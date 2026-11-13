import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ContrastInkPC

/// F9 anywhere: drawing on / off. A Carbon hot key: works whatever app is in front, and needs no permission.
enum HotKey {
    private static var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    private static var pressed: (() -> Void)?

    /// True when F9 was registered (another app may already own it).
    @discardableResult
    static func register(_ action: @escaping () -> Void) -> Bool {
        pressed = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        if handler == nil {
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.pressed?() }
                return noErr
            }, 1, &spec, nil, &handler)
            guard status == noErr else { return false }
        }
        let id = EventHotKeyID(signature: OSType(0x43496E6B), id: 1)   // 'CInk'
        return RegisterEventHotKey(UInt32(kVK_F9), 0, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    static var registered: Bool { ref != nil }
}

/// Holding Control (on its own) switches drawing on while it is held, as holding Ctrl does on Windows, but only after
/// it has been held for a moment with no click (ControlHold): Control-click (the Mac's right-click) and Control-drag
/// (Horos, OsiriX) still reach the app below. Read by polling the keyboard's modifier state and the mouse buttons, and
/// by watching mouse-down events, none of which needs a permission (watching keys in other apps would).
final class ControlWatcher {
    private var timer: Timer?
    private var hold = ControlHold()
    private var monitors: [Any] = []
    /// Whether Hold Control is switched on (⚙ Settings): while it is off nothing is watched for.
    var enabled: () -> Bool = { false }
    /// .start: switch drawing on; .stop: off again.
    var changed: ((ControlHold.Change) -> Void)?

    func start() {
        let t = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // a click between two polls (a quick Control-click) still counts
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.clicked() }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.clicked(); return e }) { monitors.append(m) }
    }

    private func clicked() {
        guard enabled() else { return }
        hold.click()
    }

    /// Drawing went off another way (Esc, F9, ✏) while Control is held: it starts again only after Control is let go.
    func drawingStopped() { hold.stopped() }

    private func poll() {
        let f = CGEventSource.flagsState(.combinedSessionState)
        let alone = enabled() && f.contains(.maskControl) && !f.contains(.maskCommand) && !f.contains(.maskAlternate)
            && !f.contains(.maskShift)
        if let c = hold.update(controlAlone: alone, mouseDown: NSEvent.pressedMouseButtons != 0, now: ProcessInfo.processInfo.systemUptime) {
            changed?(c)
        }
    }
}

/// Keys sent to the app in front: → and ← to turn the slide (the tablet's ‹ ›, and slide keys pressed while the
/// drawing layer has the keyboard). Posting keys to another app needs the Accessibility permission.
enum KeySender {
    private static var asked = false

    /// The app in front, other than Contrast Ink (kept up to date by the controller).
    static var front: NSRunningApplication?

    /// Sends the key to the app in front. False when the permission is missing (it is asked for once, the first
    /// time it is needed, with the reason shown on the toolbar).
    @discardableResult
    static func press(_ keyCode: UInt16) -> Bool {
        guard Permissions.accessibility(prompt: !asked) else { asked = true; return false }
        guard let pid = front?.processIdentifier, pid != ProcessInfo.processInfo.processIdentifier else { return false }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return false }
            e.postToPid(pid)
        }
        return true
    }
}

/// The two permissions the Mac may ask for, and where to give them.
enum Permissions {
    /// Screen Recording: the tablet's picture of the screen (without it macOS 14 and later give no picture at all).
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS to show its Screen Recording request (once; after that only System Settings changes it).
    static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    /// Accessibility: sending → and ← to the app in front (the tablet's ‹ ›, slide keys while drawing).
    static func accessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func openScreenRecording() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

    static func summary() -> String {
        let screen = screenRecording ? "Screen Recording: allowed." : MacTexts.screenRecordingMissing
        let keys = accessibility(prompt: false) ? "Accessibility: allowed." : "Accessibility: not allowed yet (needed only for the tablet's ‹ › and for slide keys pressed while drawing)."
        return screen + "\n" + keys
    }
}

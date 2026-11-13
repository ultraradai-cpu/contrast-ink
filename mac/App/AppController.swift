import AppKit
import ColorSync
import ContrastInkCore
import ContrastInkPC
import CryptoKit

/// Contrast Ink on the Mac: the drawing layer, the toolbar, the keys, OBS, and the tablet link, tied together. The
/// same behaviour as the Windows app (App.xaml.cs) as far as macOS allows.
final class AppController {
    private(set) var settings: MacSettings
    private(set) var drawing = false
    /// Drawing is on only while Control is held (let go: off again).
    private var heldByControl = false
    /// The screen the layer covers now (in NSScreen.screens), and each screen's own marks.
    private(set) var covered = 0
    private var screenMarks = ScreenMarks()
    /// The pen tablet's proximity events (which end is near), watched in every app: the drawing layer is never the
    /// active window, so it may not be sent them itself.
    private var proximityMonitors: [Any] = []
    var watchesTabletProximity: Bool { proximityMonitors.count == 2 }
    let overlay = OverlayPanel()
    let ink = InkView()
    private(set) var toolbar: Toolbar!
    private(set) var recorder: Recorder!
    private(set) var pad: PadHost?
    /// A listener that couldn't open (shown as what to do), and a key file that couldn't be read (the link stays off).
    private var padProblem: PadProblem?
    private var padKeyProblem: String?
    private let control = ControlWatcher()
    private var keyMonitor: Any?
    private let save: Bool
    private let defaultsKey = "settings"

    init(save: Bool = true) {
        self.save = save
        settings = MacSettings.decode(save ? UserDefaults.standard.data(forKey: defaultsKey) : nil, screens: NSScreen.screens.count)
        toolbar = Toolbar(controller: self)
        recorder = Recorder(toolbar: toolbar)
        ink.controller = self
        ink.autoresizingMask = [.width, .height]
        overlay.contentView = ink
    }

    func start() {
        // an older saved copy chose its screen by index only: remember that screen by its ID from now on
        let ids = NSScreen.screens.map(Self.screenID)
        if settings.screenID == nil, settings.screen > 0, ids.indices.contains(settings.screen) {
            settings.screenID = ids[settings.screen]
            if save, let d = settings.encoded() { UserDefaults.standard.set(d, forKey: defaultsKey) }
        }
        cover()
        overlay.orderFrontRegardless()
        toolbar.place(x: settings.toolbarX, y: settings.toolbarY)
        apply(save: false)
        if !HotKey.register({ [weak self] in self?.toggleDrawing() }) {
            toolbar.warn("F9 couldn't be set up (another app may use it): use the ✏ button, or switch on Hold Control to Draw in ⚙ Settings.")
        }
        control.enabled = { [weak self] in self?.settings.holdControlToDraw ?? false }
        control.changed = { [weak self] c in self?.controlChanged(c) }
        control.start()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .tabletProximity, handler: { [weak self] e in self?.ink.proximity(e) }) {
            proximityMonitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .tabletProximity, handler: { [weak self] e in self?.ink.proximity(e); return e }) {
            proximityMonitors.append(m)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.drawing, e.window === self.overlay else { return e }
            return self.key(e) ? nil : e
        }
        // the app in front (where → and ← go), and screens plugged in or out
        KeySender.front = NSWorkspace.shared.frontmostApplication.flatMap { $0 == NSRunningApplication.current ? nil : $0 }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, a != NSRunningApplication.current {
                KeySender.front = a
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
        if settings.tabletPad { startPad() }
    }

    // MARK: the drawing layer

    static func displayNumber(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// A screen's lasting ID: its display UUID (the same each time that display is plugged in), else its number.
    static func screenID(_ s: NSScreen) -> String {
        let n = displayNumber(s)
        if let u = CGDisplayCreateUUIDFromDisplayID(n)?.takeRetainedValue() { return CFUUIDCreateString(nil, u) as String }
        return "display-\(n)"
    }

    /// Covers the chosen screen, found by its ID. A projector dropping out for a moment: the layer covers the main
    /// screen meanwhile (the choice isn't changed or saved), and goes back when the projector returns. Each screen
    /// keeps its own marks; a screen whose size changed gets its marks stretched to fit.
    private func cover() {
        let all = NSScreen.screens
        let ids = all.map(Self.screenID)
        // nil for the moment macOS lists no screen (a display being swapped): the screens-changed notice brings it back
        guard let i = ScreenChoice.index(ids: ids, chosenID: settings.screenID, savedIndex: settings.screen) else { return }
        let screen = all[i]
        covered = i
        overlay.setFrame(screen.frame, display: true)
        let marks = screenMarks.cover(ids[i], width: Double(screen.frame.width), height: Double(screen.frame.height), board: ink.board)
        if marks != ink.board { ink.replaceBoard(marks); marksChanged() }
        let scale = screen.backingScaleFactor
        pad?.setTarget(ScreenGrabber.Target(display: Self.displayNumber(screen), pixelWidth: Int(screen.frame.width * scale),
                                            pixelHeight: Int(screen.frame.height * scale), exclude: toolbar.windowNumbers))
    }

    /// Screens plugged in or out: the layer follows, nothing is saved (the presenter's choice stays as it was).
    private func screensChanged() {
        cover()
        apply(save: false)
    }

    /// 🖥: the next screen, chosen (and saved) by its ID.
    func nextScreen() {
        let ids = NSScreen.screens.map(Self.screenID)
        guard let n = ScreenChoice.next(ids: ids, covered: covered) else { return }
        settings.screenID = ids[n]
        settings.screen = n
        cover()
        apply()
    }

    /// Drawing on: the layer takes the mouse, and (`keys`) the keyboard for the letter keys, without activating the
    /// app. Off: clicks go to the app below, and the keyboard goes back to it.
    func setDrawing(_ on: Bool, keys: Bool = true) {
        guard on != drawing else { return }
        drawing = on
        overlay.ignoresMouseEvents = !on
        ink.drawingOn = on
        if on {
            if keys {
                overlay.mayBecomeKey = true
                overlay.makeKeyAndOrderFront(nil)
                overlay.makeFirstResponder(ink)
            }
        } else {
            heldByControl = false
            control.drawingStopped()
            let hadKeys = overlay.isKeyWindow
            overlay.mayBecomeKey = false
            if hadKeys { giveKeyboardBack() }
            ink.laser.hideDot()
        }
        apply(save: false)
    }

    /// The keyboard back to PowerPoint (or whatever app is in front). The drawing layer gives up the key window
    /// itself (taken off screen and put straight back, now unable to be key), then the app in front is activated;
    /// on macOS 14 and later activation is cooperative, so this app yields it to that app first.
    private func giveKeyboardBack() {
        overlay.resignKey()
        overlay.orderOut(nil)
        overlay.orderFrontRegardless()
        guard let front = KeySender.front, !front.isTerminated else { return }
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: front)
            _ = front.activate(from: NSRunningApplication.current, options: [])
        } else {
            _ = front.activate(options: [])
        }
    }

    func toggleDrawing() { setDrawing(!drawing) }

    private func controlChanged(_ c: ControlHold.Change) {
        switch c {
        case .start: if !drawing { heldByControl = true; setDrawing(true, keys: false) }
        case .stop: if heldByControl { setDrawing(false) }
        }
    }

    /// A key while the drawing layer has the keyboard. True when it was used.
    private func key(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags
        guard let k = MacKeys.resolve(keyCode: e.keyCode, characters: e.charactersIgnoringModifiers ?? "",
                                      command: f.contains(.command), control: f.contains(.control), option: f.contains(.option),
                                      undoWithZ: settings.undoWithZ) else { return false }
        switch k {
        case .stopDrawing: setDrawing(false)
        case .pass(let a):
            // a slide key: on to the app in front, so the slide still turns while drawing
            if !KeySender.press(a == .next ? MacKeys.right : MacKeys.left) {
                toolbar.notice("To change slides while drawing, allow Contrast Ink in System Settings → Privacy & Security → Accessibility. Or press F9 (drawing off) first.")
            }
        case .action(let a): perform(a)
        }
        return true
    }

    private func perform(_ a: KeyAction) {
        switch a {
        case .pen: setTool(.pen)
        case .highlighter: setTool(.highlighter)
        case .arrow: setTool(.arrow)
        case .oval: setTool(.oval)
        case .eraser: setTool(.eraser)
        case .laser: setTool(.laser)
        case .clear: clear()
        case .fade: toggleFade()
        case .thinner: setWidth(max(settings.width - 1, 0))
        case .thicker: setWidth(min(settings.width + 1, Settings.widths.count - 1))
        case .undo: undo()
        case .color(let i): setColor(i)
        case .next, .previous: break
        }
    }

    // MARK: tools

    func setTool(_ t: Tool) { settings.tool = t; ink.toolChanged(); apply() }
    func setColor(_ i: Int) {
        settings.color = i
        if settings.tool == .eraser || settings.tool == .laser { settings.tool = .pen; ink.toolChanged() }   // a colour means drawing
        apply()
    }
    func setWidth(_ i: Int) { settings.width = i; apply() }
    func setOpacity(_ o: Double) { settings.opacity = o; apply() }
    func toggleFade() { settings.fadingInk.toggle(); apply() }
    func toggleFold() { settings.toolbarCollapsed.toggle(); apply() }
    func undo() { _ = ink.undo(); marksChanged() }
    func clear() { ink.clear(); marksChanged() }

    func change(_ f: (inout MacSettings) -> Void) { f(&settings); apply() }

    func toolbarMoved(x: Double, y: Double) { settings.toolbarX = x; settings.toolbarY = y; apply() }

    /// A mark was added, erased, undone, cleared or faded: the undo button and the tablet follow.
    func marksChanged() {
        toolbar.setCanUndo(ink.board.canUndo)
        sendState()
    }

    /// Shows and saves the settings, and tells the tablet.
    private func apply(save: Bool = true) {
        settings = settings.cleaned(screens: NSScreen.screens.count)
        toolbar.refresh(drawing: drawing, settings: settings, screens: NSScreen.screens.count, covered: covered)
        toolbar.setCanUndo(ink.board.canUndo)
        ink.needsDisplay = true
        if save && self.save, let d = settings.encoded() { UserDefaults.standard.set(d, forKey: defaultsKey) }
        sendState()
    }

    // MARK: the tablet link

    func setTabletPad(_ on: Bool) {
        settings.tabletPad = on
        if on { startPad() } else { stopPad() }
        apply()
    }

    /// Listens for a tablet (switched on in ⚙ Settings). Screen Recording is asked for here: the tablet's picture needs it.
    func startPad(code: String? = nil) {
        guard pad == nil else { return }
        padKeyProblem = nil
        let key: P256.KeyAgreement.PrivateKey
        switch PadIdentity.load() {
        case .problem(let text):
            // never a new key behind the presenter's back: every paired tablet would warn "not the PC you paired with"
            padKeyProblem = text
            toolbar.notice(text)
            showPad()
            return
        case .key(let k, let note):
            key = k
            if let note { toolbar.notice(note) }
        }
        if !Permissions.screenRecording { Permissions.requestScreenRecording() }
        let p = PadHost(key: key, code: code)
        pad = p
        p.server.onMessage = { [weak self] t, m in self?.padMessage(t, m) }
        p.server.onConnection = { [weak self, weak p] name, _ in
            guard let self, let p else { return }
            if name == nil { self.ink.remoteCancel() } else { p.newConnection(); self.sendState() }
            self.showPad()
        }
        p.server.onCodeChanged = { [weak self] _ in
            self?.showPad()
            self?.toolbar.notice("Someone kept typing wrong tablet codes: there is a new code (⚙ Settings).")
        }
        p.server.onReady = { [weak self] _, usb in
            guard let self else { return }
            if usb != nil, self.padProblem == .usbDoor { self.padProblem = nil }   // it opened after all
            self.showPad()
        }
        p.server.onError = { [weak self] problem, raw in
            Log.write(raw)   // the details for the log; the toolbar says what to do
            self?.padProblem = problem
            self?.showPad()
        }
        p.server.allowUsbDoor = { [weak self, weak p] device, answer in
            guard let self, let p, self.pad === p else { answer(false); return }
            if Self.usbDoorAllowed { answer(true); return }
            Log.write("tablet link: \"\(device)\" on the USB door is waiting to be allowed")
            self.askUsbDoor(answer)
        }
        cover()
        p.start()
        showPad()
    }

    /// The USB door can be reached by any program on this Mac, not only an Android tablet through adb: the first
    /// tablet there in each run of the app waits for the presenter's Allow (until its 30-second PROOF deadline).
    private static var usbDoorAllowed = false
    private var askNumber = 0

    private func askUsbDoor(_ answer: @escaping (Bool) -> Void) {
        askNumber += 1
        let n = askNumber
        toolbar.ask("An Android tablet on the USB cable wants to draw:") { yes in
            if yes { AppController.usbDoorAllowed = true }
            answer(yes)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + PadPC.proofWithin) { [weak self] in
            guard let self, self.askNumber == n else { return }
            self.toolbar.cancelAsk()   // the tablet has given up by now
        }
    }

    func stopPad() {
        pad?.stop()
        pad = nil
        padProblem = nil
        padKeyProblem = nil
        askNumber += 1
        toolbar.cancelAsk()
        ink.remoteCancel()
        showPad()
    }

    private func showPad() {
        guard let p = pad else { toolbar.showPad(settings.tabletPad ? padKeyProblem : nil); return }
        var lines: [String] = []
        if let c = p.server.connected {
            lines.append("Connected: \(c.name)" + (c.usb ? " (by the USB cable)." : " (over Wi-Fi). Plug in its USB cable and it switches to the cable by itself."))
        } else {
            let ports = p.server.ports
            lines.append("On the tablet: Contrast Ink → Use as a pad → \(PadHost.macName), code \(p.server.code). The first time, the tablet shows a PC check: it must be \(p.server.pcCheck).")
            if let a = PadHost.addresses().first {
                lines.append("Or type the address \(a)" + (ports.wifi != 0 && ports.wifi != PadProtocol.defaultPort ? ":\(ports.wifi)" : "") + ".")
            }
            lines.append("By USB cable, by itself when plugged in: an iPad in pad mode just needs the cable; an Android tablet needs USB debugging on and Google's platform-tools (adb) on this Mac"
                         + (p.adbFound ? " (found)." : " (not found yet: brew install android-platform-tools)."))
            if ports.usb != nil {
                lines.append("An Android tablet is set up for the cable: it connects by itself. The first time, allow it on this toolbar.")
            }
        }
        if !Permissions.screenRecording {
            lines.append(MacTexts.screenRecordingForTablet)
        }
        if let padProblem { lines.append(padProblem.instruction) }
        toolbar.showPad(lines.joined(separator: "\n"))
    }

    func refreshPermissions() {
        toolbar.showPermissions(Permissions.summary())
        showPad()
    }

    private func sendState() {
        guard let p = pad else { return }
        p.server.send(PadPC.state(tool: settings.tool, color: settings.color, width: settings.width, opacity: settings.opacity,
                                  fading: settings.fadingInk, canUndo: ink.board.canUndo))
    }

    /// What the tablet draws and asks for (strokes in fractions of this screen, its toolbar's commands).
    func padMessage(_ type: UInt8, _ payload: Data) {
        switch PadProtocol.Kind(rawValue: type) {
        case .strokeBegin?: if let b = PadPC.begin(payload) { ink.remoteBegin(b.x, b.y, eraserEnd: b.eraserEnd) }
        case .strokePoints?: ink.remoteMove(PadPC.points(payload))
        case .strokeEnd?: ink.remoteEnd(); sendState()
        case .strokeCancel?: ink.remoteCancel()
        case .hover?: if let h = PadPC.hover(payload) { ink.remoteHover(h.x, h.y) }
        case .hoverEnd?: ink.remoteHoverEnd()
        case .command?: if let c = PadPC.command(payload) { padCommand(c) }
        default: break
        }
    }

    private func padCommand(_ c: PadCommand) {
        switch c {
        case .undo: undo()
        case .clear: clear()
        case .next, .previous:
            // the app in front turns the page; the first time, macOS asks for Accessibility (and the toolbar says why)
            if !KeySender.press(c == .next ? MacKeys.right : MacKeys.left) {
                toolbar.notice("To change slides from the tablet, allow Contrast Ink in System Settings → Privacy & Security → Accessibility (it sends → and ← to the app in front).")
            }
        case .fade(let on): settings.fadingInk = on; apply()
        case .tool(let t): setTool(t)
        case .color(let i): setColor(i)
        case .width(let w): setWidth(w)
        case .opacity(let o): setOpacity(o)
        }
    }

    /// ✕: quits at once when nothing would be lost; otherwise asks first (marks on the screen, an OBS recording
    /// Contrast Ink started, a connected tablet).
    func quitClicked() {
        let question = QuitCheck.question(marks: ink.board.marks.count, recording: recorder.active, tablet: pad?.server.connected != nil)
        guard let question else { NSApp.terminate(nil); return }
        toolbar.confirmQuit(question) { NSApp.terminate(nil) }
    }

    func quit() {
        pad?.stop()
    }
}

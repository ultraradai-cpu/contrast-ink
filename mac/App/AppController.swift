import AppKit
import ContrastInkCore
import ContrastInkPC

/// Contrast Ink on the Mac: the drawing layer, the toolbar, the keys, OBS, and the tablet link, tied together. The
/// same behaviour as the Windows app (App.xaml.cs) as far as macOS allows.
final class AppController {
    private(set) var settings: MacSettings
    private(set) var drawing = false
    /// Drawing is on only while Control is held (let go: off again).
    private var heldByControl = false
    let overlay = OverlayPanel()
    let ink = InkView()
    private(set) var toolbar: Toolbar!
    private(set) var recorder: Recorder!
    private(set) var pad: PadHost?
    private var padNotice: String?
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
        cover()
        overlay.orderFrontRegardless()
        toolbar.place(x: settings.toolbarX, y: settings.toolbarY)
        apply(save: false)
        if !HotKey.register({ [weak self] in self?.toggleDrawing() }) {
            toolbar.warn("F9 couldn't be set up (another app may use it): use the ✏ button, or hold Control to draw.")
        }
        control.changed = { [weak self] down in self?.controlChanged(down) }
        control.start()
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

    private var screen: NSScreen {
        let all = NSScreen.screens
        return all.indices.contains(settings.screen) ? all[settings.screen] : (NSScreen.main ?? all[0])
    }

    /// Covers the chosen screen (a projector plugged in or out mid-lecture: the layer follows by itself).
    private func cover() {
        overlay.setFrame(screen.frame, display: true)
        let scale = screen.backingScaleFactor
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        pad?.setTarget(ScreenGrabber.Target(display: id, pixelWidth: Int(screen.frame.width * scale), pixelHeight: Int(screen.frame.height * scale),
                                            exclude: toolbar.windowNumbers))
    }

    private func screensChanged() {
        settings = settings.cleaned(screens: NSScreen.screens.count)
        cover()
        apply()
    }

    func nextScreen() {
        let n = NSScreen.screens.count
        guard n > 1 else { return }
        settings.screen = (settings.screen + 1) % n
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
            let hadKeys = overlay.isKeyWindow
            overlay.mayBecomeKey = false
            // the keyboard back to PowerPoint: activating it takes the key window from the drawing layer
            if hadKeys { KeySender.front?.activate(options: []) }
            ink.laser.hideDot()
        }
        apply(save: false)
    }

    func toggleDrawing() { setDrawing(!drawing) }

    private func controlChanged(_ down: Bool) {
        guard settings.holdControlToDraw else { return }
        if down, !drawing { heldByControl = true; setDrawing(true, keys: false) }
        else if !down, heldByControl { setDrawing(false) }
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
        toolbar.refresh(drawing: drawing, settings: settings, screens: NSScreen.screens.count)
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
        if !Permissions.screenRecording { Permissions.requestScreenRecording() }
        let p = PadHost(code: code)
        pad = p
        p.server.onMessage = { [weak self] t, m in self?.padMessage(t, m) }
        p.server.onConnection = { [weak self] name, _ in
            guard let self else { return }
            if name == nil { self.ink.remoteCancel() } else { self.sendState() }
            self.showPad()
        }
        p.server.onCodeChanged = { [weak self] _ in
            self?.showPad()
            self?.toolbar.notice("Someone kept typing wrong tablet codes: there is a new code (⚙ Settings).")
        }
        p.server.onReady = { [weak self] _, _ in self?.showPad() }
        p.server.onError = { [weak self] text in Log.write(text); self?.padNotice = text; self?.showPad() }
        cover()
        p.start()
        showPad()
    }

    func stopPad() {
        pad?.stop()
        pad = nil
        padNotice = nil
        ink.remoteCancel()
        showPad()
    }

    private func showPad() {
        guard let p = pad else { toolbar.showPad(nil); return }
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
            lines.append(ports.usb != nil ? "USB door: open (127.0.0.1:\(PadPC.usbPort))." : "USB door: not open (another app uses port \(PadPC.usbPort)?).")
        }
        if !Permissions.screenRecording {
            lines.append("The tablet's picture needs Screen Recording: System Settings → Privacy & Security → Screen Recording → Contrast Ink, then quit and reopen it.")
        }
        if let padNotice { lines.append(padNotice) }
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

    func quit() {
        pad?.stop()
    }
}

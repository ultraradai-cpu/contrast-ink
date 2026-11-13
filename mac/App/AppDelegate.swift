import AppKit
import ContrastInkCore
import ContrastInkPC

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let smoke = ProcessInfo.processInfo.arguments.contains("--smoke-test")
        let c = AppController(save: !smoke)
        controller = c
        c.start()
        if smoke { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { SmokeTest.run(c) } }
    }

    func applicationWillTerminate(_ notification: Notification) { controller?.quit() }
}

/// `ContrastInk --smoke-test`: starts the app as usual, checks that it came up as it should (the drawing layer above
/// other windows and letting clicks through until drawing is on, the toolbar hidden from capture and above the layer,
/// a tablet's stroke drawn and seen in the layer's pixels, undo, a tablet command, and the audit's fixes: the keyboard
/// given back when drawing goes off, only a stroke's own area drawn again, ✕ asking first, the pen tablet's
/// proximity watched), prints "SMOKE OK" and quits.
/// Run by the Mac workflow on GitHub, where no Screen Recording permission can be given: pictures of the screen are
/// not taken there (only their JPEG encoding is checked).
enum SmokeTest {
    private static var failures: [String] = []

    private static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures.append(what) }
    }

    static func run(_ c: AppController) {
        let o = c.overlay
        check(o.isVisible, "the drawing layer is on screen")
        check(o.level.rawValue >= NSWindow.Level.statusBar.rawValue, "the drawing layer is above normal windows (level \(o.level.rawValue))")
        check(o.collectionBehavior.contains(.canJoinAllSpaces) && o.collectionBehavior.contains(.fullScreenAuxiliary),
              "the drawing layer joins every Space and full-screen apps")
        check(o.ignoresMouseEvents, "drawing off: clicks go through to the app below")
        let t = c.toolbar.panel
        check(t.isVisible, "the toolbar is on screen")
        check(t.sharingType == .none, "the toolbar asks to be left out of screen capture")
        check(t.level.rawValue > o.level.rawValue, "the toolbar is above the drawing layer")
        check(t.styleMask.contains(.nonactivatingPanel) && !t.canBecomeKey, "the toolbar never takes the keyboard")
        print("     F9 hot key registered: \(HotKey.registered)")

        check(!c.settings.holdControlToDraw, "Hold Control is off by default (Control-click is the Mac's right-click)")
        c.setDrawing(true)
        check(!o.ignoresMouseEvents && c.ink.drawingOn, "drawing on: the layer takes the mouse")
        print("     drawing on: the layer has the keyboard: \(o.isKeyWindow)")
        c.setDrawing(false)
        check(o.ignoresMouseEvents, "drawing off again: clicks go through")
        check(!o.isKeyWindow, "drawing off: the drawing layer has given up the keyboard")
        check(o.isVisible, "drawing off: the drawing layer is still on screen")

        // the chosen screen, by its ID
        let screens = NSScreen.screens
        check(screens.indices.contains(c.covered) && o.frame == screens[c.covered].frame, "the layer covers the chosen screen")
        check(!AppController.screenID(screens[0]).isEmpty && AppController.screenID(screens[0]) == AppController.screenID(screens[0]),
              "a screen has a lasting ID (\(AppController.screenID(screens[0])))")
        let chosen = c.settings.screenID
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        check(c.settings.screenID == chosen, "a change of screens doesn't change the chosen screen")
        check(!Permissions.summary().contains("desktop"), "the permissions text doesn't claim the tablet sees the desktop")
        check(c.watchesTabletProximity, "the pen tablet's proximity is watched in every app")

        // a tablet's stroke, through the same path the tablet link uses
        func send(_ m: Data) { c.padMessage(m[0], m.dropFirst(5)) }
        c.setTool(.pen); c.setColor(0); c.setWidth(2); c.setOpacity(1)
        send(PadProtocol.strokeBegin(x: 0.25, y: 0.25))
        send(PadProtocol.strokePoints([(x: 0.5, y: 0.5)]))
        send(PadProtocol.strokeEnd())
        check(c.ink.board.marks.count == 1, "a tablet stroke becomes a mark")
        let px = pixel(c.ink, 0.375, 0.375)
        check(px.map { $0.alphaComponent > 0.8 && $0.redComponent > 0.8 && $0.greenComponent < 0.4 } ?? false,
              "the mark is drawn in red where it was drawn (\(px.map { "r \($0.redComponent) g \($0.greenComponent) a \($0.alphaComponent)" } ?? "no pixels"))")
        let empty = pixel(c.ink, 0.8, 0.2)
        check(empty.map { $0.alphaComponent < 0.05 } ?? false, "the rest of the layer is see-through")

        // a stroke being drawn redraws only its own part of the layer, never the finished marks
        let drawnBefore = c.ink.marksDrawn
        send(PadProtocol.strokeBegin(x: 0.6, y: 0.6))
        for i in 1...20 {
            send(PadProtocol.strokePoints([(x: 0.6 + Double(i) * 0.005, y: 0.6)]))
            c.ink.displayIfNeeded()
        }
        check(c.ink.marksDrawn == drawnBefore, "drawing a stroke doesn't draw the finished marks again (\(c.ink.marksDrawn - drawnBefore) drawn)")
        let area = c.ink.lastDrawn
        check(area.width > 0 && area.width < c.ink.bounds.width / 4 && area.height < c.ink.bounds.height / 4,
              "only the stroke's new piece is drawn again (\(Int(area.width))×\(Int(area.height)) of \(Int(c.ink.bounds.width))×\(Int(c.ink.bounds.height)))")
        send(PadProtocol.strokeCancel())
        check(c.ink.board.marks.count == 1, "a cancelled stroke leaves no mark")

        // ✕ with a mark on the screen asks first, and Cancel keeps the app running
        c.quitClicked()
        check(c.toolbar.confirmingQuit, "✕ with marks asks before quitting")
        c.toolbar.answerQuit(false)
        check(!c.toolbar.confirmingQuit, "Cancel keeps Contrast Ink running")
        send(PadProtocol.command("undo"))
        check(c.ink.board.marks.isEmpty, "undo from the tablet removes it")
        send(PadProtocol.command("tool:arrow"))
        send(PadProtocol.command("color:3"))
        check(c.settings.tool == .arrow && c.settings.color == 3, "tool and colour commands from the tablet")
        send(PadProtocol.strokeBegin(x: 0.1, y: 0.1))
        send(PadProtocol.strokePoints([(x: 0.3, y: 0.2)]))
        send(PadProtocol.strokeEnd())
        check(c.ink.board.marks.first?.points.count == 5, "an arrow from the tablet has its head")
        c.clear()
        check(c.ink.board.marks.isEmpty && c.ink.board.canUndo, "clear, and undo can bring it back")

        // the USB door's question (Allow / Deny) on the toolbar
        var answered: Bool?
        c.toolbar.ask("An Android tablet on the USB cable wants to draw:") { answered = $0 }
        check(c.toolbar.asking, "the toolbar asks Allow / Deny")
        c.toolbar.cancelAsk()
        check(!c.toolbar.asking && answered == false, "a question taken away unanswered is a Deny")

        // the tablet's pictures: only the encoding (no Screen Recording permission on GitHub's Macs)
        let jpeg = ScreenGrabber.encode(testImage())
        check(jpeg.map { $0.starts(with: [0xFF, 0xD8]) } ?? false, "a picture encodes as JPEG")
        check(ScreenGrabber.scaled(3024, 1964) == (1600, 1039), "pictures are at most 1600 px wide")
        print("     pictures of the screen: skipped (Screen Recording permission: \(Permissions.screenRecording))")

        // the pen tablet's eraser end, through the app's own event queue (the local proximity monitor)
        if let near = proximity(eraser: true, entering: true) {
            NSApp.postEvent(near, atStart: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                check(c.ink.eraserEnd, "the pen's eraser end coming near is seen (proximity event)")
                if let away = proximity(eraser: true, entering: false) { c.ink.proximity(away) }
                check(!c.ink.eraserEnd, "the pen leaving is seen")
                finish()
            }
        } else {
            check(false, "a proximity event could be made")
            finish()
        }
    }

    private static func finish() {
        if failures.isEmpty { print("SMOKE OK") } else { print("SMOKE FAILED: \(failures.count)") }
        fflush(stdout)
        exit(failures.isEmpty ? 0 : 1)
    }

    /// A pen tablet's proximity event (pointer type 3: the eraser end).
    private static func proximity(eraser: Bool, entering: Bool) -> NSEvent? {
        guard let e = CGEvent(source: nil) else { return nil }
        e.type = .tabletProximity
        e.setIntegerValueField(.tabletProximityEventPointerType, value: eraser ? 3 : 1)
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        return NSEvent(cgEvent: e)
    }

    /// The layer's own drawing at fractions of its size (not a screen capture).
    private static func pixel(_ v: NSView, _ fx: Double, _ fy: Double) -> NSColor? {
        guard v.bounds.width > 0, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        let x = Int(Double(rep.pixelsWide) * fx), y = Int(Double(rep.pixelsHigh) * fy)
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    private static func testImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        ctx.setFillColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        return ctx.makeImage()!
    }
}

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
/// a tablet's stroke drawn and seen in the layer's pixels, undo, a tablet command), prints "SMOKE OK" and quits.
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

        c.setDrawing(true)
        check(!o.ignoresMouseEvents && c.ink.drawingOn, "drawing on: the layer takes the mouse")
        c.setDrawing(false)
        check(o.ignoresMouseEvents, "drawing off again: clicks go through")

        // a tablet's stroke, through the same path the tablet link uses
        func send(_ m: Data) { c.padMessage(m[0], m.dropFirst(5)) }
        c.setTool(.pen); c.setColor(0); c.setWidth(2); c.setOpacity(1)
        send(PadProtocol.strokeBegin(x: 0.25, y: 0.25))
        send(PadProtocol.strokePoints([(x: 0.5, y: 0.5)]))
        send(PadProtocol.strokeEnd())
        check(c.ink.board.marks.count == 1, "a tablet stroke becomes a mark")
        let px = pixel(c.ink, 0.375, 0.375)
        check(px.map { $0.alpha > 0.8 && $0.red > 0.8 && $0.green < 0.4 } ?? false,
              "the mark is drawn in red where it was drawn (\(px.map { "r \($0.red) g \($0.green) a \($0.alpha)" } ?? "no pixels"))")
        let empty = pixel(c.ink, 0.8, 0.2)
        check(empty.map { $0.alpha < 0.05 } ?? false, "the rest of the layer is see-through")
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

        // the tablet's pictures: only the encoding (no Screen Recording permission on GitHub's Macs)
        let jpeg = ScreenGrabber.encode(testImage())
        check(jpeg.map { $0.starts(with: [0xFF, 0xD8]) } ?? false, "a picture encodes as JPEG")
        check(ScreenGrabber.scaled(3024, 1964) == (1600, 1039), "pictures are at most 1600 px wide")
        print("     pictures of the screen: skipped (Screen Recording permission: \(Permissions.screenRecording))")

        if failures.isEmpty { print("SMOKE OK") } else { print("SMOKE FAILED: \(failures.count)") }
        fflush(stdout)
        exit(failures.isEmpty ? 0 : 1)
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

import AppKit
import ImageIO
import ScreenCaptureKit
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
/// Run by the Mac workflow on GitHub. Where Screen Recording is allowed (GitHub's Macs allow it), the tablet's picture
/// is captured for real with ScreenCaptureKit and must not show the toolbar; where it isn't, that is said in the log
/// and only the toolbar's capture flag is checked.
enum SmokeTest {
    private static var failures: [String] = []

    private static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures.append(what) }
    }

    static func run(_ c: AppController) {
        print("     macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let o = c.overlay
        check(o.isVisible, "the drawing layer is on screen")
        check(o.level.rawValue >= NSWindow.Level.statusBar.rawValue, "the drawing layer is above normal windows (level \(o.level.rawValue))")
        check(o.collectionBehavior.contains(.canJoinAllSpaces) && o.collectionBehavior.contains(.fullScreenAuxiliary),
              "the drawing layer joins every Space and full-screen apps")
        check(o.ignoresMouseEvents, "drawing off: clicks go through to the app below")
        let t = c.toolbar.panel
        check(t.isVisible, "the toolbar is on screen")
        // a flag only (whether a capture honours it depends on the macOS version): the live capture below is the real check
        check(t.sharingType == .none, "flag check: the toolbar's sharingType is .none (asks to be left out of screen capture)")
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
        // the swatch's own sRGB numbers (#FF3B30) on a P3 display, not device RGB (more saturated there)
        let p3 = inkOnP3(c.ink, 0.375, 0.375, Settings.colors[0])
        check(p3 == nil, "on a P3 display the red ink is the swatch's sRGB red \(Settings.colors[0]) (\(p3 ?? "it is"))")
        let empty = pixel(c.ink, 0.8, 0.2)
        check(empty.map { $0.alphaComponent < 0.05 } ?? false, "the rest of the layer is see-through")

        // a live stroke (not ended yet) is drawn by its own path: the same sRGB colour on a P3 display
        c.setColor(2)   // green #34C759: far from sRGB's corner, so device RGB would shift it plainly
        send(PadProtocol.strokeBegin(x: 0.7, y: 0.2))
        send(PadProtocol.strokePoints([(x: 0.9, y: 0.2)]))
        let liveP3 = inkOnP3(c.ink, 0.8, 0.2, Settings.colors[2])
        check(liveP3 == nil, "on a P3 display a live stroke is the swatch's sRGB green \(Settings.colors[2]) (\(liveP3 ?? "it is"))")
        // A bitmap converts device RGB as if it were sRGB, so the pixels above can't tell them apart (a mutation run
        // showed it). A PDF keeps the colour space each colour was set in: device RGB is written as RG / rg.
        let ops = pdfColourOperators(c.ink)
        print("     the layer drawn as PDF sets its colours with: \(ops.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))")
        check((ops["RG"] ?? 0) + (ops["rg"] ?? 0) == 0 && (ops["SC"] ?? 0) + (ops["SCN"] ?? 0) > 0,
              "the ink's colours are set in a calibrated colour space (sRGB), never device RGB (RG/rg)")
        send(PadProtocol.strokeCancel())
        c.setColor(0)

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

        // the tablet's pictures: the encoding here; a live capture at the end (captureCheck)
        let jpeg = ScreenGrabber.encode(testImage())
        check(jpeg.map { $0.starts(with: [0xFF, 0xD8]) } ?? false, "a picture encodes as JPEG")
        check(ScreenGrabber.scaled(3024, 1964) == (1600, 1039), "pictures are at most 1600 px wide")

        // the pen tablet's eraser end, through the app's own event queue (the local proximity monitor)
        if let near = proximity(eraser: true, entering: true) {
            NSApp.postEvent(near, atStart: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                check(c.ink.eraserEnd, "the pen's eraser end coming near is seen (proximity event)")
                if let away = proximity(eraser: true, entering: false) { c.ink.proximity(away) }
                check(!c.ink.eraserEnd, "the pen leaving is seen")
                captureCheck(c) { finish() }
            }
        } else {
            check(false, "a proximity event could be made")
            captureCheck(c) { finish() }
        }
    }

    /// The tablet's picture, taken for real by ScreenGrabber (ScreenCaptureKit, the toolbar's windows left out by
    /// number, as the tablet link does). sharingType .none alone isn't relied on (honoured or not by macOS version), so
    /// for these captures the toolbar is made capturable: the capture leaving nothing out must show it (the check can
    /// fail), the tablet's capture must not. What .none alone does is logged. The pictures are kept as
    /// smoke-capture-*.jpg. Without Screen Recording permission this says so and checks nothing more.
    private static func captureCheck(_ c: AppController, then done: @escaping () -> Void) {
        let t = c.toolbar.panel
        guard #available(macOS 14.0, *) else {
            print("     LIVE CAPTURE NOT TESTED: macOS 13 (no ScreenCaptureKit screenshots); only the sharingType flag was checked")
            done(); return
        }
        guard Permissions.screenRecording, let screen = t.screen ?? NSScreen.main else {
            print("     LIVE CAPTURE NOT TESTED: no Screen Recording permission on this Mac; only the sharingType flag was checked")
            done(); return
        }
        let scale = screen.backingScaleFactor
        func target(_ exclude: [Int]) -> ScreenGrabber.Target {
            ScreenGrabber.Target(display: AppController.displayNumber(screen), pixelWidth: Int(screen.frame.width * scale),
                                 pixelHeight: Int(screen.frame.height * scale), exclude: exclude)
        }
        var ended = false
        func end() { if !ended { ended = true; t.sharingType = .none; done() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if !ended { check(false, "live capture: ScreenCaptureKit gave pictures within 30 s"); end() }
        }
        /// One capture (a fresh grabber: no window list kept from before), its share of toolbar colour, on the main queue.
        func capture(_ name: String, exclude: [Int], then next: @escaping (Double?) -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                ScreenGrabber().jpeg(target(exclude)) { jpeg in
                    DispatchQueue.main.async {
                        guard !ended else { return }
                        if let jpeg { try? jpeg.write(to: URL(fileURLWithPath: "smoke-capture-\(name).jpg")) }
                        next(toolbarShare(jpeg, panel: t.frame, screen: screen.frame))
                    }
                }
            }
        }
        func pct(_ v: Double?) -> String { v.map { "\(Int($0 * 100))% of its box is its colour" } ?? "no picture" }
        print("     toolbar at \(t.frame) on a screen \(screen.frame) at \(scale)x")
        capture("flag-only", exclude: []) { flagOnly in
            print("     sharingType .none alone, nothing left out: the toolbar is \((flagOnly ?? 0) > 0.3 ? "IN" : "not in") the capture (\(pct(flagOnly)))")
            t.sharingType = .readOnly
            capture("all", exclude: []) { shown in
                check((shown ?? 0) > 0.3, "live capture, nothing left out (toolbar capturable): the toolbar is in the picture (\(pct(shown))), so this check can fail")
                capture("tablet", exclude: c.toolbar.windowNumbers) { left in
                    check(left.map { $0 < 0.05 } ?? false, "live capture (ScreenCaptureKit), as the tablet gets it: the toolbar is absent (\(pct(left)))")
                    inkOnP3Window(c, screen: screen) { end() }
                }
            }
        }
    }

    /// The layer drawn into a PDF, and how often each colour-setting operator appears in it (RG/rg: device RGB;
    /// CS/SC/SCN and cs/sc/scn: a named colour space, sRGB here).
    private static func pdfColourOperators(_ v: NSView) -> [String: Int] {
        final class Counts { var ops: [String: Int] = [:] }
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: v.bounds.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return [:] }
        ctx.beginPDFPage(nil)
        if v.isFlipped { ctx.translateBy(x: 0, y: box.height); ctx.scaleBy(x: 1, y: -1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: v.isFlipped)
        v.draw(v.bounds)
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider),
              let page = doc.page(at: 1) else { return [:] }
        let counts = Counts()
        // one table per operator, so each callback knows its own name
        for op in ["RG", "rg", "CS", "cs", "SC", "sc", "SCN", "scn", "K", "k", "G", "g"] {
            guard let one = CGPDFOperatorTableCreate() else { continue }
            CGPDFOperatorTableSetCallback(one, op) { _, info in
                guard let info else { return }
                Unmanaged<Counts>.fromOpaque(info).takeUnretainedValue().ops["_", default: 0] += 1
            }
            let before = counts.ops["_"] ?? 0
            let stream = CGPDFContentStreamCreateWithPage(page)
            let scanner = CGPDFScannerCreate(stream, one, Unmanaged.passUnretained(counts).toOpaque())
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            CGPDFContentStreamRelease(stream)
            CGPDFOperatorTableRelease(one)
            let n = (counts.ops["_"] ?? 0) - before
            counts.ops["_"] = before
            if n > 0 { counts.ops[op] = n }
        }
        counts.ops["_"] = nil
        return counts.ops
    }

    /// The marks drawn by the layer into a Display P3 picture (a MacBook's screen), read back as sRGB: within [r] of
    /// (fx, fy) there must be solid ink of exactly [hex] (the swatch). Device-RGB ink would keep its numbers in P3 and
    /// read back more saturated. Nil when it matches, else what was found.
    private static func inkOnP3(_ v: NSView, _ fx: Double, _ fy: Double, _ hex: String, r: Int = 6) -> String? {
        let w = Int(v.bounds.width), h = Int(v.bounds.height)
        guard w > 0, h > 0, let want = Ink.rgb(hex), let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: p3,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "no P3 picture" }
        if v.isFlipped { ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: v.isFlipped)
        v.draw(v.bounds)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return "no pixels" }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let cx = Int(Double(w) * fx), cy = Int(Double(h) * fy)   // the bitmap's first row is the picture's top
        var best = Double.infinity, found = "no solid ink"
        for y in max(0, cy - r)...min(h - 1, cy + r) {
            for x in max(0, cx - r)...min(w - 1, cx + r) {
                let i = (y * w + x) * 4
                guard px[i + 3] >= 250 else { continue }
                let comps: [CGFloat] = [CGFloat(px[i]) / 255, CGFloat(px[i + 1]) / 255, CGFloat(px[i + 2]) / 255, 1]
                guard let c = CGColor(colorSpace: p3, components: comps)?.converted(to: srgb, intent: .defaultIntent, options: nil),
                      let s = c.components, s.count >= 3 else { continue }
                let d = max(abs(Double(s[0]) - want.r), abs(Double(s[1]) - want.g), abs(Double(s[2]) - want.b))
                if d < best { best = d; found = String(format: "P3 %d %d %d = sRGB %.3f %.3f %.3f", px[i], px[i + 1], px[i + 2], s[0], s[1], s[2]) }
            }
        }
        return best < 0.03 ? nil : found
    }

    /// The drawing layer's window given a Display P3 backing store (as on a MacBook's screen), a thick green stroke
    /// being drawn (live: finished marks go through an sRGB picture first), and the screen captured: the green must come out as the swatch's sRGB #34C759. Ink in device RGB would
    /// keep its numbers in the P3 store and come out more saturated (the bitmap and PDF checks can't see that).
    private static func inkOnP3Window(_ c: AppController, screen: NSScreen, then done: @escaping () -> Void) {
        let o = c.overlay
        let before = o.colorSpace
        o.colorSpace = .displayP3
        func send(_ m: Data) { c.padMessage(m[0], m.dropFirst(5)) }
        c.setTool(.pen); c.setColor(2); c.setWidth(2); c.setOpacity(1)
        send(PadProtocol.strokeBegin(x: 0.30, y: 0.43))
        send(PadProtocol.strokePoints([(x: 0.50, y: 0.43), (x: 0.70, y: 0.43)]))
        c.ink.display()
        let want = Ink.rgb(Settings.colors[2]) ?? (0, 1, 0)
        captureRaw(screen: screen, exclude: c.toolbar.windowNumbers) { image in
            o.colorSpace = before
            send(PadProtocol.strokeCancel())
            if let image { try? (NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))?
                .write(to: URL(fileURLWithPath: "smoke-capture-p3-green.png")) }
            guard let image, let rgb = meanSRGB(image, fx: 0.5, fy: 0.43, half: 2) else {
                check(false, "the green patch on a P3 window could be captured"); done(); return
            }
            let d = max(abs(rgb.0 - want.r), abs(rgb.1 - want.g), abs(rgb.2 - want.b))
            check(d < 0.06, String(format: "on a Display P3 window the green ink is the swatch's sRGB %@ (captured %.3f %.3f %.3f)",
                                   Settings.colors[2], rgb.0, rgb.1, rgb.2))
            done()
        }
    }

    /// The screen as ScreenCaptureKit gives it (PNG-quality, not the tablet's JPEG: colours must stay exact).
    private static func captureRaw(screen: NSScreen, exclude: [Int], _ done: @escaping (CGImage?) -> Void) {
        guard #available(macOS 14.0, *) else { done(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
                guard let content, let display = content.displays.first(where: { $0.displayID == AppController.displayNumber(screen) }) else {
                    DispatchQueue.main.async { done(nil) }; return
                }
                let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { exclude.contains(Int($0.windowID)) })
                let config = SCStreamConfiguration()
                config.width = Int(screen.frame.width * screen.backingScaleFactor)
                config.height = Int(screen.frame.height * screen.backingScaleFactor)
                config.showsCursor = false
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                    DispatchQueue.main.async { done(image) }
                }
            }
        }
    }

    /// The mean colour, in sRGB, of a (2·half+1)² block centred at fractions of the image.
    private static func meanSRGB(_ image: CGImage, fx: Double, fy: Double, half: Int) -> (Double, Double, Double)? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        let cx = Int(Double(image.width) * fx), cy = Int(Double(image.height) * fy)
        var sum = (0.0, 0.0, 0.0), n = 0.0
        for y in max(0, cy - half)...min(image.height - 1, cy + half) {
            for x in max(0, cx - half)...min(image.width - 1, cx + half) {
                let i = (y * image.width + x) * 4
                sum.0 += Double(px[i]) / 255; sum.1 += Double(px[i + 1]) / 255; sum.2 += Double(px[i + 2]) / 255; n += 1
            }
        }
        return n > 0 ? (sum.0 / n, sum.1 / n, sum.2 / n) : nil
    }

    /// The share of the toolbar's box (its edges left out) in a captured JPEG that is the toolbar's background colour.
    private static func toolbarShare(_ jpeg: Data?, panel: NSRect, screen: NSRect) -> Double? {
        guard let jpeg, let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        let sx = Double(image.width) / Double(screen.width), sy = Double(image.height) / Double(screen.height)
        let box = panel.insetBy(dx: panel.width * 0.15, dy: panel.height * 0.15)
        // screen points (origin bottom left) to the picture's pixels (origin top left)
        let x0 = max(0, Int((box.minX - screen.minX) * sx)), x1 = min(image.width, Int((box.maxX - screen.minX) * sx))
        let y0 = max(0, Int((screen.maxY - box.maxY) * sy)), y1 = min(image.height, Int((screen.maxY - box.minY) * sy))
        guard x1 > x0, y1 > y0 else { return nil }
        let bar = Ink.rgb(MacPalette.bar) ?? (0.08, 0.1, 0.13)
        let want = (Int(bar.r * 255), Int(bar.g * 255), Int(bar.b * 255))
        var n = 0, total = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * image.width + x) * 4
                total += 1
                if abs(Int(px[i]) - want.0) <= 24 && abs(Int(px[i + 1]) - want.1) <= 24 && abs(Int(px[i + 2]) - want.2) <= 24 { n += 1 }
            }
        }
        return total > 0 ? Double(n) / Double(total) : nil
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
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        return ctx.makeImage()!
    }
}

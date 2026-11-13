import AppKit
import ContrastInkCore
import ContrastInkPC

/// The drawing layer: a borderless, see-through panel over one whole screen, above normal windows and above a
/// full-screen PowerPoint show, on every Space. With drawing off it ignores the mouse (clicks go to the app below);
/// with drawing on it takes the mouse, and (switched on with F9 or ✏) the keyboard, without activating the app.
final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    /// Only while drawing (the controller decides): then the letter keys reach the drawing layer.
    var mayBecomeKey = false
    override var canBecomeKey: Bool { mayBecomeKey }
    override var canBecomeMain: Bool { false }
}

/// The marks, the shape or line being drawn, and the laser, drawn with Core Graphics (macOS has no PencilKit canvas).
/// The finished marks that don't fade are kept as one picture, drawn again only when they change (a new mark is
/// added to it); a stroke being drawn redraws only the part of the layer it touched.
final class InkView: NSView {
    weak var controller: AppController?
    var board = InkBoard()
    var laser = LaserTrail()
    /// Drawing is on: the view takes the mouse (and paints an all-but-invisible film so every click lands here).
    var drawingOn = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }

    private var live: InkStroke?
    private var liveSquare = false
    private var mouseErasing = false
    private var mouseLaser = false
    /// A pen tablet's eraser end is near the tablet (macOS tells with a proximity event, which the controller's
    /// event monitors pass on: the drawing layer, never the active window, may not get it itself).
    private(set) var eraserEnd = false
    // the picture of the finished marks that don't fade
    private var cache: CGContext?
    private var cacheImage: CGImage?
    private var cacheIDs: [Int] = []
    private var cacheRevision = -1
    private var cacheSize = CGSize.zero, cacheScale: CGFloat = 0
    // the last box an arrow or oval being drawn covered (it moves whole)
    private var liveShapeRect: NSRect?, remoteShapeRect: NSRect?
    /// For the smoke test: finished marks drawn (into the picture or each frame while fading), the last area drawn.
    private(set) var marksDrawn = 0
    private(set) var lastDrawn = NSRect.zero
    private var remote: InkStroke?
    private var remoteErasing = false, remoteLaser = false
    private var timer: Timer?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private var style: MacSettings { controller?.settings ?? MacSettings() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func resetCursorRects() {
        guard drawingOn else { return }
        addCursorRect(bounds, cursor: style.tool == .eraser ? .arrow : .crosshair)
    }

    // MARK: mouse and pen

    private func point(_ e: NSEvent) -> Pt {
        let p = convert(e.locationInWindow, from: nil)
        return Pt(Double(p.x), Double(p.y))
    }

    /// The pen's pressure from a pen tablet (Wacom, XP-Pen, Huion...), nil for a mouse or trackpad.
    private func pressure(_ e: NSEvent) -> Double? {
        e.subtype == .tabletPoint ? Double(e.pressure) : nil
    }

    override func tabletProximity(with event: NSEvent) { proximity(event) }

    /// A pen came near the tablet or left it: which end (the eraser end erases, when that is switched on).
    func proximity(_ event: NSEvent) {
        guard event.type == .tabletProximity || event.subtype == .tabletProximity else { return }
        eraserEnd = event.isEnteringProximity && event.pointingDeviceType == .eraser
    }

    override func mouseDown(with e: NSEvent) {
        guard drawingOn else { return }
        if e.subtype == .tabletProximity { tabletProximity(with: e) }
        let p = point(e), tool = style.tool
        if (eraserEnd && style.penEraserEnd) || tool == .eraser {
            mouseErasing = true
            erase(at: p, radius: 8)
            return
        }
        if tool == .laser {
            mouseLaser = true
            laser.down(p, at: Self.now())
            animate()
            return
        }
        live = InkStroke(tool: tool, start: p, pressure: pressure(e))
        liveSquare = e.modifierFlags.contains(.shift)
        liveShapeRect = nil
        dirty(live, before: 0, square: liveSquare, last: &liveShapeRect)
    }

    override func mouseDragged(with e: NSEvent) {
        guard drawingOn else { return }
        let p = point(e)
        if mouseErasing { erase(at: p, radius: 8); return }
        if mouseLaser { laser.move(p, touching: true, at: Self.now()); animate(); return }
        let before = live?.raw.count ?? 0
        live?.add(p, pressure: pressure(e))
        liveSquare = e.modifierFlags.contains(.shift)
        dirty(live, before: before, square: liveSquare, last: &liveShapeRect)
    }

    override func mouseUp(with e: NSEvent) {
        if mouseErasing { mouseErasing = false; return }
        if mouseLaser {
            mouseLaser = false
            if style.tool != .laser { laser.hideDot() }
            needsDisplay = true
            return
        }
        guard let s = live else { return }
        dirty(s, before: 0, square: liveSquare, last: &liveShapeRect)   // where it was drawn, if it isn't kept
        live = nil
        liveShapeRect = nil
        finish(s, square: e.modifierFlags.contains(.shift), keep: e.modifierFlags.contains(.shift))
    }

    override func rightMouseDown(with e: NSEvent) {
        guard drawingOn, style.undoWithRightClick else { return }
        controller?.undo()
    }

    override func mouseMoved(with e: NSEvent) {
        guard drawingOn, style.tool == .laser, !mouseLaser else { return }
        laser.move(point(e), touching: false, at: Self.now())
        needsDisplay = true
    }

    override func mouseExited(with e: NSEvent) {
        guard !mouseLaser, !remoteLaser, laser.dot != nil else { return }
        laser.hideDot()
        needsDisplay = true
    }

    /// A finished line or shape becomes a mark (fading, when fading ink is on and Shift isn't held).
    private func finish(_ s: InkStroke, square: Bool, keep: Bool) {
        let st = style
        let fading = st.fadingInk && !keep ? Self.now() : nil
        if let m = s.mark(color: st.color, width: st.lineWidth, opacity: st.opacity, fadingSince: fading, square: square) {
            board.add(m)
            controller?.marksChanged()
            invalidate(m)
        }
        animate()
    }

    /// Draws again the part of the layer a stroke being drawn changed: the new piece of a line, or the shape's old
    /// and new box.
    private func dirty(_ s: InkStroke?, before: Int, square: Bool, last: inout NSRect?) {
        guard let s else { return }
        let st = style
        let w = s.tool == .highlighter ? Settings.highlighterWidth(st.lineWidth) : st.lineWidth
        let shape = s.tool == .arrow || s.tool == .oval
        let pts = s.points(width: st.lineWidth, square: square)
        guard let b = InkArea.bounds(InkArea.fresh(pts, drawn: before, wholeShape: shape), pad: w * 0.75 + 3) else { return }
        let r = NSRect(x: b.x, y: b.y, width: b.width, height: b.height)
        setNeedsDisplay(shape ? r.union(last ?? r) : r)
        if shape { last = r }
    }

    /// Draws again where a mark is (or was).
    private func invalidate(_ m: InkMark) {
        guard let b = InkArea.bounds(m.points, pad: m.width * 0.75 + 3) else { return }
        setNeedsDisplay(NSRect(x: b.x, y: b.y, width: b.width, height: b.height))
    }

    private func erase(at p: Pt, radius: Double) {
        if board.erase(at: p, radius: radius) {
            controller?.marksChanged()
            needsDisplay = true
        }
    }

    // MARK: the tablet (fractions of this screen)

    private func fromPad(_ x: Double, _ y: Double) -> Pt { Pt(x * Double(bounds.width), y * Double(bounds.height)) }

    func remoteBegin(_ x: Double, _ y: Double, eraserEnd: Bool) {
        remoteCancel()
        let p = fromPad(x, y), tool = style.tool
        remoteErasing = eraserEnd || tool == .eraser
        remoteLaser = !remoteErasing && tool == .laser
        if remoteErasing { erase(at: p, radius: 16); return }
        if remoteLaser { laser.down(p, at: Self.now()); animate(); return }
        remote = InkStroke(tool: tool, start: p)
        remoteShapeRect = nil
        dirty(remote, before: 0, square: false, last: &remoteShapeRect)
    }

    func remoteMove(_ points: [Pt]) {
        let before = remote?.raw.count ?? 0
        for f in points {
            let p = fromPad(f.x, f.y)
            if remoteErasing { erase(at: p, radius: 16) }
            else if remoteLaser { laser.move(p, touching: true, at: Self.now()) }
            else { remote?.add(p) }
        }
        if remoteLaser { animate(); needsDisplay = true }
        dirty(remote, before: before, square: false, last: &remoteShapeRect)
    }

    func remoteEnd() {
        if remoteLaser { laser.hideDot(); remoteLaser = false; needsDisplay = true }
        remoteErasing = false
        guard let s = remote else { return }
        dirty(s, before: 0, square: false, last: &remoteShapeRect)
        remote = nil
        remoteShapeRect = nil
        finish(s, square: false, keep: false)
    }

    /// A palm or a second finger on the tablet, or the tablet went: the stroke being drawn goes.
    func remoteCancel() {
        if remoteLaser { laser.hideDot(); remoteLaser = false }
        remoteErasing = false
        dirty(remote, before: 0, square: false, last: &remoteShapeRect)
        remote = nil
        remoteShapeRect = nil
        needsDisplay = true
    }

    func remoteHover(_ x: Double, _ y: Double) {
        guard style.tool == .laser else { return }
        laser.move(fromPad(x, y), touching: false, at: Self.now())
        needsDisplay = true
    }

    func remoteHoverEnd() {
        guard style.tool == .laser, !remoteLaser else { return }
        laser.hideDot()
        needsDisplay = true
    }

    // MARK: undo, clear, time

    func undo() -> Bool {
        live = nil
        let done = board.undo(now: Self.now())
        animate()
        needsDisplay = true
        return done
    }

    func clear() {
        live = nil
        remoteCancel()
        board.clear()
        needsDisplay = true
    }

    /// The laser was put away: its dot goes (a line still fading finishes fading).
    func toolChanged() {
        if style.tool != .laser { laser.hideDot() }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// Fading ink and the laser's line need drawing again and again while they fade; nothing runs otherwise.
    private func animate() {
        needsDisplay = true
        guard timer == nil, board.anyFading || !laser.trail.isEmpty else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func frame() {
        let now = Self.now()
        let before = animatedArea()
        if board.fade(now: now) { controller?.marksChanged() }
        laser.prune(now: now)
        let r = before.union(animatedArea())
        if !r.isNull { setNeedsDisplay(r) }
        if !board.anyFading && laser.trail.isEmpty { timer?.invalidate(); timer = nil }
    }

    /// Where fading marks and the laser are: the only part that changes from frame to frame.
    private func animatedArea() -> NSRect {
        var r = NSRect.null
        func add(_ pts: [Pt], _ pad: Double) {
            if let b = InkArea.bounds(pts, pad: pad) { r = r.union(NSRect(x: b.x, y: b.y, width: b.width, height: b.height)) }
        }
        for m in board.marks where m.fadingSince != nil { add(m.points, m.width * 0.75 + 3) }
        add(laser.trail.map(\.p) + (laser.dot.map { [$0] } ?? []), Laser.width(style.lineWidth) * 1.5 + 4)
        return r
    }

    // MARK: drawing

    /// The marks moved to another screen (the controller keeps each screen's own): drawn again whole.
    func replaceBoard(_ b: InkBoard) {
        live = nil
        remoteCancel()
        board = b
        needsDisplay = true
    }

    /// The picture of the finished marks that don't fade: a mark added since is drawn onto it; anything else
    /// (an erase, undo, clear, another size) draws it again from the start.
    private func cachedMarks(scale: CGFloat) -> CGImage? {
        let size = bounds.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        if board.revision == cacheRevision, size == cacheSize, scale == cacheScale { return cacheImage }
        let still = board.marks.filter { $0.fadingSince == nil }
        let ids = still.map(\.id)
        var ctx = cache
        var start = 0
        if ctx == nil || size != cacheSize || scale != cacheScale || !ids.starts(with: cacheIDs) {
            ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            // the layer's own coordinates: top-left origin, in points
            ctx?.translateBy(x: 0, y: size.height * scale)
            ctx?.scaleBy(x: scale, y: -scale)
            cacheIDs = []
        } else {
            start = cacheIDs.count
        }
        guard let c = ctx else { return nil }
        for m in still.dropFirst(start) { draw(m, alpha: m.alpha(at: 0), in: c) }
        cache = c
        cacheIDs = ids
        cacheSize = size
        cacheScale = scale
        cacheRevision = board.revision
        cacheImage = c.makeImage()
        return cacheImage
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        lastDrawn = dirtyRect
        ctx.clear(dirtyRect)
        if drawingOn {
            // all but invisible (0.4%): a see-through window would otherwise let clicks fall through its empty parts
            ctx.setFillColor(NSColor(white: 0, alpha: 0.004).cgColor)
            ctx.fill(dirtyRect)
        }
        let now = Self.now()
        if let image = cachedMarks(scale: window?.backingScaleFactor ?? 2) {
            ctx.saveGState()
            ctx.clip(to: dirtyRect)
            // the picture is upright; this view is flipped
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: bounds.size))
            ctx.restoreGState()
        }
        for m in board.marks where m.fadingSince != nil { draw(m, alpha: m.alpha(at: now), in: ctx) }
        let st = style
        for s in [live, remote].compactMap({ $0 }) {
            let pts = s.points(width: st.lineWidth, square: s == live && liveSquare)
            let hl = s.tool == .highlighter
            let m = InkMark(points: pts, pressures: s.tool == .pen && s.pressures.count == pts.count ? s.pressures : [],
                            color: st.color, width: hl ? Settings.highlighterWidth(st.lineWidth) : st.lineWidth,
                            opacity: hl ? 1 : st.opacity, highlighter: hl)
            draw(m, alpha: m.alpha(at: now), in: ctx, finished: false)
        }
        drawLaser(in: ctx, now: now, width: Laser.width(st.lineWidth))
    }

    /// An ink colour in sRGB, as the toolbar's swatches (NSColor(hex:)), the tablet and the Windows app define it.
    /// `setStrokeColor(red:green:blue:alpha:)` would be device RGB: on a P3 display the same numbers come out more
    /// saturated, so the ink wouldn't match its swatch, the projector or the recording.
    static func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> CGColor {
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!   // MUTATION: device RGB
    }

    private func draw(_ m: InkMark, alpha: Double, in ctx: CGContext, finished: Bool = true) {
        guard alpha > 0, let first = m.points.first else { return }
        if finished { marksDrawn += 1 }
        let c = Ink.rgb(Settings.colors[min(max(m.color, 0), Settings.colors.count - 1)]) ?? (1, 0, 0)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let layered = alpha < 1
        if layered {
            // one see-through layer for the whole mark, so its overlapping pieces don't darken each other
            ctx.setAlpha(CGFloat(alpha))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        ctx.setStrokeColor(Self.srgb(c.r, c.g, c.b, 1))
        ctx.setFillColor(Self.srgb(c.r, c.g, c.b, 1))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if m.points.count == 1 || m.points.allSatisfy({ $0 == first }) {
            let r = m.width(at: 0) / 2
            ctx.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2))
        } else if !m.pressures.isEmpty {
            for i in 1..<m.points.count {
                ctx.setLineWidth(CGFloat((m.width(at: i - 1) + m.width(at: i)) / 2))
                ctx.move(to: CGPoint(x: m.points[i - 1].x, y: m.points[i - 1].y))
                ctx.addLine(to: CGPoint(x: m.points[i].x, y: m.points[i].y))
                ctx.strokePath()
            }
        } else {
            ctx.setLineWidth(CGFloat(m.width))
            ctx.addLines(between: m.points.map { CGPoint(x: $0.x, y: $0.y) })
            ctx.strokePath()
        }
        if layered { ctx.endTransparencyLayer() }
    }

    /// Three passes, as on Windows: a wide soft glow, the red line, a thin bright core (so it reads as light, not ink).
    private func drawLaser(in ctx: CGContext, now: Double, width: Double) {
        let red = Ink.rgb(Laser.color) ?? (1, 0.18, 0.18)
        let segments = laser.segments(now: now)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        for pass in 0..<3 {
            for s in segments {
                switch pass {
                case 0: ctx.setStrokeColor(Self.srgb(red.r, red.g, red.b, s.alpha * 0.25)); ctx.setLineWidth(width * 2.4)
                case 1: ctx.setStrokeColor(Self.srgb(red.r, red.g, red.b, s.alpha)); ctx.setLineWidth(width)
                default: ctx.setStrokeColor(Self.srgb(1, 1, 1, s.alpha * 0.8)); ctx.setLineWidth(width * 0.3)
                }
                ctx.move(to: CGPoint(x: s.a.x, y: s.a.y))
                ctx.addLine(to: CGPoint(x: s.b.x, y: s.b.y))
                ctx.strokePath()
            }
        }
        if let d = laser.dot {
            func dot(_ r: Double, _ col: (Double, Double, Double), _ a: Double) {
                ctx.setFillColor(Self.srgb(col.0, col.1, col.2, a))
                ctx.fillEllipse(in: CGRect(x: d.x - r, y: d.y - r, width: r * 2, height: r * 2))
            }
            dot(width * 1.3, (red.r, red.g, red.b), 0.25)
            dot(width / 2, (red.r, red.g, red.b), 1)
            dot(width * 0.18, (1, 1, 1), 0.85)
        }
    }
}

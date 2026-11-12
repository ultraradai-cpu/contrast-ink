import ContrastInkCore
import UIKit

/// The laser pointer: where Apple Pencil (or a finger, when fingers draw) hovers or touches, in slide points, and the
/// glowing line it leaves while touching. One shared copy, so the projector shows it too. Never a mark.
@MainActor
final class LaserPointer: ObservableObject {
    static let shared = LaserPointer()

    struct Glow { let p: CGPoint; let at: Date; let line: Int }
    private(set) var trail: [Glow] = []
    private(set) var dot: CGPoint?
    /// Anything to draw: the iPad's and the projector's laser layers redraw while this is true.
    @Published private(set) var showing = false
    private var line = 0

    func down(_ p: CGPoint) { line += 1; move(p, touching: true) }

    func move(_ p: CGPoint, touching: Bool) {
        dot = p
        if touching { trail.append(Glow(p: p, at: Date(), line: line)) }
        update()
    }

    /// The Pencil lifted away or the laser was put down: the dot goes; the line fades as it would.
    func hideDot() { dot = nil; update() }

    /// Another slide: nothing of the last one's laser stays.
    func clear() { trail = []; dot = nil; update() }

    /// Drops the bits of line that have faded away (called on each frame while showing).
    func prune(now: Date = Date()) {
        trail.removeAll { Laser.opacity(age: now.timeIntervalSince($0.at)) <= 0 }
        update()
    }

    private func update() {
        let s = dot != nil || !trail.isEmpty
        if s != showing { showing = s }
    }

    /// Draws the laser. `scale`: screen points per slide point; `penWidth`: the chosen pen width (slide points).
    func draw(in ctx: CGContext, scale: CGFloat, penWidth: Double, now: Date = Date()) {
        let w = CGFloat(Laser.width(penWidth)) * scale
        let red = UIColor(hex: Laser.color)
        ctx.setLineCap(.round)
        // three passes: a wide soft glow, the red line, a thin bright core (so it reads as light, not ink)
        let passes: [(UIColor, CGFloat, CGFloat)] = [(red, 0.25, 2.4), (red, 1, 1), (.white, 0.8, 0.3)]
        for (color, alpha, width) in passes {
            ctx.setLineWidth(w * width)
            for i in trail.indices.dropFirst() {
                let a = trail[i - 1], b = trail[i]
                guard a.line == b.line else { continue }
                let o = Laser.opacity(age: now.timeIntervalSince(b.at))
                guard o > 0 else { continue }
                ctx.setStrokeColor(color.withAlphaComponent(alpha * o).cgColor)
                ctx.move(to: CGPoint(x: a.p.x * scale, y: a.p.y * scale))
                ctx.addLine(to: CGPoint(x: b.p.x * scale, y: b.p.y * scale))
                ctx.strokePath()
            }
        }
        if let d = dot {
            let c = CGPoint(x: d.x * scale, y: d.y * scale)
            for (color, alpha, r) in [(red, 0.25, w * 1.3), (red, 1, w / 2), (UIColor.white, 0.85, w * 0.18)] {
                ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
        }
    }
}

/// The laser over the iPad's slide (sized like the canvas): redraws every frame while there is something to show.
final class LaserLayerView: UIView {
    var zoom: CGFloat = 1
    var penWidth: () -> Double = { 6 }
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        accessibilityIdentifier = "laser"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Something changed: redraw now, and keep redrawing while the line fades.
    func kick() {
        setNeedsDisplay()
        guard link == nil else { return }
        let l = CADisplayLink(target: LaserTick { [weak self] in self?.tick() }, selector: #selector(LaserTick.tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func tick() {
        let laser = LaserPointer.shared
        laser.prune()
        setNeedsDisplay()
        if !laser.showing { link?.invalidate(); link = nil }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        LaserPointer.shared.draw(in: ctx, scale: zoom, penWidth: penWidth())
    }

    override func removeFromSuperview() { link?.invalidate(); link = nil; super.removeFromSuperview() }
}

/// CADisplayLink holds its target strongly: this small object breaks the cycle.
private final class LaserTick {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func tick() { action() }
}

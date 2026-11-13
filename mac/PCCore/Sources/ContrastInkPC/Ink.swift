import ContrastInkCore
import Foundation

/// One mark on the drawing layer: a pen or highlighter line, or an arrow or oval drawn as a line. Points are in the
/// drawing layer's points, top-left origin.
public struct InkMark: Equatable, Sendable {
    public var id: Int
    public var points: [Pt]
    /// The pen's pressure at each point (0...1) when it came from a pen tablet; empty for a mouse or a shape.
    public var pressures: [Double]
    /// Index into Settings.colors.
    public var color: Int
    /// Line width in points (the highlighter's is already its wide width).
    public var width: Double
    /// 1 = solid. The highlighter keeps its own see-through look.
    public var opacity: Double
    public var highlighter: Bool
    /// When it began fading (seconds on the app's clock); nil: it stays.
    public var fadingSince: Double?

    public init(id: Int = 0, points: [Pt], pressures: [Double] = [], color: Int, width: Double, opacity: Double = 1,
                highlighter: Bool = false, fadingSince: Double? = nil) {
        self.id = id; self.points = points; self.pressures = pressures; self.color = color; self.width = width
        self.opacity = opacity; self.highlighter = highlighter; self.fadingSince = fadingSince
    }

    /// How see-through the highlighter is.
    public static let highlighterAlpha = 0.4

    /// How visible it is now: its opacity, times its fading.
    public func alpha(at now: Double) -> Double {
        let base = highlighter ? Self.highlighterAlpha : opacity
        guard let f = fadingSince else { return base }
        return base * Fade.opacity(age: now - f)
    }

    /// The line's width at point i: the pen's pressure thins and thickens it (from 40% to 140%).
    public func width(at i: Int) -> Double {
        guard i < pressures.count else { return width }
        let p = min(max(pressures[i], 0), 1)
        return width * (0.4 + p)
    }

    /// True when `p` is within `radius` of the line (its own thickness counts).
    public func touches(_ p: Pt, radius: Double) -> Bool {
        let r = radius + width / 2
        if points.count == 1 { return Ink.distance(p, points[0]) <= r }
        for i in 1..<max(points.count, 1) where Ink.distance(p, segment: points[i - 1], points[i]) <= r { return true }
        return false
    }
}

/// The marks on the drawing layer and their undo history: the same rules as the Windows overlay. Undo takes back
/// the last step (a mark, an erase, a clear); a mark that already faded away is skipped, the step before it is undone.
public struct InkBoard: Equatable, Sendable {
    public private(set) var marks: [InkMark] = []
    private enum Step: Equatable, Sendable { case added([InkMark]), removed([InkMark]) }
    private var history: [Step] = []
    private var nextID = 1
    public static let historyLimit = 300
    /// Goes up with every change to the marks: the drawing layer keeps a picture of the finished marks and draws it
    /// again only when this has changed.
    public private(set) var revision = 0

    public init() {}

    public var isEmpty: Bool { marks.isEmpty }

    /// True when undo would change something (a step whose marks all faded away doesn't count).
    public var canUndo: Bool {
        history.contains { step in
            switch step {
            case .added(let m): return m.contains { a in marks.contains { $0.id == a.id } }
            case .removed(let m): return m.contains { a in !marks.contains { $0.id == a.id } }
            }
        }
    }

    /// A finished mark: kept, and remembered for undo. Its id is given here.
    @discardableResult
    public mutating func add(_ mark: InkMark) -> Int {
        var m = mark
        m.id = nextID
        nextID += 1
        marks.append(m)
        remember(.added([m]))
        revision += 1
        return m.id
    }

    /// The eraser touched `p`: every mark within `radius` goes (undo brings them back). True when one went.
    @discardableResult
    public mutating func erase(at p: Pt, radius: Double) -> Bool {
        let hit = marks.filter { $0.touches(p, radius: radius) }
        guard !hit.isEmpty else { return false }
        marks.removeAll { m in hit.contains { $0.id == m.id } }
        remember(.removed(hit))
        revision += 1
        return true
    }

    /// Removes every mark (undo brings them back).
    public mutating func clear() {
        guard !marks.isEmpty else { return }
        remember(.removed(marks))
        marks = []
        revision += 1
    }

    /// Takes back the last step. A mark that faded away while fading ink was on comes back fading from the start.
    @discardableResult
    public mutating func undo(now: Double) -> Bool {
        while let step = history.popLast() {
            switch step {
            case .added(let added):
                let still = added.filter { a in marks.contains { $0.id == a.id } }
                if still.isEmpty { continue }   // already faded away: undo the step before it
                marks.removeAll { m in still.contains { $0.id == m.id } }
                revision += 1
                return true
            case .removed(let removed):
                let back = removed.filter { r in !marks.contains { $0.id == r.id } }
                if back.isEmpty { continue }
                for var m in back {
                    if m.fadingSince != nil { m.fadingSince = now }
                    marks.append(m)
                }
                marks.sort { $0.id < $1.id }   // back in the order they were drawn (the newest on top)
                revision += 1
                return true
            }
        }
        return false
    }

    /// Fading ink: drops the marks that have faded away. True when one went (draw again).
    @discardableResult
    public mutating func fade(now: Double) -> Bool {
        let before = marks.count
        marks.removeAll { $0.fadingSince != nil && $0.alpha(at: now) <= 0 }
        if marks.count != before { revision += 1 }
        return marks.count != before
    }

    /// The marks (and those undo can bring back) stretched to a screen of another size: a fraction of the screen
    /// stays the same fraction. Widths stay as they are (a line keeps its weight).
    public func scaled(x sx: Double, y sy: Double) -> InkBoard {
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0, sx != 1 || sy != 1 else { return self }
        func f(_ m: InkMark) -> InkMark { var m = m; m.points = m.points.map { Pt($0.x * sx, $0.y * sy) }; return m }
        var b = self
        b.marks = marks.map(f)
        b.history = history.map { step in
            switch step {
            case .added(let m): return .added(m.map(f))
            case .removed(let m): return .removed(m.map(f))
            }
        }
        b.revision += 1
        return b
    }

    /// Whether any mark is fading (the app keeps a timer only while one is).
    public var anyFading: Bool { marks.contains { $0.fadingSince != nil } }

    private mutating func remember(_ s: Step) {
        history.append(s)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }
}

/// A mark being drawn: the pen's or highlighter's line grows, the arrow and oval follow the pointer.
public struct InkStroke: Equatable, Sendable {
    public let tool: Tool
    public let start: Pt
    public private(set) var raw: [Pt]
    public private(set) var pressures: [Double]
    public var end: Pt { raw.last ?? start }

    public init(tool: Tool, start: Pt, pressure: Double? = nil) {
        self.tool = tool
        self.start = start
        raw = [start]
        pressures = pressure.map { [$0] } ?? []
    }

    /// The pointer moved. Points closer than a quarter point to the last are skipped (a resting pen sends many).
    public mutating func add(_ p: Pt, pressure: Double? = nil) {
        if let last = raw.last, Ink.distance(p, last) < 0.25, tool == .pen || tool == .highlighter { return }
        if tool == .arrow || tool == .oval { raw = [start, p]; return }
        guard raw.count < PadPC.maxStrokePoints else { return }
        raw.append(p)
        if let pressure, pressures.count == raw.count - 1 { pressures.append(pressure) }
    }

    /// The points to draw now. `square`: Shift held, an oval becomes a circle.
    public func points(width: Double, square: Bool = false) -> [Pt] {
        switch tool {
        case .arrow: return Shapes.arrow(from: start, to: end, width: width)
        case .oval: return Shapes.oval(start, square ? Shapes.square(start: start, end: end) : end)
        default: return raw
        }
    }

    /// True when a shape is too small to keep (a click with the arrow or oval leaves nothing).
    public var tooSmall: Bool { (tool == .arrow || tool == .oval) && Shapes.tooSmall(start, end) }

    /// The finished mark in the given style (nil for a shape too small to keep, or the eraser and laser).
    public func mark(color: Int, width: Double, opacity: Double, fadingSince: Double?, square: Bool = false) -> InkMark? {
        guard tool == .pen || tool == .highlighter || tool == .arrow || tool == .oval, !tooSmall else { return nil }
        let hl = tool == .highlighter
        let w = hl ? Settings.highlighterWidth(width) : width
        let pts = points(width: width, square: square)
        let pr = tool == .pen && pressures.count == pts.count ? pressures : []
        return InkMark(points: pts, pressures: pr, color: color, width: w, opacity: hl ? 1 : opacity, highlighter: hl,
                       fadingSince: fadingSince)
    }
}

public enum Ink {
    public static func distance(_ a: Pt, _ b: Pt) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }

    /// The distance from `p` to the segment from `a` to `b`.
    public static func distance(_ p: Pt, segment a: Pt, _ b: Pt) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy
        guard len2 > 0 else { return distance(p, a) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return distance(p, Pt(a.x + t * dx, a.y + t * dy))
    }

    /// "#FF3B30" → (1, 0.23, 0.19); nil for anything else.
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double(v >> 16) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

/// The laser pointer's line and dot (Core's Laser rules): a dot where the pen or mouse is, and while it touches,
/// a line that fades away behind it. Never a mark.
public struct LaserTrail: Equatable, Sendable {
    public struct Point: Equatable, Sendable { public var p: Pt; public var t: Double; public var line: Int }
    public private(set) var trail: [Point] = []
    public private(set) var dot: Pt?
    private var line = 0
    public init() {}

    public var showing: Bool { dot != nil || !trail.isEmpty }

    /// The pen or mouse went down: a new line starts here (not joined to the last one).
    public mutating func down(_ p: Pt, at t: Double) { line += 1; move(p, touching: true, at: t) }

    public mutating func move(_ p: Pt, touching: Bool, at t: Double) {
        dot = p
        if touching { trail.append(Point(p: p, t: t, line: line)) }
    }

    /// The pointer left, or the laser was put away: the dot goes, the line fades as it would.
    public mutating func hideDot() { dot = nil }

    public mutating func clear() { trail = []; dot = nil }

    /// Drops what has faded. True while there is still a line to draw (keep the timer going).
    @discardableResult
    public mutating func prune(now: Double) -> Bool {
        trail.removeAll { Laser.opacity(age: now - $0.t) <= 0 }
        return !trail.isEmpty
    }

    /// The pieces of line to draw now: (from, to, brightness), only within one line.
    public func segments(now: Double) -> [(a: Pt, b: Pt, alpha: Double)] {
        guard trail.count > 1 else { return [] }
        var out: [(Pt, Pt, Double)] = []
        for i in 1..<trail.count where trail[i - 1].line == trail[i].line {
            let o = Laser.opacity(age: now - trail[i].t)
            if o > 0 { out.append((trail[i - 1].p, trail[i].p, o)) }
        }
        return out
    }
}

import Foundation

/// Points for the shape tools (the same rules as the Windows app's Shapes.cs), drawn as one ink line so undo,
/// clear and fading treat them like any mark.
public enum Shapes {
    /// An arrow from `from` to `to`: the shaft, then the two sides of the head.
    /// The head grows with the line width and the arrow's length (but never past half the arrow).
    public static func arrow(from: Pt, to: Pt, width: Double) -> [Pt] {
        let dx = to.x - from.x, dy = to.y - from.y, len = (dx * dx + dy * dy).squareRoot()
        if len < 1 { return [from, to] }
        let head = min(max(width * 4, len * 0.25), len * 0.5)
        let ux = dx / len, uy = dy / len
        let angle = Double.pi / 7   // about 26° each side
        func side(_ a: Double) -> Pt {
            Pt(to.x - head * (ux * cos(a) - uy * sin(a)), to.y - head * (uy * cos(a) + ux * sin(a)))
        }
        return [from, to, side(angle), to, side(-angle)]
    }

    /// An oval fitting the box from `a` to `b` (any corner order), closed.
    public static func oval(_ a: Pt, _ b: Pt, segments: Int = 72) -> [Pt] {
        let cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2, rx = abs(b.x - a.x) / 2, ry = abs(b.y - a.y) / 2
        var pts = (0...segments).map { i -> Pt in
            let t = 2 * Double.pi * Double(i) / Double(segments)
            return Pt(cx + rx * cos(t), cy + ry * sin(t))
        }
        pts[segments] = pts[0]   // exactly closed
        return pts
    }

    /// With Shift held, an oval becomes a circle (the larger side wins), keeping the starting corner.
    public static func square(start: Pt, end: Pt) -> Pt {
        let w = end.x - start.x, h = end.y - start.y, s = max(abs(w), abs(h))
        return Pt(start.x + (w < 0 ? -s : s), start.y + (h < 0 ? -s : s))
    }

    /// Apple's ink smooths a line through its points, which rounds off an arrow's tip. A point given three times is
    /// passed through exactly, so the corners of a shape stay sharp. The first and last points stay single.
    public static func sharpCorners(_ pts: [Pt]) -> [Pt] {
        guard pts.count > 2 else { return pts }
        var out = [pts[0]]
        for p in pts.dropFirst().dropLast() { out += [p, p, p] }
        out.append(pts[pts.count - 1])
        return out
    }

    /// True when a drag is too small to be a shape (a tap): it leaves nothing behind.
    public static func tooSmall(_ a: Pt, _ b: Pt) -> Bool { abs(b.x - a.x) < 4 && abs(b.y - a.y) < 4 }
}

/// Fading ink: a mark stays fully visible for a while, then fades out and is removed.
public enum Fade {
    public static let hold: Double = 2, out: Double = 1

    /// How visible a fading mark is at this age in seconds: 1 = fully, 0 = gone (remove it).
    public static func opacity(age: Double) -> Double {
        if age <= hold { return 1 }
        let t = (age - hold) / out
        return t >= 1 ? 0 : 1 - t
    }
}

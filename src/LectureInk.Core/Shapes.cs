namespace LectureInk.Core;

public readonly record struct Pt(double X, double Y);

/// <summary>Points for the shape tools, drawn as one ink line so undo, clear and fading treat them like any mark.</summary>
public static class Shapes
{
    /// <summary>
    /// An arrow from <paramref name="from"/> to <paramref name="to"/>: the shaft, then the two sides of the head.
    /// The head grows with the line width and the arrow's length (but never past half the arrow).
    /// </summary>
    public static IReadOnlyList<Pt> Arrow(Pt from, Pt to, double width)
    {
        double dx = to.X - from.X, dy = to.Y - from.Y, len = Math.Sqrt(dx * dx + dy * dy);
        if (len < 1) return new[] { from, to };
        double head = Math.Min(Math.Max(width * 4, len * 0.25), len * 0.5);
        double ux = dx / len, uy = dy / len;
        const double angle = Math.PI / 7;   // about 26° each side
        Pt Side(double a) => new(to.X - head * (ux * Math.Cos(a) - uy * Math.Sin(a)),
                                 to.Y - head * (uy * Math.Cos(a) + ux * Math.Sin(a)));
        return new[] { from, to, Side(angle), to, Side(-angle) };
    }

    /// <summary>An oval fitting the box from <paramref name="a"/> to <paramref name="b"/> (any corner order), closed.</summary>
    public static IReadOnlyList<Pt> Oval(Pt a, Pt b, int segments = 72)
    {
        double cx = (a.X + b.X) / 2, cy = (a.Y + b.Y) / 2, rx = Math.Abs(b.X - a.X) / 2, ry = Math.Abs(b.Y - a.Y) / 2;
        var pts = new Pt[segments + 1];
        for (int i = 0; i <= segments; i++)
        {
            double t = 2 * Math.PI * i / segments;
            pts[i] = new Pt(cx + rx * Math.Cos(t), cy + ry * Math.Sin(t));
        }
        pts[segments] = pts[0];   // exactly closed (cos/sin of 2π are not exactly 1/0)
        return pts;
    }

    /// <summary>With Shift held, an oval becomes a circle (the larger side wins), keeping the starting corner.</summary>
    public static Pt Square(Pt start, Pt end)
    {
        double w = end.X - start.X, h = end.Y - start.Y, s = Math.Max(Math.Abs(w), Math.Abs(h));
        return new Pt(start.X + Math.Sign(w == 0 ? 1 : w) * s, start.Y + Math.Sign(h == 0 ? 1 : h) * s);
    }
}

using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;
using ContrastInk.Core;

namespace ContrastInk;

/// <summary>
/// The laser pointer, drawn over the marks: a glowing red dot where the pen or mouse is, and while it touches, a
/// glowing line that fades away behind it (Core's <see cref="Laser"/> rules). Nothing here is ever a mark.
/// </summary>
sealed class LaserView : FrameworkElement
{
    static readonly Color Red = (Color)ColorConverter.ConvertFromString(Laser.Color);
    readonly List<(Point p, DateTime t, int line)> trail = new();
    Point? dot;
    int line;
    double width = 8;
    bool ticking;

    public LaserView() { IsHitTestVisible = false; }

    /// <summary>Anything of the laser on screen (the tablet's picture then includes the marks layer).</summary>
    public bool Showing => dot != null || trail.Count > 0;

    public void SetWidth(double penWidth) { width = Laser.Width(penWidth); InvalidateVisual(); }

    /// <summary>The pen or mouse moved; <paramref name="touching"/>: the line grows.</summary>
    public void Move(Point p, bool touching)
    {
        dot = p;
        if (touching) trail.Add((p, DateTime.UtcNow, line));
        Changed();
    }

    /// <summary>The pen or mouse went down: a new line starts here (not joined to the last one).</summary>
    public void Down(Point p) { line++; Move(p, true); }

    /// <summary>The pointer left, or the laser was put away: the dot goes, the line fades as it would.</summary>
    public void HideDot() { dot = null; Changed(); }

    public void Clear() { trail.Clear(); dot = null; InvalidateVisual(); }

    void Changed()
    {
        InvalidateVisual();
        if (ticking || trail.Count == 0) return;
        ticking = true;
        CompositionTarget.Rendering += Tick;
    }

    void Tick(object? sender, EventArgs e)
    {
        var now = DateTime.UtcNow;
        trail.RemoveAll(x => Laser.Opacity(now - x.t) <= 0);
        InvalidateVisual();
        if (trail.Count > 0) return;
        CompositionTarget.Rendering -= Tick;
        ticking = false;
    }

    static Brush Brush(double alpha) => new SolidColorBrush(Color.FromArgb((byte)(255 * Math.Clamp(alpha, 0, 1)), Red.R, Red.G, Red.B));
    static Brush White(double alpha) => new SolidColorBrush(Color.FromArgb((byte)(255 * Math.Clamp(alpha, 0, 1)), 255, 255, 255));
    static Pen Round(Brush b, double w) => new(b, w) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };

    protected override void OnRender(DrawingContext dc)
    {
        var now = DateTime.UtcNow;
        // three passes: a wide soft glow, the red line, a thin bright core (so it reads as light, not ink)
        for (int pass = 0; pass < 3; pass++)
            for (int i = 1; i < trail.Count; i++)
            {
                var (a, _, la) = trail[i - 1];
                var (b, tb, lb) = trail[i];
                if (la != lb) continue;
                double o = Laser.Opacity(now - tb);
                if (o <= 0) continue;
                var pen = pass switch
                {
                    0 => Round(Brush(o * 0.25), width * 2.4),
                    1 => Round(Brush(o), width),
                    _ => Round(White(o * 0.8), width * 0.3),
                };
                dc.DrawLine(pen, a, b);
            }
        if (dot is { } d)
        {
            dc.DrawEllipse(Brush(0.25), null, d, width * 1.3, width * 1.3);
            dc.DrawEllipse(Brush(1), null, d, width / 2, width / 2);
            dc.DrawEllipse(White(0.85), null, d, width * 0.18, width * 0.18);
        }
    }
}

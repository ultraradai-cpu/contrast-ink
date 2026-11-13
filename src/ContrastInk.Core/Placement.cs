namespace ContrastInk.Core;

/// <summary>A rectangle in screen pixels.</summary>
public readonly record struct Box(int Left, int Top, int Right, int Bottom)
{
    public int Width => Right - Left;
    public int Height => Bottom - Top;
    public bool Contains(int x, int y) => x >= Left && x < Right && y >= Top && y < Bottom;
}

/// <summary>Keeps the toolbar fully on the screen it is on, never moving it to another screen.</summary>
public static class Placement
{
    /// <summary>
    /// Where the toolbar's top-left corner should be so it is wholly inside the work area of the screen holding its
    /// centre (or the nearest screen, if its centre is off every screen). Returns the same corner when nothing is off.
    /// An earlier version used the main screen only, which pulled a toolbar on the projector back onto the laptop.
    /// </summary>
    public static (int left, int top) KeepInside(Box toolbar, IReadOnlyList<Box> workAreas)
    {
        if (workAreas.Count == 0) return (toolbar.Left, toolbar.Top);
        int cx = toolbar.Left + toolbar.Width / 2, cy = toolbar.Top + toolbar.Height / 2;
        var area = workAreas.FirstOrDefault(a => a.Contains(cx, cy));
        if (area == default)
            area = workAreas.OrderBy(a => Distance(a, cx, cy)).First();
        int left = Math.Max(area.Left, Math.Min(toolbar.Left, area.Right - toolbar.Width));
        int top = Math.Max(area.Top, Math.Min(toolbar.Top, area.Bottom - toolbar.Height));
        return (left, top);
    }

    static long Distance(Box a, int x, int y)
    {
        long dx = x < a.Left ? a.Left - x : x >= a.Right ? x - a.Right + 1 : 0;
        long dy = y < a.Top ? a.Top - y : y >= a.Bottom ? y - a.Bottom + 1 : 0;
        return dx * dx + dy * dy;
    }
}

/// <summary>A screen as Windows lists it: its name ("\\.\DISPLAY2") and where it is, in real pixels.</summary>
public readonly record struct Display(string Device, Box Bounds);

/// <summary>
/// Which screen the drawing layer covers. The presenter's choice is kept apart from the screen in use: a projector
/// that drops out for a moment moves the layer to the laptop, and back to the projector when it returns. (Before,
/// the fallback was saved as the choice, so one flicker of the cable moved the layer to the laptop for good.)
/// </summary>
public static class ScreenChoice
{
    /// <summary>
    /// The index in <paramref name="now"/> of the chosen screen: the one with the chosen name and place, else the
    /// chosen name, else the chosen place; when none is there, the first screen (the main one). With no name kept
    /// (a settings file from before), the chosen number, while that many screens are there.
    /// </summary>
    public static int Resolve(IReadOnlyList<Display> now, string? device, Box? bounds, int index)
    {
        if (now.Count == 0) return 0;
        if (device == null && bounds == null) return index >= 0 && index < now.Count ? index : 0;
        int i = Find(now, d => d.Device == device && d.Bounds == bounds);
        if (i < 0 && device != null) i = Find(now, d => d.Device == device);
        if (i < 0 && bounds != null) i = Find(now, d => d.Bounds == bounds);
        return i < 0 ? 0 : i;
    }

    static int Find(IReadOnlyList<Display> list, Func<Display, bool> match)
    {
        for (int i = 0; i < list.Count; i++) if (match(list[i])) return i;
        return -1;
    }
}

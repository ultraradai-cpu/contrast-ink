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

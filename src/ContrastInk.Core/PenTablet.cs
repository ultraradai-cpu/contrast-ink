namespace ContrastInk.Core;

public enum TabletMode { Auto, On, Off }

/// <summary>
/// Pen tablets beside the keyboard (Wacom Intuos and One, XP-Pen Deco, Huion Inspiroy, Gaomon, Veikk...) and pen
/// screens (Wacom Cintiq, XP-Pen Artist, Huion Kamvas, a Surface) both report as pens. A pen screen's pen is where
/// it touches; a tablet's pen moves the cursor, and WPF can place its input as if the tablet covered every screen,
/// so its clicks and marks land in the wrong place (reported with an XP-Pen: no clicks, no drawing). A tablet's pen
/// is therefore used as the mouse it moves. Windows tells the two apart: a pen screen is "integrated" (tied to a
/// display), a tablet is "external".
/// </summary>
public static class PenTablet
{
    /// <summary>Whether the pen is used like a mouse.</summary>
    /// <param name="externalPens">Tablets Windows reports (not tied to a display).</param>
    /// <param name="integratedPens">Pen screens Windows reports (a pen screen's pen must stay a pen).</param>
    public static bool UseAsMouse(TabletMode mode, int externalPens, int integratedPens) => mode switch
    {
        TabletMode.On => true,
        TabletMode.Off => false,
        _ => externalPens > 0 && integratedPens == 0,
    };
}

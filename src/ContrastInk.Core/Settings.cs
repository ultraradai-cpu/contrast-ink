using System.Text.Json;

namespace ContrastInk.Core;

public enum Tool { Pen, Highlighter, Arrow, Oval, Eraser, Laser }

/// <summary>What the app remembers between lectures (saved in %AppData%\ContrastInk\settings.json).</summary>
public sealed class Settings
{
    // Red, yellow, green, cyan and white stand out on dark MR/CT images; black is for white slides; red works on both
    public static readonly string[] Colors = { "#FF3B30", "#FFD60A", "#34C759", "#00D4FF", "#FFFFFF", "#111111" };
    public static readonly string[] ColorNames = { "Red", "Yellow", "Green", "Cyan", "White", "Black" };
    // pen thickness in screen points (×1.5 on a 150% display): thin for labels, thick to be seen in a video
    public static readonly double[] Widths = { 3, 6, 10 };
    public static readonly string[] WidthNames = { "Thin", "Medium", "Thick" };

    /// <summary>The highlighter is a wide, see-through version of the same thickness.</summary>
    public static double HighlighterWidth(double width) => width * 4 + 6;

    public Tool Tool { get; set; } = Tool.Pen;
    public int Color { get; set; }
    public int Width { get; set; } = 1;
    public bool FadingInk { get; set; }
    /// <summary>How solid new marks of the pen, arrow and circle are: 1 = solid, down to 0.1 (the highlighter keeps its own look).</summary>
    public double Opacity { get; set; } = 1;
    public const double MinOpacity = 0.1;
    public int Screen { get; set; }
    /// <summary>
    /// The screen the presenter chose for the drawing layer, by Windows' name for it ("\\.\DISPLAY2") and where it
    /// was (left, top, right, bottom): found again after it drops out and comes back (<see cref="ScreenChoice"/>).
    /// Null in a file from before these existed (then <see cref="Screen"/> is used).
    /// </summary>
    public string? ScreenDevice { get; set; }
    public int[]? ScreenBounds { get; set; }
    /// <summary>Where the toolbar was left; empty until it is first dragged (never NaN: JSON cannot store it).</summary>
    public double? ToolbarX { get; set; }
    public double? ToolbarY { get; set; }
    public bool ToolbarCollapsed { get; set; }

    // ways to undo (⚙ on the toolbar); a settings file from before these existed reads them as on
    /// <summary>While drawing, Z alone undoes the last mark (Ctrl+Z always does).</summary>
    public bool UndoWithZ { get; set; } = true;
    /// <summary>While drawing, a right-click, or the pen's side button, undoes the last mark.</summary>
    public bool UndoWithRightClick { get; set; } = true;
    /// <summary>Touching a mark with the pen's eraser end removes it, whatever tool is chosen.</summary>
    public bool PenEraserEnd { get; set; } = true;
    /// <summary>A small undo button appears beside the last mark (hidden from recordings like the toolbar).</summary>
    public bool UndoButtonByPen { get; set; } = true;
    /// <summary>In a PowerPoint slide show, each slide keeps its own marks: the next slide starts clean, going back shows them again.</summary>
    public bool MarksPerSlide { get; set; } = true;
    /// <summary>Resting the mouse or pen on a toolbar button shows its name ("Pen (P)") under the buttons.</summary>
    public bool ShowButtonNames { get; set; } = true;
    /// <summary>
    /// A pen tablet beside the keyboard (Wacom Intuos/One, XP-Pen, Huion, Gaomon, Veikk...): whether its pen is used like
    /// a mouse. Auto: yes when Windows reports such a tablet and no pen screen. Takes effect when Contrast Ink starts.
    /// </summary>
    public TabletMode PenTabletMode { get; set; } = TabletMode.Auto;
    /// <summary>A tablet (Android or iPad) may connect over the network and be used as a pad that draws here.</summary>
    public bool TabletPad { get; set; }
    /// <summary>
    /// Windows 10: the tablet's picture by Windows' own capture (it sees video and 3D windows the older copy can show
    /// black), although Windows then draws a yellow border around the screen, which the audience and OBS see. Windows
    /// 11 always uses it (no border there).
    /// </summary>
    public bool TabletWindowsCapture { get; set; }

    /// <summary>Keeps every value in range, so a hand-edited or old file can't break the app.</summary>
    public Settings Clean(int screens)
    {
        if (!Enum.IsDefined(Tool)) Tool = Tool.Pen;
        if (!Enum.IsDefined(PenTabletMode)) PenTabletMode = TabletMode.Auto;
        Color = Math.Clamp(Color, 0, Colors.Length - 1);
        Width = Math.Clamp(Width, 0, Widths.Length - 1);
        Screen = screens <= 0 ? 0 : Math.Clamp(Screen, 0, screens - 1);
        Opacity = double.IsFinite(Opacity) ? Math.Clamp(Opacity, MinOpacity, 1) : 1;
        if (ToolbarX is { } x && !double.IsFinite(x)) ToolbarX = null;
        if (ToolbarY is { } y && !double.IsFinite(y)) ToolbarY = null;
        if (ScreenBounds is not { Length: 4 }) ScreenBounds = null;
        if (ScreenDevice is { Length: > 64 }) ScreenDevice = null;
        return this;
    }

    static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public static Settings Load(string path, int screens)
    {
        try { return (JsonSerializer.Deserialize<Settings>(File.ReadAllText(path)) ?? new Settings()).Clean(screens); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException or NotSupportedException)
        { return new Settings().Clean(screens); }
    }

    /// <summary>
    /// Writes the settings. Never throws: settings are a convenience, and a failure here once stopped the app
    /// half way through starting (a NaN position cannot be written as JSON), leaving a toolbar with dead buttons.
    /// </summary>
    public bool Save(string path) => Serialize() is { } json && Write(path, json);

    /// <summary>The settings as the file holds them (null if they can't be written). Cheap: the UI thread calls it,
    /// and the file is written elsewhere (<see cref="Write"/>).</summary>
    public string? Serialize()
    {
        try
        {
            Clean(int.MaxValue);   // never write a value that can't be read back
            return JsonSerializer.Serialize(this, Json);
        }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or JsonException) { return null; }
    }

    /// <summary>
    /// Writes a settings file whole or not at all: into a file beside it, then moved over it in one step. Written in
    /// place, a crash or a full disk mid-write left half a file, and every setting went back to its default.
    /// Never throws.
    /// </summary>
    public static bool Write(string path, string json)
    {
        string temp = path + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            using (var f = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                var bytes = System.Text.Encoding.UTF8.GetBytes(json);
                f.Write(bytes, 0, bytes.Length);
                f.Flush(flushToDisk: true);
            }
            File.Move(temp, path, overwrite: true);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            try { if (File.Exists(temp)) File.Delete(temp); } catch (Exception d) when (d is IOException or UnauthorizedAccessException) { }
            return false;
        }
    }
}

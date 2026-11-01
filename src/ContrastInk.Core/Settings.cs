using System.Text.Json;

namespace ContrastInk.Core;

public enum Tool { Pen, Highlighter, Arrow, Oval, Eraser }

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
    public int Screen { get; set; }
    /// <summary>Where the toolbar was left; empty until it is first dragged (never NaN: JSON cannot store it).</summary>
    public double? ToolbarX { get; set; }
    public double? ToolbarY { get; set; }
    public bool ToolbarCollapsed { get; set; }

    /// <summary>Keeps every value in range, so a hand-edited or old file can't break the app.</summary>
    public Settings Clean(int screens)
    {
        if (!Enum.IsDefined(Tool)) Tool = Tool.Pen;
        Color = Math.Clamp(Color, 0, Colors.Length - 1);
        Width = Math.Clamp(Width, 0, Widths.Length - 1);
        Screen = screens <= 0 ? 0 : Math.Clamp(Screen, 0, screens - 1);
        if (ToolbarX is { } x && !double.IsFinite(x)) ToolbarX = null;
        if (ToolbarY is { } y && !double.IsFinite(y)) ToolbarY = null;
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
    public bool Save(string path)
    {
        try
        {
            Clean(int.MaxValue);   // never write a value that can't be read back
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(this, Json));
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or JsonException)
        { return false; }
    }
}

using System.Text.Json;

namespace LectureInk.Core;

public enum Tool { Pen, Highlighter, Arrow, Oval, Eraser }

/// <summary>What the app remembers between lectures (saved in %AppData%\LectureInk\settings.json).</summary>
public sealed class Settings
{
    public static readonly string[] Colors = { "#E53935", "#FDD835", "#43A047", "#1E88E5", "#FFFFFF" };
    public static readonly string[] ColorNames = { "Red", "Yellow", "Green", "Blue", "White" };
    public static readonly double[] Widths = { 3, 5, 9 };

    public Tool Tool { get; set; } = Tool.Pen;
    public int Color { get; set; }
    public int Width { get; set; } = 1;
    public bool FadingInk { get; set; }
    public int Screen { get; set; }
    public double ToolbarX { get; set; } = double.NaN;
    public double ToolbarY { get; set; } = double.NaN;
    public bool ToolbarCollapsed { get; set; }

    /// <summary>Keeps every value in range, so a hand-edited or old file can't break the app.</summary>
    public Settings Clean(int screens)
    {
        if (!Enum.IsDefined(Tool)) Tool = Tool.Pen;
        Color = Math.Clamp(Color, 0, Colors.Length - 1);
        Width = Math.Clamp(Width, 0, Widths.Length - 1);
        Screen = screens <= 0 ? 0 : Math.Clamp(Screen, 0, screens - 1);
        if (!double.IsFinite(ToolbarX)) ToolbarX = double.NaN;
        if (!double.IsFinite(ToolbarY)) ToolbarY = double.NaN;
        return this;
    }

    static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public static Settings Load(string path, int screens)
    {
        try { return (JsonSerializer.Deserialize<Settings>(File.ReadAllText(path)) ?? new Settings()).Clean(screens); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException or NotSupportedException)
        { return new Settings().Clean(screens); }
    }

    public void Save(string path)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(this, Json));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { /* settings are a convenience */ }
    }
}

namespace ContrastInk.Core;

/// <summary>
/// The laser pointer: a glowing dot that follows the pen or mouse, and, while touching, a glowing line that fades away
/// behind it. Never a mark: not saved with the slide, not undone, not erased.
/// </summary>
public static class Laser
{
    public const string Color = "#FF2D2D";
    /// <summary>Each bit of the line stays bright this long after it was drawn...</summary>
    public static readonly TimeSpan Hold = TimeSpan.FromMilliseconds(600);
    /// <summary>...then fades out over this long.</summary>
    public static readonly TimeSpan Out = TimeSpan.FromMilliseconds(600);

    /// <summary>How bright a bit of the line drawn this long ago is: 1 = fully, 0 = gone (drop it).</summary>
    public static double Opacity(TimeSpan age)
    {
        if (age <= Hold) return 1;
        double t = (age - Hold).TotalMilliseconds / Out.TotalMilliseconds;
        return t >= 1 ? 0 : 1 - t;
    }

    /// <summary>The dot's and line's width for the chosen pen width: easy to see from the back of a lecture hall.</summary>
    public static double Width(double penWidth) => Math.Max(8, penWidth * 1.6);
}

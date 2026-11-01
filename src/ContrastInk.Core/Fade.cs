namespace ContrastInk.Core;

/// <summary>Fading ink: a mark stays fully visible for a while, then fades out and is removed.</summary>
public static class Fade
{
    public static readonly TimeSpan Hold = TimeSpan.FromSeconds(2);
    public static readonly TimeSpan Out = TimeSpan.FromSeconds(1);

    /// <summary>How visible a fading mark is at this age: 1 = fully, 0 = gone (remove it).</summary>
    public static double Opacity(TimeSpan age)
    {
        if (age <= Hold) return 1;
        double t = (age - Hold).TotalMilliseconds / Out.TotalMilliseconds;
        return t >= 1 ? 0 : 1 - t;
    }
}

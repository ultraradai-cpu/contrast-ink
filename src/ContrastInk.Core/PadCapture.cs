namespace ContrastInk.Core;

/// <summary>
/// Which way the Windows app makes the tablet's picture, decided per picture. Windows.Graphics.Capture ("WGC") sees
/// GPU-drawn windows the GDI copy can miss, but on Windows 10 (before build 20348) Windows draws a yellow border around
/// the screen while it runs, which the audience sees and OBS records. So:
/// <list type="bullet">
/// <item>Windows 11 (20348 and later): WGC.</item>
/// <item>Windows 10: the GDI copy, unless the presenter switched WGC on (⚙), or the GDI copy came back black while
/// WGC's isn't (a video or 3D window GDI can't see): then WGC for the rest of that tablet's connection.</item>
/// <item>A WGC failure never switches it off for good: GDI for <see cref="RetryAfter"/>, then WGC again; a new
/// connection tries again at once.</item>
/// <item>HDR on the screen: GDI (Windows hands GDI an SDR picture; WGC's 8-bit copy of an HDR screen is washed out).</item>
/// </list>
/// Kept free of Windows calls, so it is tested anywhere.
/// </summary>
public sealed class PadCaptureChoice
{
    public static readonly TimeSpan RetryAfter = TimeSpan.FromSeconds(15);
    public const int BorderlessBuild = 20348;

    readonly bool wgcAvailable, borderless;
    DateTime offUntil = DateTime.MinValue;
    bool gdiBlack;       // this connection: the GDI copy was black, WGC is tried
    bool wgcConfirmed;   // ...and WGC's picture wasn't black: WGC for the rest of the connection

    /// <param name="wgcAvailable">This Windows has WGC (10 2004 or later, and the capture service).</param>
    /// <param name="windowsBuild">Windows' build number: from <see cref="BorderlessBuild"/> on, no border.</param>
    public PadCaptureChoice(bool wgcAvailable, int windowsBuild)
    {
        this.wgcAvailable = wgcAvailable;
        borderless = windowsBuild >= BorderlessBuild;
    }

    /// <summary>The presenter's choice in ⚙: WGC on Windows 10 too, border and all.</summary>
    public bool UserWantsWgc { get; set; }
    /// <summary>The screen is in HDR (advanced colour): GDI.</summary>
    public bool Hdr { get; set; }

    /// <summary>Whether to try WGC for the next picture.</summary>
    public bool UseWgc(DateTime now) =>
        wgcAvailable && !Hdr && now >= offUntil && (borderless || UserWantsWgc || gdiBlack || wgcConfirmed);

    /// <summary>WGC failed (or froze, or its picture was black while GDI's wasn't): GDI for a while.</summary>
    public void WgcFailed(DateTime now)
    {
        offUntil = now + RetryAfter;
        gdiBlack = false;
        wgcConfirmed = false;
    }

    /// <summary>A WGC picture that wasn't black.</summary>
    public void WgcGood() { if (gdiBlack) wgcConfirmed = true; }

    /// <summary>
    /// WGC's picture was black too (the screen really is black): back to GDI, which shows no border. True if that
    /// changed the choice.
    /// </summary>
    public bool BothBlack(DateTime now)
    {
        if (borderless || UserWantsWgc || !gdiBlack) return false;
        WgcFailed(now);
        return true;
    }

    /// <summary>The GDI copy came back black. True if WGC is worth trying for the next picture.</summary>
    public bool GdiCameBackBlack(DateTime now)
    {
        if (!wgcAvailable || Hdr || now < offUntil || gdiBlack || wgcConfirmed) return false;
        gdiBlack = true;
        return true;
    }

    /// <summary>A tablet connected: every earlier failure forgotten.</summary>
    public void NewConnection()
    {
        offUntil = DateTime.MinValue;
        gdiBlack = false;
        wgcConfirmed = false;
    }

    /// <summary>
    /// A picture (32-bit BGRx, any alpha) that is nearly all black: at least 97% of its pixels (sampled) darker than
    /// 16 in every channel. A slide is never that; a failed copy of a GPU window is.
    /// </summary>
    public static bool MostlyBlack(ReadOnlySpan<byte> bgrx, int width, int height)
    {
        if (width <= 0 || height <= 0 || bgrx.Length < width * height * 4) return false;
        int step = Math.Max(1, (int)Math.Sqrt((double)width * height / 20000));   // about 20 000 samples
        long all = 0, dark = 0;
        for (int y = 0; y < height; y += step)
            for (int x = 0; x < width; x += step)
            {
                int i = (y * width + x) * 4;
                all++;
                if (bgrx[i] < 16 && bgrx[i + 1] < 16 && bgrx[i + 2] < 16) dark++;
            }
        return all > 0 && dark >= all * 0.97;
    }
}

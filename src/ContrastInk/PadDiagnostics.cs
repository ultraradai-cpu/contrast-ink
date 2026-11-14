using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

namespace ContrastInk;

/// <summary>What the drawing layer is doing, read from the tablet link's picture thread (no UI thread needed).</summary>
readonly record struct PadLayerState(IntPtr Hwnd, bool RemoteDown, bool Marks, int Page);

/// <summary>
/// Always-on notes about the tablet's picture, for a PC where it goes wrong (the tablet's picture black while writing
/// could not be made to happen on the build machines). Kept on this PC only, in %AppData%\ContrastInk:
///   pad-diagnostics.txt   one line when a tablet connects, at every change of how the picture is made, for the
///                         first 3 mostly-black pictures of each connection, and for the first picture made while the
///                         tablet's pen was down. No picture content, no tablet name: sizes, flags, Windows' numbers.
///                         Kept under about 200 KB (the oldest lines go).
///   pad-black.jpg         the first mostly-black picture of each connection (overwritten each time)
///   pad-during-stroke.jpg the first picture made while the tablet's pen was down, each connection (overwritten)
/// The two pictures may show the slide: they never leave this PC unless the presenter sends them.
/// Every write is best-effort: a full disk or a locked file never stops the tablet's picture.
/// </summary>
sealed class PadDiagnostics
{
    public static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ContrastInk");
    public static string LogPath => Path.Combine(Folder, "pad-diagnostics.txt");
    public static string BlackPath => Path.Combine(Folder, "pad-black.jpg");
    public static string DuringStrokePath => Path.Combine(Folder, "pad-during-stroke.jpg");
    const long MaxBytes = 200 * 1024, KeepBytes = 120 * 1024;
    const int BlackLinesPerConnection = 3;

    readonly object gate = new();
    int blackLines;
    bool blackSaved, strokeSaved;
    static readonly string windows = WindowsBuild(), gpu = DisplayAdapter();

    /// <summary>A tablet connected: the per-connection counts start again, and a line says what this PC is.</summary>
    public void Connected(bool usb, Native.RECT screen, PadLayerState layer, string path)
    {
        lock (gate) { blackLines = 0; blackSaved = false; strokeSaved = false; }
        Line($"tablet connected ({(usb ? "USB" : "Wi-Fi")}); graphics: {gpu}; WPF render tier {OverlayWindow.RenderTier}", screen, null, path, layer, null, false);
    }

    /// <summary>The way the picture is made changed (<see cref="PadServer"/>'s Used).</summary>
    public void PathChanged(Native.RECT screen, int w, int h, string path, PadLayerState layer, bool? wgcBlack, bool gdiBlack) =>
        Line("capture path now: " + path, screen, (w, h), path, layer, wgcBlack, gdiBlack);

    /// <summary>
    /// One picture, before it is made into a JPEG: a line (and a saved copy) if it is mostly black, or the first made
    /// while the tablet's pen is down. <paramref name="jpeg"/> makes the copy only when one is wanted.
    /// </summary>
    public void Picture(bool black, Native.RECT screen, int w, int h, string path, PadLayerState layer, bool? wgcBlack, bool gdiBlack,
        bool held, Func<byte[]> jpeg)
    {
        bool lineBlack, saveBlack, saveStroke;
        lock (gate)
        {
            lineBlack = black && blackLines < BlackLinesPerConnection;
            if (lineBlack) blackLines++;
            saveBlack = black && !blackSaved;
            if (saveBlack) blackSaved = true;
            saveStroke = layer.RemoteDown && !strokeSaved;
            if (saveStroke) strokeSaved = true;
        }
        string extra = held ? "; the last good picture was sent instead, with the marks over it" : "";
        if (lineBlack) Line("mostly-black picture" + extra, screen, (w, h), path, layer, wgcBlack, gdiBlack);
        if (saveStroke) Line("first picture during a tablet stroke" + (black ? " (mostly black)" : " (not black)") + extra, screen, (w, h), path, layer, wgcBlack, gdiBlack);
        if (!saveBlack && !saveStroke) return;
        byte[] bytes;
        try { bytes = jpeg(); } catch (Exception e) { App.Log(e); return; }
        if (saveBlack) Save(BlackPath, bytes);
        if (saveStroke) Save(DuringStrokePath, bytes);
    }

    /// <summary>
    /// Mostly black, as the tablet would show it: 64 points (an 8 x 8 grid) of the picture, 58 or more of them darker
    /// than 16 in every channel. A see-through pixel (alpha 0) counts as black: the JPEG makes it black.
    /// </summary>
    public static bool MostlyBlack(System.Windows.Media.Imaging.BitmapSource pic)
    {
        try
        {
            System.Windows.Media.Imaging.BitmapSource src = pic;
            var f = pic.Format;
            if (f != System.Windows.Media.PixelFormats.Bgr32 && f != System.Windows.Media.PixelFormats.Bgra32 && f != System.Windows.Media.PixelFormats.Pbgra32)
                src = new System.Windows.Media.Imaging.FormatConvertedBitmap(pic, System.Windows.Media.PixelFormats.Bgra32, null, 0);
            int w = src.PixelWidth, h = src.PixelHeight, dark = 0;
            if (w < 1 || h < 1) return false;
            bool alpha = src.Format != System.Windows.Media.PixelFormats.Bgr32;
            var px = new byte[4];
            for (int gy = 0; gy < 8; gy++)
                for (int gx = 0; gx < 8; gx++)
                {
                    int x = Math.Min(w - 1, (int)((gx + 0.5) * w / 8)), y = Math.Min(h - 1, (int)((gy + 0.5) * h / 8));
                    src.CopyPixels(new System.Windows.Int32Rect(x, y, 1, 1), px, 4, 0);
                    if ((alpha && px[3] == 0) || (px[0] < 16 && px[1] < 16 && px[2] < 16)) dark++;
                }
            return dark >= 58;
        }
        catch (Exception e) when (e is InvalidOperationException or ArgumentException or NotSupportedException or COMException) { return false; }
    }

    void Line(string what, Native.RECT r, (int w, int h)? size, string path, PadLayerState layer, bool? wgcBlack, bool gdiBlack)
    {
        var sb = new StringBuilder();
        sb.Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff")).Append(' ').Append(what);
        sb.Append(" | Windows ").Append(windows);
        sb.Append(" | screen ").Append($"{r.Left},{r.Top},{r.Right},{r.Bottom}");
        sb.Append(" dpi ").Append(layer.Hwnd != IntPtr.Zero ? GetDpiForWindow(layer.Hwnd).ToString() : "?");
        if (size is { } s) sb.Append(" | picture ").Append(s.w).Append('x').Append(s.h);
        sb.Append(" | path ").Append(path.Length > 0 ? path : "(none yet)");
        sb.Append(" | tablet stroke ").Append(layer.RemoteDown ? "in progress" : "no");
        sb.Append(" | marks ").Append(layer.Marks ? "yes" : "no");
        sb.Append(" | wgc LastWasBlack ").Append(wgcBlack is { } b ? (b ? "yes" : "no") : "-");
        sb.Append(" | gdiBlack ").Append(gdiBlack ? "yes" : "no");
        sb.Append(" | layer exstyle ").Append(layer.Hwnd != IntPtr.Zero ? ExStyleText(layer.Hwnd) : "(no window)");
        sb.Append('\n');
        lock (gate)
        {
            try
            {
                Directory.CreateDirectory(Folder);
                var file = LogPath;
                File.AppendAllText(file, sb.ToString());
                if (new FileInfo(file).Length > MaxBytes) Trim(file);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }

    /// <summary>The newest lines kept (about 120 KB), starting at a whole line.</summary>
    static void Trim(string file)
    {
        var all = File.ReadAllBytes(file);
        int from = all.Length - (int)KeepBytes;
        if (from <= 0) return;
        int nl = Array.IndexOf(all, (byte)'\n', from);
        from = nl < 0 ? from : nl + 1;
        var tail = new byte[all.Length - from];
        Array.Copy(all, from, tail, 0, tail.Length);
        File.WriteAllBytes(file, tail);
    }

    void Save(string file, byte[] bytes)
    {
        lock (gate)
        {
            try { Directory.CreateDirectory(Folder); File.WriteAllBytes(file, bytes); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }

    static string ExStyleText(IntPtr hwnd)
    {
        long s = GetWindowLongPtr(hwnd, Native.GWL_EXSTYLE).ToInt64();
        var names = new StringBuilder($"0x{s:X8}");
        if ((s & Native.WS_EX_LAYERED) != 0) names.Append(" LAYERED");
        if ((s & Native.WS_EX_TRANSPARENT) != 0) names.Append(" TRANSPARENT");
        if ((s & Native.WS_EX_TOOLWINDOW) != 0) names.Append(" TOOLWINDOW");
        if ((s & Native.WS_EX_NOACTIVATE) != 0) names.Append(" NOACTIVATE");
        if ((s & 0x8) != 0) names.Append(" TOPMOST");
        if (GetWindowDisplayAffinity(hwnd, out var a)) names.Append($" affinity {a}");
        return names.ToString();
    }

    static string WindowsBuild()
    {
        var v = Environment.OSVersion.Version;
        string ubr = "";
        try
        {
            using var k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
            if (k?.GetValue("UBR") is int u) ubr = "." + u;
        }
        catch (Exception e) when (e is System.Security.SecurityException or IOException or UnauthorizedAccessException) { }
        return $"{v.Major}.{v.Minor}.{v.Build}{ubr}";
    }

    /// <summary>The display adapters' names ("NVIDIA GeForce RTX 3060, Intel(R) UHD Graphics"): which GPU draws matters here.</summary>
    static string DisplayAdapter()
    {
        try
        {
            var names = new System.Collections.Generic.List<string>();
            var d = new DISPLAY_DEVICE { cb = Marshal.SizeOf<DISPLAY_DEVICE>() };
            for (uint i = 0; i < 16 && EnumDisplayDevices(null, i, ref d, 0); i++, d = new DISPLAY_DEVICE { cb = Marshal.SizeOf<DISPLAY_DEVICE>() })
                if (!string.IsNullOrEmpty(d.DeviceString) && !names.Any(n => n.StartsWith(d.DeviceString, StringComparison.Ordinal))) names.Add(d.DeviceString + ((d.StateFlags & 4) != 0 ? " (main)" : ""));
            return names.Count > 0 ? string.Join(", ", names) : "unknown";
        }
        catch (Exception) { return "unknown"; }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string? device, uint index, ref DISPLAY_DEVICE dd, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern bool GetWindowDisplayAffinity(IntPtr hwnd, out uint affinity);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
}

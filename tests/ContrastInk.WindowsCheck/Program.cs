// Contrast Ink: the Windows check.
// Starts the real ContrastInk.exe over a white "slide" window, uses it with simulated mouse and keys, and reads the
// screen back pixel by pixel. Every check prints what it measured. Screenshots go to the output folder.
//
//   ContrastInk.WindowsCheck.exe <path to ContrastInk.exe> <output folder> normal|control
//
// "control" starts the app with hiding from capture switched off (CONTRASTINK_TEST_NOHIDE=1) and requires the check
// to SEE the toolbar: proof that the "toolbar is hidden" check can fail.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Windows.Forms;
using ContrastInk.Core;

static class Program
{
    static string exe = "", outDir = "", runMode = "normal";
    static Slide slide = null!;
    static readonly List<string> lines = new();
    static int failures;
    static Rectangle screen;
    static double scale = 1;   // screen pixels per WPF point

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length < 3) { Console.Error.WriteLine("usage: <ContrastInk.exe> <out dir> normal|control"); return 2; }
        (exe, outDir, runMode) = (Path.GetFullPath(args[0]), Path.GetFullPath(args[1]), args[2]);
        Directory.CreateDirectory(outDir);
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        screen = Screen.PrimaryScreen!.Bounds;
        slide = new Slide(screen);
        int code = 1;
        slide.Shown += (_, _) => new Thread(() =>
        {
            try { code = Run(); }
            catch (Exception e) { Log("FAIL  the check itself crashed: " + e); code = 1; }
            finally
            {
                File.WriteAllLines(Path.Combine(outDir, $"results-{runMode}.txt"), lines);
                slide.BeginInvoke(() => slide.Close());
            }
        }) { IsBackground = true }.Start();
        Application.Run(slide);
        return code;
    }

    static void Log(string s) { lines.Add(s); Console.WriteLine(s); }
    static void Check(bool ok, string what, string measured)
    {
        if (!ok) failures++;
        Log($"{(ok ? "PASS" : "FAIL")}  {what}  [{measured}]");
    }

    static int Run()
    {
        Log($"Contrast Ink Windows check ({runMode}) on Windows build {Environment.OSVersion.Version.Build}, screen {screen.Width}x{screen.Height}");
        string status = Path.Combine(outDir, $"status-{runMode}.json");
        File.Delete(status);
        // fresh settings, so every run starts from the defaults
        var settingsFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ContrastInk", "settings.json");
        if (File.Exists(settingsFile)) File.Delete(settingsFile);
        var psi = new ProcessStartInfo(exe) { UseShellExecute = false };
        psi.Environment["CONTRASTINK_TEST"] = "1";
        psi.Environment["CONTRASTINK_STATUS"] = status;
        if (runMode == "control") psi.Environment["CONTRASTINK_TEST_NOHIDE"] = "1";
        using var app = Process.Start(psi)!;
        try
        {
            var sw = Stopwatch.StartNew();
            while (!File.Exists(status) && sw.Elapsed.TotalSeconds < 20) Thread.Sleep(200);
            Thread.Sleep(800);
            Check(File.Exists(status), "the app starts and reports its state", File.Exists(status) ? "status written" : "no status after 20 s");
            if (!File.Exists(status)) { Shot("no-start"); return 1; }
            var st = JsonDocument.Parse(File.ReadAllText(status)).RootElement;
            Log("      app status: " + st.GetRawText());
            if (st.TryGetProperty("error", out var err)) { Check(false, "the app could read its own state", err.GetString() ?? ""); return failures; }
            scale = st.GetProperty("dpi").GetUInt32() / 96.0;
            int[] tb = st.GetProperty("toolbar").EnumerateArray().Select(e => e.GetInt32()).ToArray();
            var toolbar = Rectangle.FromLTRB(tb[0], tb[1], tb[2], tb[3]);

            if (runMode == "control")
            {
                double dark = ToolbarDarkShare(Shot("control-toolbar"), toolbar);
                Check(dark > 0.3, "CONTROL: with hiding switched off, a screen capture DOES show the toolbar", $"{dark:P0} of the toolbar's area is toolbar colour");
                return failures;
            }
            Normal(st, toolbar);
            return failures;
        }
        finally
        {
            Log("      app still running at the end: " + !app.HasExited + (app.HasExited ? ", exit code " + app.ExitCode : ""));
            try { if (!app.HasExited) app.Kill(); } catch (InvalidOperationException) { }
            // the app's own error log, if it wrote one
            var errLog = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ContrastInk", "error.log");
            if (File.Exists(errLog)) { Log("      app error.log:"); foreach (var l in File.ReadAllLines(errLog)) Log("        " + l); File.Delete(errLog); }
        }
    }

    // ---------------------------------------------------------------- the checks
    static void Normal(JsonElement st, Rectangle toolbar)
    {
        Check(st.GetProperty("hooksWorking").GetBoolean(), "keyboard and pen watcher installed", "hooksWorking=" + st.GetProperty("hooksWorking"));
        Check(st.GetProperty("hiddenFromCapture").GetBoolean(), "the app reports the toolbar hidden from capture", "hiddenFromCapture=" + st.GetProperty("hiddenFromCapture"));
        double dark = ToolbarDarkShare(Shot("01-start"), toolbar);
        Check(dark < 0.05, "a screen capture does NOT show the toolbar", $"{dark:P1} of the toolbar's area is toolbar colour (the control run must show it)");

        int W = screen.Width, H = screen.Height;
        int x1 = (int)(W * 0.12), x2 = (int)(W * 0.58), xm = (int)(W * 0.35);
        var clickSpot = new Point((int)(W * 0.85), (int)(H * 0.9));

        // click-through
        int c0 = slide.Clicks; Click(clickSpot); Thread.Sleep(300);
        Check(slide.Clicks == c0 + 1, "drawing off: a click reaches the window underneath", $"clicks {c0} -> {slide.Clicks}");
        Check(Native.GetForegroundWindow() == slide.Hwnd, "the window underneath keeps the keyboard", "foreground is the slide window: " + (Native.GetForegroundWindow() == slide.Hwnd));

        // the toolbar's draw button (found by its accessible name), clicked with the real mouse
        var drawBtn = FindToolbarButton("Draw on / off");
        Check(drawBtn != null, "the toolbar's Draw button is there and named for screen readers", drawBtn?.ToString() ?? "not found");
        if (drawBtn != null) { Click(drawBtn.Value); Thread.Sleep(300); }
        c0 = slide.Clicks; Click(clickSpot); Thread.Sleep(300);
        Check(slide.Clicks == c0, "after clicking the toolbar's Draw button, a click no longer reaches the window underneath", $"clicks {c0} -> {slide.Clicks}");
        Check(Native.GetForegroundWindow() == slide.Hwnd, "clicking the toolbar did not take the keyboard from the window underneath", "foreground is the slide window: " + (Native.GetForegroundWindow() == slide.Hwnd));
        Key(VK.F9); Thread.Sleep(300);
        c0 = slide.Clicks; Click(clickSpot); Thread.Sleep(300);
        Check(slide.Clicks == c0 + 1, "F9 switches drawing off again: clicks reach the window underneath", $"clicks {c0} -> {slide.Clicks}");
        Key(VK.F9); Thread.Sleep(300);
        Key('C'); Thread.Sleep(200);

        // colours: one line per colour, across the white slide and the black stripe
        int stripeX = slide.StripeCenterX;
        for (int i = 0; i < Settings.Colors.Length; i++)
        {
            Key((char)('1' + i)); Thread.Sleep(120);
            int y = Row(i);
            Drag(new Point(x1, y), new Point(stripeX + 30, y));
        }
        Thread.Sleep(400);
        var shot = Shot("02-colours");
        for (int i = 0; i < Settings.Colors.Length; i++)
        {
            var want = ColorTranslator.FromHtml(Settings.Colors[i]);
            bool white = Settings.ColorNames[i] == "White";
            int x = white ? stripeX : xm;   // white is checked on the black stripe
            var got = Closest(shot, x, Row(i), want, 8);
            Check(Diff(got, want) <= 40, $"colour {i + 1} ({Settings.ColorNames[i]}) draws in its colour", $"want {Hex(want)}, screen has {Hex(got)}");
        }

        // thickness: thin, medium, thick, measured across the line
        Key('C'); Key('1'); Thread.Sleep(150);
        int[] widthsPx = new int[3];
        Key((char)0xDB); Key((char)0xDB); Thread.Sleep(150);   // [ [ : thin
        for (int w = 0; w < 3; w++)
        {
            int y = Row(w);
            Drag(new Point(x1, y), new Point(x2, y));
            Key((char)0xDD); Thread.Sleep(150);   // ] : one thicker
        }
        Thread.Sleep(400);
        shot = Shot("03-thickness");
        for (int w = 0; w < 3; w++)
        {
            widthsPx[w] = Thickness(shot, xm, Row(w));
            double want = Settings.Widths[w] * scale;
            Check(Math.Abs(widthsPx[w] - want) <= Math.Max(2, want * 0.35), $"{Settings.WidthNames[w]} line is about {want:0} px thick", $"measured {widthsPx[w]} px");
        }
        Check(widthsPx[0] < widthsPx[1] && widthsPx[1] < widthsPx[2], "thin < medium < thick", string.Join(" < ", widthsPx));

        // highlighter: see-through over dark content
        Key('C'); Key('H'); Key('2'); Thread.Sleep(150);
        int hy = Row(1);
        Drag(new Point(x1, hy), new Point(stripeX + 30, hy));
        Thread.Sleep(400);
        shot = Shot("04-highlighter");
        var onWhite = shot.GetPixel(xm, hy);
        var onStripe = shot.GetPixel(stripeX, hy);
        Check(onWhite.B < 160 && onWhite.R > 180 && onWhite.G > 150, "highlighter leaves a yellow band on the white slide", Hex(onWhite));
        Check(onStripe.R + onStripe.G + onStripe.B < 450, "highlighter is see-through: the black stripe still shows under it", "on the stripe: " + Hex(onStripe));
        int hw = Thickness(shot, xm, hy);
        Check(hw > widthsPx[2], "highlighter band is wider than the thick pen", $"{hw} px vs thick pen {widthsPx[2]} px");

        // arrow
        Key('C'); Key('A'); Key('1'); Thread.Sleep(150);
        int ay = Row(3);
        var a1 = new Point(x1, ay); var a2 = new Point(xm + (int)(W * 0.1), ay);
        Drag(a1, a2);
        Thread.Sleep(400);
        shot = Shot("05-arrow");
        var head = Shapes.Arrow(new Pt(a1.X, a1.Y), new Pt(a2.X, a2.Y), Settings.Widths[1] * scale);
        Pt Along(Pt a, Pt b, double t) => new(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t);
        var side1 = Along(head[1], head[2], 0.6); var side2 = Along(head[3], head[4], 0.6);
        var red = ColorTranslator.FromHtml(Settings.Colors[0]);
        Check(Diff(Closest(shot, (a1.X + a2.X) / 2, ay, red, 4), red) <= 40, "arrow: the shaft is drawn", Hex(Closest(shot, (a1.X + a2.X) / 2, ay, red, 4)));
        Check(Diff(Closest(shot, (int)side1.X, (int)side1.Y, red, 4), red) <= 40 && Diff(Closest(shot, (int)side2.X, (int)side2.Y, red, 4), red) <= 40,
              "arrow: both sides of the head are drawn", $"{Hex(Closest(shot, (int)side1.X, (int)side1.Y, red, 4))} / {Hex(Closest(shot, (int)side2.X, (int)side2.Y, red, 4))}");
        Check(IsWhite(shot.GetPixel((a1.X + a2.X) / 2, ay - 25)), "arrow: nothing drawn away from it", Hex(shot.GetPixel((a1.X + a2.X) / 2, ay - 25)));

        // oval, then undo it
        Key('O'); Thread.Sleep(150);
        int oy1 = Row(4) - 10, oy2 = Row(5) + 40, ox1 = xm + (int)(W * 0.15), ox2 = ox1 + 160;
        Drag(new Point(ox1, oy1), new Point(ox2, oy2));
        Thread.Sleep(400);
        shot = Shot("06-oval");
        var ovalTop = new Point((ox1 + ox2) / 2, oy1);
        Check(Diff(Closest(shot, ovalTop.X, ovalTop.Y, red, 4), red) <= 40, "circle tool: the oval's edge is drawn", Hex(Closest(shot, ovalTop.X, ovalTop.Y, red, 4)));
        Check(IsWhite(shot.GetPixel((ox1 + ox2) / 2, (oy1 + oy2) / 2)), "circle tool: the inside stays clear", Hex(shot.GetPixel((ox1 + ox2) / 2, (oy1 + oy2) / 2)));
        KeyCombo(VK.Control, 'Z'); Thread.Sleep(400);
        shot = Shot("07-undo");
        Check(Diff(Closest(shot, ovalTop.X, ovalTop.Y, red, 4), red) > 60, "Ctrl+Z removes the oval", Hex(Closest(shot, ovalTop.X, ovalTop.Y, red, 4)));
        Check(Diff(Closest(shot, (a1.X + a2.X) / 2, ay, red, 4), red) <= 40, "Ctrl+Z leaves the arrow", Hex(Closest(shot, (a1.X + a2.X) / 2, ay, red, 4)));

        // eraser: touch the arrow
        Key('E'); Thread.Sleep(150);
        Drag(new Point((a1.X + a2.X) / 2 - 3, ay - 3), new Point((a1.X + a2.X) / 2 + 3, ay + 3));
        Thread.Sleep(400);
        shot = Shot("08-eraser");
        Check(Diff(Closest(shot, (a1.X + a2.X) / 2, ay, red, 4), red) > 60, "eraser removes the arrow it touches", Hex(Closest(shot, (a1.X + a2.X) / 2, ay, red, 4)));

        // clear
        Key('P'); Key('1'); Thread.Sleep(150);
        Drag(new Point(x1, Row(0)), new Point(x2, Row(0)));
        Key('C'); Thread.Sleep(400);
        shot = Shot("09-clear");
        Check(Marked(shot, new Rectangle(x1 - 10, Row(0) - 20, x2 - x1 + 20, Row(5) - Row(0) + 40)) == 0, "C clears every mark", "marked pixels left: " + Marked(shot, new Rectangle(x1 - 10, Row(0) - 20, x2 - x1 + 20, Row(5) - Row(0) + 40)));

        // fading ink
        Key('F'); Thread.Sleep(150);
        Drag(new Point(x1, Row(2)), new Point(x2, Row(2)));
        Thread.Sleep(500);
        var early = Closest(Shot("10-fade-0.5s"), xm, Row(2), red, 4);
        Thread.Sleep(3300);
        var late = Closest(Shot("11-fade-3.8s"), xm, Row(2), red, 4);
        Check(Diff(early, red) <= 40 && IsWhite(late), "fading ink: visible at 0.5 s, gone by 3.8 s", $"{Hex(early)} then {Hex(late)}");
        Key('F'); Thread.Sleep(150);

        // keys: slide keys reach the window underneath while drawing; tool letters don't; Esc stops drawing
        int k0 = slide.Keys.Count;
        Key(VK.Next); Thread.Sleep(300);
        Check(slide.Keys.Skip(k0).Contains(Keys.Next), "while drawing, Page Down still reaches the slides", "keys seen: " + string.Join(",", slide.Keys.Skip(k0)));
        k0 = slide.Keys.Count;
        Key('P'); Thread.Sleep(300);
        Check(!slide.Keys.Skip(k0).Contains(Keys.P), "while drawing, P is Contrast Ink's (not PowerPoint's previous slide)", "keys seen: " + string.Join(",", slide.Keys.Skip(k0)));
        Key(VK.Escape); Thread.Sleep(300);
        k0 = slide.Keys.Count;
        Key('P'); Thread.Sleep(300);
        Check(slide.Keys.Skip(k0).Contains(Keys.P), "after Esc, P reaches the slides again", "keys seen: " + string.Join(",", slide.Keys.Skip(k0)));
        c0 = slide.Clicks; Click(clickSpot); Thread.Sleep(300);
        Check(slide.Clicks == c0 + 1, "after Esc, clicks reach the slides again", $"clicks {c0} -> {slide.Clicks}");

        // hold Ctrl to draw
        Native.KeyDown(VK.Control); Thread.Sleep(200);
        Drag(new Point(x1, Row(4)), new Point(x2, Row(4)));
        Native.KeyUp(VK.Control); Thread.Sleep(400);
        shot = Shot("12-hold-ctrl");
        Check(Diff(Closest(shot, xm, Row(4), red, 4), red) <= 40, "holding Ctrl draws", Hex(Closest(shot, xm, Row(4), red, 4)));
        c0 = slide.Clicks; Click(clickSpot); Thread.Sleep(300);
        Check(slide.Clicks == c0 + 1, "letting go of Ctrl: clicks reach the slides again", $"clicks {c0} -> {slide.Clicks}");

        // still hidden at the end, after all of that
        dark = ToolbarDarkShare(Shot("13-end"), toolbar);
        Check(dark < 0.05, "at the end, a screen capture still does NOT show the toolbar", $"{dark:P1} toolbar colour");
        Log($"{(failures == 0 ? "ALL PASSED" : failures + " FAILED")}");
    }

    // ---------------------------------------------------------------- measuring
    static int Row(int i) => (int)(screen.Height * 0.32) + i * 44;
    static bool IsWhite(Color c) => c.R > 235 && c.G > 235 && c.B > 235;
    static int Diff(Color a, Color b) => Math.Max(Math.Abs(a.R - b.R), Math.Max(Math.Abs(a.G - b.G), Math.Abs(a.B - b.B)));
    static string Hex(Color c) => $"#{c.R:X2}{c.G:X2}{c.B:X2}";

    /// <summary>The pixel nearest in colour to <paramref name="want"/> within ±range rows of (x, y): lines are a few px thick.</summary>
    static Color Closest(Bitmap b, int x, int y, Color want, int range)
    {
        Color best = b.GetPixel(x, y);
        for (int dy = -range; dy <= range; dy++)
            for (int dx = -2; dx <= 2; dx++)
            {
                var c = b.GetPixel(Math.Clamp(x + dx, 0, b.Width - 1), Math.Clamp(y + dy, 0, b.Height - 1));
                if (Diff(c, want) < Diff(best, want)) best = c;
            }
        return best;
    }

    /// <summary>How many pixels of the column at x, around y, are not white: the line's thickness.</summary>
    static int Thickness(Bitmap b, int x, int y)
    {
        int n = 0;
        for (int dy = -40; dy <= 40; dy++)
        {
            var c = b.GetPixel(x, Math.Clamp(y + dy, 0, b.Height - 1));
            if (!(c.R > 200 && c.G > 200 && c.B > 200) || (c.B < 200 && c.R > 150)) n++;   // ink, or a light highlighter tint
        }
        return n;
    }

    static int Marked(Bitmap b, Rectangle r)
    {
        int n = 0;
        for (int y = r.Top; y < r.Bottom; y += 2)
            for (int x = r.Left; x < r.Right; x += 2)
                if (x < slide.StripeLeft - 2 || x > slide.StripeRight + 2)
                    if (!IsWhite(b.GetPixel(x, y))) n++;
        return n;
    }

    /// <summary>Share of the toolbar's rectangle that has the toolbar's own dark ink colour in a screen capture.</summary>
    static double ToolbarDarkShare(Bitmap b, Rectangle t)
    {
        var ink = ColorTranslator.FromHtml("#141A22");
        int n = 0, all = 0;
        for (int y = Math.Max(0, t.Top); y < Math.Min(b.Height, t.Bottom); y++)
            for (int x = Math.Max(0, t.Left); x < Math.Min(b.Width, t.Right); x++)
            { all++; if (Diff(b.GetPixel(x, y), ink) <= 12) n++; }
        return all == 0 ? 0 : (double)n / all;
    }

    static Bitmap Shot(string name)
    {
        var bmp = new Bitmap(screen.Width, screen.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(screen.Location, Point.Empty, screen.Size);
        bmp.Save(Path.Combine(outDir, $"{runMode}-{name}.png"), ImageFormat.Png);
        return bmp;
    }

    // ---------------------------------------------------------------- finding the toolbar's button
    static Point? FindToolbarButton(string nameStarts)
    {
        foreach (var hwnd in Native.ProcessWindows("Contrast Ink"))
        {
            var root = System.Windows.Automation.AutomationElement.FromHandle(hwnd);
            foreach (System.Windows.Automation.AutomationElement e in root.FindAll(System.Windows.Automation.TreeScope.Descendants, System.Windows.Automation.Condition.TrueCondition))
                if (e.Current.Name.StartsWith(nameStarts, StringComparison.Ordinal))
                {
                    var r = e.Current.BoundingRectangle;
                    return new Point((int)(r.Left + r.Width / 2), (int)(r.Top + r.Height / 2));
                }
        }
        return null;
    }

    // ---------------------------------------------------------------- input
    static void Click(Point p) { Native.MoveTo(p, screen); Thread.Sleep(40); Native.Mouse(Native.LEFTDOWN); Thread.Sleep(40); Native.Mouse(Native.LEFTUP); }
    static void Drag(Point a, Point b)
    {
        Native.MoveTo(a, screen); Thread.Sleep(60);
        Native.Mouse(Native.LEFTDOWN); Thread.Sleep(60);
        for (int i = 1; i <= 24; i++) { Native.MoveTo(new Point(a.X + (b.X - a.X) * i / 24, a.Y + (b.Y - a.Y) * i / 24), screen); Thread.Sleep(12); }
        Native.Mouse(Native.LEFTUP); Thread.Sleep(120);
    }
    static void Key(char c) => Key(char.IsLetterOrDigit(c) ? (ushort)char.ToUpperInvariant(c) : (ushort)c);
    static void Key(ushort vk) { Native.KeyDown(vk); Thread.Sleep(30); Native.KeyUp(vk); Thread.Sleep(80); }
    static void KeyCombo(ushort mod, char c) { Native.KeyDown(mod); Thread.Sleep(40); Key(c); Native.KeyUp(mod); Thread.Sleep(80); }
}

static class VK { public const ushort Control = 0x11, Escape = 0x1B, F9 = 0x78, Next = 0x22; }

/// <summary>The "slide": a white full-screen window with a black stripe, counting clicks and keys that reach it.</summary>
sealed class Slide : Form
{
    public int Clicks;
    public readonly List<Keys> Keys = new();
    public IntPtr Hwnd;
    public readonly int StripeLeft, StripeRight;
    public int StripeCenterX => (StripeLeft + StripeRight) / 2;

    public Slide(Rectangle screen)
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = screen;
        BackColor = Color.White;
        KeyPreview = true;
        Text = "Slide";
        StripeLeft = screen.Left + (int)(screen.Width * 0.62);
        StripeRight = StripeLeft + 70;
        var stripe = new Panel { BackColor = Color.Black, Bounds = new Rectangle(StripeLeft - screen.Left, 0, 70, screen.Height) };
        stripe.MouseDown += (_, _) => Clicks++;
        Controls.Add(stripe);
        MouseDown += (_, _) => Clicks++;
        KeyDown += (_, e) => { Keys.Add(e.KeyCode); e.Handled = true; };
        Shown += (_, _) => { Hwnd = Handle; Activate(); };
    }
}

static class Native
{
    public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;
    const uint MOVE = 0x0001, ABSOLUTE = 0x8000, KEYUP = 0x0002;

    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public U u; }
    [StructLayout(LayoutKind.Explicit)] struct U { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();

    static void Send(INPUT i)
    {
        if (SendInput(1, new[] { i }, Marshal.SizeOf<INPUT>()) != 1)
            throw new InvalidOperationException("SendInput was refused (error " + Marshal.GetLastWin32Error() + ")");
    }
    public static void MoveTo(Point p, Rectangle screen) => Send(new INPUT { type = 0, u = new U { mi = new MOUSEINPUT {
        dx = (int)Math.Round((p.X - screen.Left) * 65535.0 / (screen.Width - 1)), dy = (int)Math.Round((p.Y - screen.Top) * 65535.0 / (screen.Height - 1)), dwFlags = MOVE | ABSOLUTE } } });
    public static void Mouse(uint flags) => Send(new INPUT { type = 0, u = new U { mi = new MOUSEINPUT { dwFlags = flags } } });
    public static void KeyDown(ushort vk) => Send(new INPUT { type = 1, u = new U { ki = new KEYBDINPUT { wVk = vk } } });
    public static void KeyUp(ushort vk) => Send(new INPUT { type = 1, u = new U { ki = new KEYBDINPUT { wVk = vk, dwFlags = KEYUP } } });

    delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, System.Text.StringBuilder s, int n);
    public static List<IntPtr> ProcessWindows(string title)
    {
        var found = new List<IntPtr>();
        EnumWindows((h, _) => { var s = new System.Text.StringBuilder(256); GetWindowText(h, s, 256); if (s.ToString() == title) found.Add(h); return true; }, IntPtr.Zero);
        return found;
    }
}

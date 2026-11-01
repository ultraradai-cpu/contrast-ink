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
            try { Run(); code = failures; }
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

    static Process app = null!;
    static ProcessStartInfo startInfo = null!;
    static string statusPath = "";

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
        app = Process.Start(psi)!;
        startInfo = psi; statusPath = status;
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
                Key(VK.F9); Thread.Sleep(300);
                Drag(new Point((int)(screen.Width * 0.12), Row(0)), new Point((int)(screen.Width * 0.58), Row(0)));
                Thread.Sleep(500);
                var ub = Native.WindowBox(UndoTitle);
                var cshot = Shot("control-undo-button");
                double blue = Share(cshot, ub, UndoBlue);
                var mid = ub.Width > 0 ? Hex(cshot.GetPixel(Math.Clamp(ub.Left + 4, 0, cshot.Width - 1), Math.Clamp(ub.Top + 4, 0, cshot.Height - 1))) : "none";
                Check(Native.IsVisible(UndoTitle) && blue > 0.3, "CONTROL: with hiding switched off, a screen capture DOES show the undo button",
                      $"visible {Native.IsVisible(UndoTitle)}, {blue:P0} of its area is its blue, at {ub}, its corner pixel {mid}");
                Key('C'); Key(VK.F9);
                return failures;
            }
            Normal(st, toolbar);
            return 0;
        }
        finally
        {
            Log("      app still running at the end: " + !app.HasExited + (app.HasExited ? ", exit code " + app.ExitCode : ""));
            try { if (!app.HasExited) app.Kill(); } catch (InvalidOperationException) { }
            // the app's own error log, if it wrote one
            var errLog = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ContrastInk", "error.log");
            bool errors = File.Exists(errLog);
            Check(!errors, "the app logged no errors", errors ? "error.log below" : "no error.log");
            if (errors) { foreach (var l in File.ReadAllLines(errLog)) Log("        " + l); File.Delete(errLog); }
        }
    }

    // ---------------------------------------------------------------- the checks
    static void Normal(JsonElement st, Rectangle toolbar)
    {
        Check(toolbar.Left >= screen.Left && toolbar.Right <= screen.Right, "the whole toolbar is on the screen (✕ reachable)", $"toolbar {toolbar.Left}..{toolbar.Right}, screen {screen.Left}..{screen.Right}");
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

        SlidesAndUndo();
        ToolbarAndPromises();

        // still hidden at the end, after all of that
        dark = ToolbarDarkShare(Shot("13-end"), toolbar);
        Check(dark < 0.05, "at the end, a screen capture still does NOT show the toolbar", $"{dark:P1} toolbar colour");
        Log($"{(failures == 0 ? "ALL PASSED" : failures + " FAILED")}");
    }

    // ---------------------------------------------------------------- undo, every way, and marks for each slide
    const string UndoTitle = "Contrast Ink undo button";
    static readonly Color UndoBlue = ColorTranslator.FromHtml("#2563EB");

    static bool Press(string name)
    {
        var p = FindToolbarButton(name);
        if (p == null) { Check(false, $"toolbar control \"{name}...\" is there", "not found"); return false; }
        Click(p.Value); Thread.Sleep(300); return true;
    }

    static void SlidesAndUndo()
    {
        int W = screen.Width;
        int x1 = (int)(W * 0.12), x2 = (int)(W * 0.58), xm = (int)(W * 0.35);
        var red = ColorTranslator.FromHtml(Settings.Colors[0]);
        bool Red(Bitmap b, int row) => Diff(Closest(b, xm, Row(row), red, 8), red) <= 40;
        string At(Bitmap b, int row) => Hex(Closest(b, xm, Row(row), red, 8));
        void Line(int row) { Drag(new Point(x1, Row(row)), new Point(x2, Row(row))); Thread.Sleep(400); }
        var blank = new Point(xm, Row(6));   // a right-click spot with nothing on it

        Key(VK.F9); Thread.Sleep(300); Key('C'); Key('P'); Key('1'); Thread.Sleep(200);

        // Z alone
        Line(0);
        var shot = Shot("30-before-z");
        bool drawn = Red(shot, 0);
        Key('Z'); Thread.Sleep(400);
        shot = Shot("31-after-z");
        Check(drawn && !Red(shot, 0), "Z alone undoes the last mark", $"before {(drawn ? "drawn" : "NOT drawn")}, after {At(shot, 0)}");

        // right-click
        Line(1);
        int c0 = slide.Clicks;
        RightClick(blank); Thread.Sleep(400);
        shot = Shot("32-right-click");
        Check(!Red(shot, 1), "a right-click undoes the last mark", At(shot, 1));
        Check(slide.Clicks == c0, "that right-click did not reach the slide", $"clicks {c0} -> {slide.Clicks}");

        // the undo button beside the mark
        Line(2);
        var box = Native.WindowBox(UndoTitle);
        bool shown = Native.IsVisible(UndoTitle);
        Check(box.Width <= 48 && box.Height <= 48, "the undo button is small", $"{box.Width} x {box.Height} px");
        Check(shown && box.Left >= x2 - 5 && box.Left <= x2 + 80 && box.Top >= Row(2) - 10 && box.Top <= Row(2) + 80,
              "the undo button appears beside the end of the mark", $"visible {shown}, at {box}, mark ends at ({x2},{Row(2)})");
        shot = Shot("33-undo-button");
        double blue = Share(shot, box, UndoBlue);
        Check(blue < 0.05, "a screen capture does NOT show the undo button", $"{blue:P1} of its area is its blue (the control run must show it)");
        if (shown)
        {
            Click(new Point(box.Left + box.Width / 2, box.Top + box.Height / 2)); Thread.Sleep(400);
            shot = Shot("34-undo-button-clicked");
            Check(!Red(shot, 2), "clicking the undo button removes the mark", At(shot, 2));
            Check(Native.GetForegroundWindow() == slide.Hwnd, "clicking it did not take the keyboard from the slides", "foreground is the slide window: " + (Native.GetForegroundWindow() == slide.Hwnd));
        }

        // each setting switched off really is off (⚙ on the toolbar)
        if (Press("Settings"))
        {
            Press("Z Key"); Press("Right-Click"); Press("Undo Button Beside");
            Line(3);
            int k0 = slide.Keys.Count;
            Key('Z'); Thread.Sleep(300);
            RightClick(blank); Thread.Sleep(400);
            shot = Shot("35-undo-switched-off");
            Check(Red(shot, 3), "settings: with Z and right-click switched off, neither undoes", At(shot, 3));
            Check(slide.Keys.Skip(k0).Contains(Keys.Z), "settings: Z switched off reaches the slides instead", "keys seen: " + string.Join(",", slide.Keys.Skip(k0)));
            Check(!Native.IsVisible(UndoTitle), "settings: the undo button switched off does not appear", "visible " + Native.IsVisible(UndoTitle));
            Press("Z Key"); Press("Right-Click"); Press("Undo Button Beside");
            Press("Settings");
            Key('C'); Thread.Sleep(300);
        }

        // each slide keeps its own marks, with a stand-in PowerPoint showing a slide show
        var ppt = new FakePowerPoint();
        uint cookie = FakePowerPoint.Register(ppt);
        Check(cookie != 0, "a stand-in PowerPoint is running", "cookie " + cookie);
        try
        {
            Thread.Sleep(900);
            Line(0);                                                   // on slide 1
            ppt.SlideShowWindows.Show.View.CurrentShowPosition = 2; Thread.Sleep(900);
            shot = Shot("40-slide-2");
            Check(!Red(shot, 0), "next slide: it starts clean", "slide 1's mark: " + At(shot, 0));
            Line(1);                                                   // on slide 2
            ppt.SlideShowWindows.Show.View.CurrentShowPosition = 1; Thread.Sleep(900);
            shot = Shot("41-back-to-slide-1");
            Check(Red(shot, 0) && !Red(shot, 1), "back to slide 1: its mark comes back, slide 2's is gone", $"slide 1's {At(shot, 0)}, slide 2's {At(shot, 1)}");
            Key('Z'); Thread.Sleep(400);
            ppt.SlideShowWindows.Show.View.CurrentShowPosition = 2; Thread.Sleep(900);
            shot = Shot("42-undo-is-per-slide");
            Check(Red(shot, 1) && !Red(shot, 0), "undo on slide 1 removed slide 1's mark, not slide 2's", $"slide 2's {At(shot, 1)}, slide 1's {At(shot, 0)}");

            // a fresh slide: two marks, two taps on the undo button take both; then it goes, as nothing is left
            ppt.SlideShowWindows.Show.View.CurrentShowPosition = 3; Thread.Sleep(900);
            Line(4); Line(5);
            var ub = Native.WindowBox(UndoTitle);
            var tap = new Point(ub.Left + ub.Width / 2, ub.Top + ub.Height / 2);
            Click(tap); Thread.Sleep(400);
            shot = Shot("44-one-tap");
            Check(Red(shot, 4) && !Red(shot, 5) && Native.IsVisible(UndoTitle), "undo button: one tap takes the last mark only, and it stays for the next",
                  $"first mark {At(shot, 4)}, second {At(shot, 5)}, button visible {Native.IsVisible(UndoTitle)}");
            Click(tap); Thread.Sleep(400);
            shot = Shot("45-two-taps");
            Check(!Red(shot, 4), "undo button: a second tap takes the mark before", At(shot, 4));
            Check(!Native.IsVisible(UndoTitle), "undo button: with nothing left to undo on this slide, it goes", "visible " + Native.IsVisible(UndoTitle));

            ppt.SlideShowWindows.Show.View.CurrentShowPosition = 2; Thread.Sleep(900);
            ppt.SlideShowWindows.Count = 0; Thread.Sleep(900);          // the slide show ends
            shot = Shot("43-show-ended");
            Check(!Red(shot, 1), "slide show ended: the slides' marks go with it", At(shot, 1));
        }
        finally { FakePowerPoint.Revoke(cookie); }
        Thread.Sleep(900);
        Key('C'); Key(VK.F9); Thread.Sleep(300);
    }

    // ---------------------------------------------------------------- the toolbar's own buttons, and the README's promises
    /// <summary>Everything above used keys. Each action here goes through its toolbar button, with the real mouse.</summary>
    static void ToolbarAndPromises()
    {
        int W = screen.Width;
        int x1 = (int)(W * 0.12), x2 = (int)(W * 0.58), xm = (int)(W * 0.35);
        var red = ColorTranslator.FromHtml(Settings.Colors[0]);
        var green = ColorTranslator.FromHtml(Settings.Colors[2]);
        if (!Press("Draw on / off")) return;               // drawing on, from the toolbar
        Press("Clear all marks");

        // colour, thickness and tool from the toolbar
        Press("Green (3)"); Press("Thick ("); Press("Pen (P)");
        Drag(new Point(x1, Row(0)), new Point(x2, Row(0)));
        Thread.Sleep(400);
        var shot = Shot("20-toolbar-green-thick");
        var got = Closest(shot, xm, Row(0), green, 8);
        Check(Diff(got, green) <= 40, "toolbar: the green dot makes the pen green", $"want {Hex(green)}, screen has {Hex(got)}");
        int t = Thickness(shot, xm, Row(0));
        Check(Math.Abs(t - Settings.Widths[2] * scale) <= Math.Max(2, Settings.Widths[2] * scale * 0.35), "toolbar: the Thick button draws thick", $"{t} px");
        Press("Highlighter (H)");
        Drag(new Point(x1, Row(2)), new Point(x2, Row(2)));
        Thread.Sleep(400);
        int hw = Thickness(Shot("21-toolbar-highlighter"), xm, Row(2));
        Check(hw > t, "toolbar: the Highlighter button draws the wide highlighter", $"{hw} px vs pen {t} px");

        // Clear from the toolbar, then Undo from the toolbar brings it all back (README: "Undo brings them back")
        Press("Clear all marks"); Thread.Sleep(300);
        var cleared = Closest(Shot("22-toolbar-clear"), xm, Row(0), green, 8);
        Check(IsWhite(cleared), "toolbar: Clear removes the marks", Hex(cleared));
        Press("Undo (Ctrl+Z)"); Thread.Sleep(400);
        var back = Closest(Shot("23-toolbar-undo-clear"), xm, Row(0), green, 8);
        Check(Diff(back, green) <= 40, "toolbar: Undo after Clear brings the marks back", Hex(back));
        // the same promise with the keys: C, then Ctrl+Z
        Key('C'); Thread.Sleep(300); KeyCombo(VK.Control, 'Z'); Thread.Sleep(400);
        back = Closest(Shot("24-keys-undo-clear"), xm, Row(0), green, 8);
        Check(Diff(back, green) <= 40, "keys: Ctrl+Z after C brings the marks back", Hex(back));
        Press("Clear all marks");

        // fading ink: holding Shift while drawing keeps that mark (README and hint)
        Press("Pen (P)"); Press("Red (1)"); Press("Fading ink");
        Native.KeyDown(VK.Shift); Thread.Sleep(150);
        Drag(new Point(x1, Row(1)), new Point(x2, Row(1)));
        Native.KeyUp(VK.Shift); Thread.Sleep(150);
        Drag(new Point(x1, Row(3)), new Point(x2, Row(3)));   // drawn without Shift: must fade
        Thread.Sleep(4000);
        shot = Shot("25-fade-shift-keeps");
        var kept = Closest(shot, xm, Row(1), red, 8); var faded = Closest(shot, xm, Row(3), red, 8);
        Check(Diff(kept, red) <= 40 && IsWhite(faded), "fading ink: the mark drawn holding Shift stays, the other fades", $"held {Hex(kept)}, not held {Hex(faded)}");
        Press("Fading ink"); Press("Clear all marks");

        // circle tool: holding Shift makes a perfect circle (README and hint)
        Press("Circle a finding");
        int cx0 = x1, cy0 = Row(0) - 20, side = 180;
        Native.KeyDown(VK.Shift); Thread.Sleep(150);
        Drag(new Point(cx0, cy0), new Point(cx0 + side, cy0 + side / 3));   // a flat box: Shift must make it round
        Native.KeyUp(VK.Shift); Thread.Sleep(400);
        shot = Shot("26-shift-circle");
        var bottom = Closest(shot, cx0 + side / 2, cy0 + side, red, 6);
        var flatBottom = shot.GetPixel(cx0 + side / 2, cy0 + side / 3);
        Check(Diff(bottom, red) <= 40 && IsWhite(flatBottom), "circle tool: holding Shift makes it as tall as it is wide", $"edge at full height {Hex(bottom)}, where a flat oval would end {Hex(flatBottom)}");
        Press("Clear all marks");

        // ‹ makes the toolbar small, › big again
        var before = Native.WindowBox("Contrast Ink");
        Press("Make the toolbar small"); Thread.Sleep(300);
        var small = Native.WindowBox("Contrast Ink");
        Check(small.Width > 0 && small.Width < before.Width / 2, "‹ makes the toolbar small", $"{before.Width} px -> {small.Width} px");
        Press("Make the toolbar small"); Thread.Sleep(300);
        var big = Native.WindowBox("Contrast Ink");
        Check(Math.Abs(big.Width - before.Width) <= 2, "› makes it big again", $"{small.Width} px -> {big.Width} px");

        // settings remembered: green pen chosen above; quit with ✕, start again, draw without choosing
        Press("Green (3)"); Press("Pen (P)"); Press("Draw on / off");   // drawing off before quitting
        Press("Quit Contrast Ink");
        bool quit = app.WaitForExit(5000);
        Check(quit, "✕ quits the app", quit ? "exited" : "still running after 5 s");
        if (!quit) return;
        File.Delete(statusPath);
        app = Process.Start(startInfo)!;
        var sw = Stopwatch.StartNew();
        while (!File.Exists(statusPath) && sw.Elapsed.TotalSeconds < 20) Thread.Sleep(200);
        Thread.Sleep(800);
        Check(File.Exists(statusPath), "it starts again after quitting", File.Exists(statusPath) ? "status written" : "no status");
        Key(VK.F9); Thread.Sleep(300);
        Drag(new Point(x1, Row(4)), new Point(x2, Row(4)));
        Thread.Sleep(400);
        got = Closest(Shot("27-remembered"), xm, Row(4), green, 8);
        Check(Diff(got, green) <= 40, "settings are remembered: the next start draws in the colour chosen last time", $"want {Hex(green)}, screen has {Hex(got)}");
        Key('C'); Key(VK.F9); Thread.Sleep(300);
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
    static double ToolbarDarkShare(Bitmap b, Rectangle t) => Share(b, t, ColorTranslator.FromHtml("#141A22"));

    /// <summary>Share of a rectangle of a capture that is this colour.</summary>
    static double Share(Bitmap b, Rectangle t, Color want)
    {
        int n = 0, all = 0;
        for (int y = Math.Max(0, t.Top); y < Math.Min(b.Height, t.Bottom); y++)
            for (int x = Math.Max(0, t.Left); x < Math.Min(b.Width, t.Right); x++)
            { all++; if (Diff(b.GetPixel(x, y), want) <= 12) n++; }
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
    static void RightClick(Point p) { Native.MoveTo(p, screen); Thread.Sleep(40); Native.Mouse(Native.RIGHTDOWN); Thread.Sleep(40); Native.Mouse(Native.RIGHTUP); }
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

static class VK { public const ushort Control = 0x11, Shift = 0x10, Escape = 0x1B, F9 = 0x78, Next = 0x22; }

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
    public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004, RIGHTDOWN = 0x0008, RIGHTUP = 0x0010;
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    public static bool IsVisible(string title) => ProcessWindows(title).Any(IsWindowVisible);
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
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    /// <summary>The on-screen rectangle of the (first) window with this exact title.</summary>
    public static Rectangle WindowBox(string title)
    {
        foreach (var h in ProcessWindows(title)) { GetWindowRect(h, out var r); return Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom); }
        return Rectangle.Empty;
    }

    public static List<IntPtr> ProcessWindows(string title)
    {
        var found = new List<IntPtr>();
        EnumWindows((h, _) => { var s = new System.Text.StringBuilder(256); GetWindowText(h, s, 256); if (s.ToString() == title) found.Add(h); return true; }, IntPtr.Zero);
        return found;
    }
}

// ---------------------------------------------------------------- a stand-in PowerPoint
// Registered where Windows lists running programs' automation objects, under PowerPoint's class id, so Contrast Ink
// finds it exactly as it would find PowerPoint: SlideShowWindows.Count, .Item(1).View.CurrentShowPosition, .Presentation.FullName.
[ComVisible(true), ClassInterface(ClassInterfaceType.AutoDispatch)]
public class FakePowerPoint
{
    public FakeShows SlideShowWindows { get; } = new();

    static readonly Guid PowerPointClsid = new("91493441-5A91-11CF-8700-00AA0060263B");
    [DllImport("oleaut32.dll")] static extern int RegisterActiveObject([MarshalAs(UnmanagedType.IUnknown)] object punk, ref Guid clsid, uint flags, out uint cookie);
    [DllImport("oleaut32.dll")] static extern int RevokeActiveObject(uint cookie, IntPtr reserved);
    public static uint Register(FakePowerPoint p) { var id = PowerPointClsid; return RegisterActiveObject(p, ref id, 0 /* ACTIVEOBJECT_STRONG */, out var c) == 0 ? c : 0; }
    public static void Revoke(uint cookie) { if (cookie != 0) RevokeActiveObject(cookie, IntPtr.Zero); }
}
[ComVisible(true), ClassInterface(ClassInterfaceType.AutoDispatch)]
public class FakeShows
{
    public int Count { get; set; } = 1;
    public FakeShow Show { get; } = new();
    public FakeShow Item(int index) => Show;
}
[ComVisible(true), ClassInterface(ClassInterfaceType.AutoDispatch)]
public class FakeShow
{
    public FakeView View { get; } = new();
    public FakePresentation Presentation { get; } = new();
}
[ComVisible(true), ClassInterface(ClassInterfaceType.AutoDispatch)]
public class FakeView { public int CurrentShowPosition { get; set; } = 1; }
[ComVisible(true), ClassInterface(ClassInterfaceType.AutoDispatch)]
public class FakePresentation { public string FullName => @"C:\Lectures\Cardiac MR.pptx"; }

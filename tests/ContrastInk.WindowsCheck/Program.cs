// Contrast Ink: the Windows check.
// Starts the real ContrastInk.exe over a white "slide" window, uses it with simulated mouse and keys, and reads the
// screen back pixel by pixel. Every check prints what it measured. Screenshots go to the output folder.
//
//   ContrastInk.WindowsCheck.exe <path to ContrastInk.exe> <output folder> normal|control
//
// "control" starts the app with hiding from capture switched off (CONTRASTINK_TEST_NOHIDE=1) and requires the check
// to SEE the toolbar: proof that the "toolbar is hidden" check can fail.
// The tablet's picture has runs of its own (only the tablet link, quick):
//   "padcontrol"  the picture whitened (CONTRASTINK_TEST_BLANKPAD=1): the picture checks must FAIL (proof that they can);
//   "padfreeze"   the first picture sent for ever (CONTRASTINK_TEST_FREEZEPAD=1): the check that the picture follows a
//                 change on the slide must FAIL (a frozen capture is caught);
//   "padgdi"      the GDI copy forced (CONTRASTINK_TEST_FORCEGDI=1) and pictures 400 px wide: every check must pass;
//   "padsmall"    Windows.Graphics.Capture with pictures 400 px wide (the downscaling exercised): every check must pass.
//   "padblack"    the screen's copy made black whenever marks are on the drawing layer (CONTRASTINK_TEST_BLACKWITHMARKS=1),
//                 the fault a presenter's PC showed (the tablet's picture black the moment its pen wrote): every check
//                 must pass, the one made mid-stroke included (the last good copy is sent, with the marks over it);
//   "padblackcontrol"  the same fault without that fix (CONTRASTINK_TEST_NOHOLD=1): the first picture must pass and
//                 the picture made mid-stroke must FAIL (proof that the mid-stroke check sees a black picture).
// Every run with a tablet also reads the app's pad-diagnostics.txt and copies pad-black.jpg / pad-during-stroke.jpg.
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
        // a copy of this program named adb.exe: a stand-in adb that writes down that it was run (and finds no tablet)
        if (string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "adb", StringComparison.OrdinalIgnoreCase))
        {
            try { File.AppendAllText(Path.Combine(AppContext.BaseDirectory, AdbRan), string.Join(" ", args) + "\n"); } catch (IOException) { }
            Console.WriteLine("List of devices attached");
            Console.WriteLine();
            return 0;
        }
        if (args.Length < 3) { Console.Error.WriteLine("usage: <ContrastInk.exe> <out dir> normal|control|padcontrol|padfreeze|padgdi|padsmall|padblack|padblackcontrol"); return 2; }
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
        if (!ok && counting) failures++;
        Log($"{(counting ? "" : "(control, not counted) ")}{(ok ? "PASS" : "FAIL")}  {what}  [{measured}]");
    }
    static bool counting = true;   // false while the pad control runs checks that must fail

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
        foreach (var f in new[] { DiagLog, DiagBlack, DiagStroke }) if (File.Exists(f)) File.Delete(f);   // this run's notes only
        var psi = new ProcessStartInfo(exe) { UseShellExecute = false };
        psi.Environment["CONTRASTINK_TEST"] = "1";
        psi.Environment["CONTRASTINK_STATUS"] = status;
        psi.Environment["CONTRASTINK_TEST_PADCODE"] = PadCode;   // the tablet link, with a code this check knows
        if (runMode == "control") psi.Environment["CONTRASTINK_TEST_NOHIDE"] = "1";
        if (runMode == "padcontrol") psi.Environment["CONTRASTINK_TEST_BLANKPAD"] = "1";
        if (runMode == "padfreeze") psi.Environment["CONTRASTINK_TEST_FREEZEPAD"] = "1";
        if (runMode == "padgdi") psi.Environment["CONTRASTINK_TEST_FORCEGDI"] = "1";
        if (runMode is "padblack" or "padblackcontrol") psi.Environment["CONTRASTINK_TEST_BLACKWITHMARKS"] = "1";
        if (runMode == "padblackcontrol") psi.Environment["CONTRASTINK_TEST_NOHOLD"] = "1";
        if (runMode is "padgdi" or "padsmall") psi.Environment["CONTRASTINK_TEST_PADWIDTH"] = SmallPicture.ToString();
        // adb: none on the app's PATH; a stand-in in C:\platform-tools, a folder any user of a PC can create, which
        // the app must never run (the restart in ToolbarAndPromises puts one on the PATH, which it must run)
        psi.Environment["PATH"] = string.Join(Path.PathSeparator, (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Where(d => d.Trim().Length > 0 && !SafeExists(Path.Combine(d.Trim().Trim('"'), "adb.exe"))));
        if (runMode == "normal") PlantAdb();
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
                Bitmap cshot; double blue; var waited = Stopwatch.StartNew();
                do { Thread.Sleep(250); cshot = Shot("control-undo-button"); blue = Share(cshot, ub, UndoBlue); } while (blue < 0.3 && waited.ElapsedMilliseconds < 2500);
                var mid = ub.Width > 0 ? Hex(cshot.GetPixel(Math.Clamp(ub.Left + 4, 0, cshot.Width - 1), Math.Clamp(ub.Top + 4, 0, cshot.Height - 1))) : "none";
                Check(UndoOnScreen() && blue > 0.3, "CONTROL: with hiding switched off, a screen capture DOES show the undo button",
                      $"visible {UndoOnScreen()}, {blue:P0} of its area is its blue, at {ub}, its corner pixel {mid}");
                Key('C'); Key(VK.F9);
                return failures;
            }
            if (runMode.StartsWith("pad", StringComparison.Ordinal)) { PadPictureRun(st); return failures; }
            Normal(st, toolbar);
            return 0;
        }
        finally
        {
            Log("      app still running at the end: " + !app.HasExited + (app.HasExited ? ", exit code " + app.ExitCode : ""));
            try { if (!app.HasExited) app.Kill(); } catch (InvalidOperationException) { }
            if (plantedAdb) try { Directory.Delete(PlantedAdbDir, recursive: true); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
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
        // the whole arrow, head too (touching the shaft once left the head behind would be a half-erased mark)
        var e1 = Closest(shot, (int)side1.X, (int)side1.Y, red, 4); var e2 = Closest(shot, (int)side2.X, (int)side2.Y, red, 4);
        var tip = Closest(shot, a2.X, ay, red, 4);
        Check(Diff(e1, red) > 60 && Diff(e2, red) > 60 && Diff(tip, red) > 60, "eraser removes the arrowhead with it",
              $"head sides {Hex(e1)} / {Hex(e2)}, tip {Hex(tip)}");

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

        // laser pointer: a glowing line while drawing, gone a second later, and never a mark
        Key('L'); Thread.Sleep(150);
        var laser = ColorTranslator.FromHtml(Laser.Color);
        Drag(new Point(x1, Row(3)), new Point(x2, Row(3)));
        var lit = Closest(Shot("11b-laser-now"), xm, Row(3), laser, 6);
        Thread.Sleep(1800);
        var gone = Closest(Shot("11c-laser-1.8s"), xm, Row(3), laser, 6);
        Check(Diff(lit, laser) <= 60 && IsWhite(gone), "laser: a glowing line while drawing, gone within 2 s", $"{Hex(lit)} then {Hex(gone)}");
        Key('P'); Thread.Sleep(150);

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
        RecordingWithObs();
        ToolbarAndPromises();
        TabletPad(st);

        // still hidden at the end, after all of that
        dark = ToolbarDarkShare(Shot("13-end"), toolbar);
        Check(dark < 0.05, "at the end, a screen capture still does NOT show the toolbar", $"{dark:P1} toolbar colour");
        Log($"{(failures == 0 ? "ALL PASSED" : failures + " FAILED")}");
    }

    // ---------------------------------------------------------------- a tablet used as a pad
    const string PadCode = "246810";

    // ---------------------------------------------------------------- which adb.exe the app runs
    const string AdbRan = "adb-ran.txt";
    const string PlantedAdbDir = @"C:\platform-tools";
    static bool plantedAdb;
    static string PathAdbDir => Path.Combine(Path.GetTempPath(), "contrastink-check-adb-on-path");

    static bool SafeExists(string f) { try { return File.Exists(f); } catch (ArgumentException) { return false; } }

    /// <summary>This program, copied into <paramref name="dir"/> as adb.exe (it then only writes down that it ran).</summary>
    static void CopyStandInAdb(string dir)
    {
        Directory.CreateDirectory(dir);
        foreach (var f in Directory.GetFiles(AppContext.BaseDirectory)) File.Copy(f, Path.Combine(dir, Path.GetFileName(f)), overwrite: true);
        File.Copy(Environment.ProcessPath!, Path.Combine(dir, "adb.exe"), overwrite: true);
        File.Delete(Path.Combine(dir, AdbRan));
    }

    static void PlantAdb()
    {
        try
        {
            if (Directory.Exists(PlantedAdbDir)) { Log("      C:\\platform-tools already exists on this machine: left as it is"); }
            else { CopyStandInAdb(PlantedAdbDir); plantedAdb = true; }
            CopyStandInAdb(PathAdbDir);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Log("      couldn't plant the stand-in adb: " + e.Message); }
    }

    /// <summary>The app must never run an adb.exe from C:\platform-tools (any user may create that folder).</summary>
    static void CheckPlantedAdbNotRun()
    {
        if (!plantedAdb) { Check(false, "adb: a stand-in adb.exe could be put in C:\\platform-tools", "not planted"); return; }
        var ran = Path.Combine(PlantedAdbDir, AdbRan);
        Check(!File.Exists(ran), "adb: an adb.exe in C:\\platform-tools (a folder any user can create) is never run",
              File.Exists(ran) ? "it ran: " + File.ReadAllText(ran).Trim() : "not run in " + (DateTime.Now - app.StartTime).TotalSeconds.ToString("0") + " s");
    }

    /// <summary>
    /// The opacity slider dragged to 10% and back to 100%: dozens of values on the way. The settings file must be
    /// written about once after it stops (each write was on the UI thread, which runs the keyboard watcher), not once per value.
    /// </summary>
    static void OpacityDragSavesOnce()
    {
        var box = ToolbarBox("Opacity");
        if (box.IsEmpty) { Check(false, "toolbar: the opacity slider is there", "not found"); return; }
        var file = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ContrastInk", "settings.json");
        Thread.Sleep(1000);   // earlier changes saved first
        int writes = 0;
        using (var w = new FileSystemWatcher(Path.GetDirectoryName(file)!, "settings.json")
               { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size })
        {
            w.Changed += (_, _) => Interlocked.Increment(ref writes);
            w.Created += (_, _) => Interlocked.Increment(ref writes);
            w.Renamed += (_, _) => Interlocked.Increment(ref writes);
            w.EnableRaisingEvents = true;
            int y = box.Top + box.Height / 2;
            Drag(new Point(box.Right - 3, y), new Point(box.Left - 20, y));
            Drag(new Point(box.Left + 3, y), new Point(box.Right + 20, y));
            Thread.Sleep(1500);
        }
        double saved = Settings.Load(file, 1).Opacity;
        Check(writes >= 1 && writes <= 6 && saved > 0.95, "toolbar: dragging the opacity slider writes the settings once it stops, not on every step",
              $"{writes} change(s) to settings.json, opacity saved {saved:0.00}");
    }

    /// <summary>The ⚙ panel's text about the tablet link (open while read), or "".</summary>
    static string PadPanelText()
    {
        if (!Press("Settings")) return "";
        Thread.Sleep(300);
        var text = ToolbarName("Code ") ?? "";
        Press("Settings");
        return text;
    }

    static byte[] PadPoint(float x, float y)
    {
        var b = new byte[8];
        System.Buffers.Binary.BinaryPrimitives.WriteSingleBigEndian(b, x);
        System.Buffers.Binary.BinaryPrimitives.WriteSingleBigEndian(b.AsSpan(4), y);
        return b;
    }

    /// <summary>What the PC sends, until <paramref name="enough"/> says so or the time is up.</summary>
    static List<(byte type, byte[] payload)> PadRead(System.Net.Sockets.NetworkStream s, PadReader r, Func<List<(byte type, byte[] payload)>, bool> enough, int ms)
    {
        var got = new List<(byte, byte[])>();
        var buf = new byte[1 << 16];
        var until = DateTime.UtcNow.AddMilliseconds(ms);
        while (DateTime.UtcNow < until && !enough(got))
        {
            if (!s.DataAvailable) { Thread.Sleep(20); continue; }
            int n = s.Read(buf, 0, buf.Length);
            if (n <= 0) break;
            got.AddRange(r.Add(buf.AsSpan(0, n)));
        }
        return got;
    }

    /// <summary>
    /// A stand-in tablet speaking version 2 as a real one does: its own fresh key, the PC's key and salt back, keys
    /// from the code, a sealed PROOF; from then on every message sealed both ways.
    /// </summary>
    sealed class TestTablet : IDisposable
    {
        public readonly System.Net.Sockets.TcpClient Tcp;
        public readonly System.Net.Sockets.NetworkStream Net;
        readonly PadReader reader = new();
        PadSeal? toPc, fromPc;
        public string Refused = "";
        public byte[]? PcKey;

        public TestTablet(int port) : this(new System.Net.Sockets.TcpClient("127.0.0.1", port)) { }
        /// <summary>On a connection that is already open (the iPad's end of a USB connection the PC opened).</summary>
        public TestTablet(System.Net.Sockets.TcpClient open) { Tcp = open; Net = Tcp.GetStream(); }

        /// <summary>The handshake with this code; true when the PC let it in (WELCOME opened). The answer to the
        /// PROOF is waited for up to <paramref name="answerMs"/> (longer where the presenter is asked first).</summary>
        public bool Pair(string code, int answerMs = 5000)
        {
            using var mine = PadCrypto.NewKey();
            Net.Write(Pad.Message(Pad.Hello, JsonSerializer.Serialize(new { device = "check", version = 2, key = Convert.ToBase64String(PadCrypto.PublicPoint(mine)) })));
            var first = PadRead(Net, reader, g => g.Count > 0, 5000);
            if (first.Count == 0) return false;
            if (first[0].type == Pad.Reject) { Refused = System.Text.Encoding.UTF8.GetString(first[0].payload); return false; }
            using var ch = JsonDocument.Parse(first[0].payload);
            PcKey = Convert.FromBase64String(ch.RootElement.GetProperty("key").GetString()!);
            var salt = Convert.FromBase64String(ch.RootElement.GetProperty("salt").GetString()!);
            var (a, b) = PadCrypto.Keys(mine, PadCrypto.ReadPoint(PcKey)!, salt, code);
            toPc = new PadSeal(a); fromPc = new PadSeal(b);
            Net.Write(Pad.Message(PadCrypto.Proof, toPc.Seal(Pad.Message(Pad.Command, PadCrypto.ProofText))));
            var answer = Read(g => g.Count > 0, answerMs);
            if (answer.Count == 0) return false;
            if (answer[0].type == Pad.Reject) { Refused = System.Text.Encoding.UTF8.GetString(answer[0].payload); return false; }
            return answer[0].type == Pad.Welcome;
        }

        public void Send(byte type, byte[] payload) => Net.Write(Pad.Message(PadCrypto.Sealed, toPc!.Seal(Pad.Message(type, payload))));
        public void Send(byte type, string text) => Send(type, System.Text.Encoding.UTF8.GetBytes(text));

        /// <summary>What the PC sent, opened (a REJECT in the clear is passed as it is).</summary>
        public List<(byte type, byte[] payload)> Read(Func<List<(byte type, byte[] payload)>, bool> enough, int ms)
        {
            var opened = new List<(byte, byte[])>();
            var buf = new byte[1 << 16];
            var until = DateTime.UtcNow.AddMilliseconds(ms);
            while (DateTime.UtcNow < until && !enough(opened))
            {
                if (!Net.DataAvailable) { Thread.Sleep(20); continue; }
                int n = Net.Read(buf, 0, buf.Length);
                if (n <= 0) break;
                foreach (var (t, p) in reader.Add(buf.AsSpan(0, n)))
                {
                    if (t == PadCrypto.Sealed && fromPc?.Open(p) is { } inner) opened.AddRange(new PadReader().Add(inner));
                    else if (t != PadCrypto.Sealed) opened.Add((t, p));
                }
            }
            return opened;
        }

        public void Dispose() { toPc?.Dispose(); fromPc?.Dispose(); Tcp.Dispose(); }
    }

    /// <summary>
    /// A stand-in tablet, over the network as a real one would be (version 2, encrypted): a wrong code is refused; the
    /// right one gets the screen's picture, one after another as each is acknowledged; a line drawn on it appears on
    /// the screen and in its picture; undo and next work; a second tablet with the right code takes over; strangers'
    /// broken messages can't end the app, and guessing is locked out.
    /// </summary>
    static void TabletPad(JsonElement st)
    {
        int port = st.TryGetProperty("padPort", out var pp) ? pp.GetInt32() : 0;
        Check(port > 0, "tablet link: the PC listens for a tablet", "port " + port);
        if (port == 0) return;
        try
        {
            using (var wrong = new TestTablet(port))
            {
                bool inWithWrong = wrong.Pair("000000");
                Check(!inWithWrong && wrong.Refused == Pad.WrongCode, "tablet link: a wrong code is refused (the code itself never sent)", wrong.Refused);
            }
            using (var old = new System.Net.Sockets.TcpClient("127.0.0.1", port))
            {
                old.GetStream().Write(Pad.Message(Pad.Hello, "{\"code\":\"" + PadCode + "\",\"device\":\"old\",\"version\":1}"));
                var m = PadRead(old.GetStream(), new PadReader(), g => g.Count > 0, 5000);
                var said = m.Count > 0 ? System.Text.Encoding.UTF8.GetString(m[0].payload) : "no answer";
                Check(said == Pad.UpdateTablet, "tablet link: a version-1 tablet (code in the clear) is told to update", said);
            }

            using var t = new TestTablet(port);
            bool paired = t.Pair(PadCode);
            Check(paired, "tablet link: the right code is let in, everything sealed from then on", paired ? "WELCOME opened" : "refused: " + t.Refused);
            if (!paired) return;
            Check(t.PcKey != null && Pad.PcCheck(t.PcKey).Length == 19, "tablet link: the PC sends its own key (the tablet's 16-digit PC check)", t.PcKey == null ? "none" : Pad.PcCheck(t.PcKey));
            var got = t.Read(g => g.Any(x => x.type == Pad.Frame) && g.Any(x => x.type == Pad.State), 8000);
            var frame = got.FirstOrDefault(x => x.type == Pad.Frame);
            Size size = default;
            if (frame.payload != null) using (var img = Image.FromStream(new MemoryStream(frame.payload))) size = img.Size;
            Check(size.Width > 100 && Math.Abs((double)size.Width / size.Height - (double)screen.Width / screen.Height) < 0.02,
                  "tablet link: the tablet gets a picture of the screen", $"{(frame.payload?.Length ?? 0) / 1024} KB, {size.Width} x {size.Height}");
            CapturePathCheck(st);
            // what is IN the first picture, not just its size: the screen, as a capture of it shows it
            PictureIsTheScreen(frame.payload, "the first picture (nothing drawn from the tablet)", "39-tablet-first");
            t.Send(Pad.FrameAck, Array.Empty<byte>());
            var next = t.Read(g => g.Any(x => x.type == Pad.Frame), 3000);
            Check(next.Any(x => x.type == Pad.Frame), "tablet link: the next picture comes once the last is acknowledged", $"{next.Count} messages");
            FollowsSlideChange(t, "39b-tablet-slide-changed");

            // a red line drawn on the tablet, across the middle of the screen
            t.Send(Pad.Command, "clear");
            t.Send(Pad.Command, "tool:pen");
            t.Send(Pad.Command, "color:0");
            float fy = (float)(Row(5) - screen.Top) / screen.Height;
            t.Send(Pad.StrokeBegin, PadPoint(0.2f, fy).Concat(new byte[] { 0 }).ToArray());
            var pts = new List<byte> { 0, 10 };
            for (int i = 1; i <= 10; i++) pts.AddRange(PadPoint(0.2f + 0.04f * i, fy));
            t.Send(Pad.StrokePoints, pts.ToArray());
            t.Send(Pad.StrokeEnd, Array.Empty<byte>());
            Thread.Sleep(600);
            var red = ColorTranslator.FromHtml(Settings.Colors[0]);
            int mx = screen.Left + (int)(screen.Width * 0.4);
            var drawn = Closest(Shot("40-tablet-line"), mx, Row(5), red, 6);
            Check(Diff(drawn, red) <= 40, "tablet link: a line drawn on the tablet appears on the screen", Hex(drawn));
            // the tablet's next picture has the line too (the marks are laid over the copy of the screen)
            t.Send(Pad.FrameAck, Array.Empty<byte>());
            t.Read(g => g.Any(x => x.type == Pad.Frame), 3000);   // the one already on its way
            t.Send(Pad.FrameAck, Array.Empty<byte>());
            var withLine = t.Read(g => g.Any(x => x.type == Pad.Frame), 3000).LastOrDefault(x => x.type == Pad.Frame);
            Color inPicture = Color.Black, around = Color.Black, onScreen = Color.White;
            if (withLine.payload != null)
                using (var img = new Bitmap(new MemoryStream(withLine.payload)))
                {
                    double k = (double)img.Width / screen.Width;
                    inPicture = Closest(img, (int)((mx - screen.Left) * k), (int)((Row(5) - screen.Top) * k), red, 4);
                    // and the slide is still there around the marks (it once turned black as soon as anything was drawn:
                    // checking only the line's colour missed it)
                    around = img.GetPixel((int)((mx - screen.Left) * k), (int)((Row(5) - 40 - screen.Top) * k));
                }
            using (var now = Shot("40b-around-the-line")) onScreen = now.GetPixel(mx, Row(5) - 40);
            Check(Diff(inPicture, red) <= 60, "tablet link: the tablet's picture shows the marks", Hex(inPicture));
            Check(Diff(around, onScreen) <= 40, "tablet link: with marks, the tablet's picture still shows the slide around them (not black)",
                  $"picture {Hex(around)}, screen {Hex(onScreen)}");
            // and the whole picture, marks and all, is the screen (it once turned black as soon as anything was drawn)
            PictureIsTheScreen(withLine.payload, "the picture with a line drawn", "40c-tablet-with-line");
            // a picture made while the pen is still down, as an iPad draws (the pictures after STROKE_END were fine on
            // a presenter's PC whose tablet went black while writing)
            MidStrokePicture(t, "40d-tablet-mid-stroke");
            t.Send(Pad.Command, "clear");
            t.Send(Pad.Command, "tool:pen");
            t.Send(Pad.Command, "color:0");
            t.Send(Pad.StrokeBegin, PadPoint(0.2f, fy).Concat(new byte[] { 0 }).ToArray());
            t.Send(Pad.StrokePoints, pts.ToArray());
            t.Send(Pad.StrokeEnd, Array.Empty<byte>());
            Thread.Sleep(600);

            t.Send(Pad.Command, "undo");
            Thread.Sleep(500);
            var undone = Closest(Shot("41-tablet-undo"), mx, Row(5), red, 6);
            Check(IsWhite(undone), "tablet link: undo on the tablet takes it away", Hex(undone));

            int k0 = slide.Keys.Count;
            t.Send(Pad.Command, "next");
            Thread.Sleep(500);
            Check(slide.Keys.Skip(k0).Contains(Keys.Right), "tablet link: next on the tablet turns the slide", "keys seen: " + string.Join(",", slide.Keys.Skip(k0)));

            // a second tablet with the right code takes over (the same tablet back after a Wi-Fi drop)
            using (var again = new TestTablet(port))
            {
                bool took = again.Pair(PadCode);
                Thread.Sleep(300);
                bool firstClosed = ClosedByPc(t.Net, 3000);   // pictures already on their way may still arrive first
                Check(took && firstClosed, "tablet link: the right code again takes over (a tablet back after a Wi-Fi drop)", $"let in {took}, the old connection closed {firstClosed}");
            }
            Thread.Sleep(500);

            // by the cable: an iPad through Apple's USB service needs no Allow (Apple's service vouches for it); then
            // Android's USB link, which reaches the PC's loopback door, where the code is empty but the presenter allows it
            IPadByCable();
            CableDoorAsksFirst();
            using (var noCode = new TestTablet(port))
            {
                noCode.Pair("");
                Check(noCode.Refused == Pad.WrongCode, "USB: on the Wi-Fi port an empty code is still wrong", noCode.Refused);
            }

            // strangers holding places: two from one address at most, and the cable still works while they wait
            var stalled = new List<System.Net.Sockets.TcpClient>();
            try
            {
                for (int i = 0; i < 2; i++)
                {
                    var waiting = new System.Net.Sockets.TcpClient("127.0.0.1", port);
                    using var k = PadCrypto.NewKey();
                    waiting.GetStream().Write(Pad.Message(Pad.Hello, JsonSerializer.Serialize(new { device = "stall", version = 2, key = Convert.ToBase64String(PadCrypto.PublicPoint(k)) })));
                    PadRead(waiting.GetStream(), new PadReader(), g => g.Count > 0, 3000);   // its CHALLENGE: it now waits up to 30 s
                    stalled.Add(waiting);
                }
                using (var third = new System.Net.Sockets.TcpClient("127.0.0.1", port))
                    Check(ClosedByPc(third.GetStream(), 2000), "tablet link: a third waiting connection from one address is turned away", "");
                using (var cable2 = new TestTablet(Pad.UsbPort))
                    Check(cable2.Pair(""), "tablet link: strangers waiting on the Wi-Fi don't block the cable", cable2.Refused);
            }
            finally { foreach (var w in stalled) w.Dispose(); }

            // strangers on the Wi-Fi, without the code: a broken first message once ended the whole app
            foreach (var junk in new[] { new byte[] { 0x01, 0, 0, 0, 1, (byte)'1' }, Pad.Message(Pad.Hello, "{\"version\":2,\"key\":\"\\uD800\"}"), new byte[] { 0x01, 0, 0x10, 0, 0 }, Pad.Message(PadCrypto.Proof, new byte[40]) })
                using (var j = new System.Net.Sockets.TcpClient("127.0.0.1", port))
                {
                    j.GetStream().Write(junk);
                    PadRead(j.GetStream(), new PadReader(), g => g.Count > 0, 1500);
                }
            Thread.Sleep(500);
            Check(!app.HasExited, "tablet link: broken or oversized first messages from strangers don't end the app", app.HasExited ? "the app exited" : "still running");

            // guessing: five wrong codes in a row lock that address out for a while. The right code first, so the wrong
            // ones above (the empty code) no longer count and the run starts at one: tries 1 to 5 must each be told
            // "Wrong code" (a lockout one early would pass a check of the 6th alone), and only the 6th is locked out.
            using (var fresh = new TestTablet(port))
                Check(fresh.Pair(PadCode), "tablet link: the right code again (the run of wrong codes starts afresh)", fresh.Refused);
            var answers = new List<string>();
            for (int i = 0; i < 6; i++)
                using (var g = new TestTablet(port))
                {
                    g.Pair((100000 + i).ToString());
                    answers.Add(g.Refused);
                }
            string Said(string a) => a == Pad.WrongCode ? "wrong code" : a == Pad.TooManyWrong ? "locked" : a.Length == 0 ? "(let in or no answer)" : a;
            Check(answers.Take(5).All(a => a == Pad.WrongCode) && answers[5] == Pad.TooManyWrong,
                  "tablet link: wrong codes 1 to 5 are each told \"Wrong code\", and only the 6th is locked out",
                  string.Join(", ", answers.Select((a, i) => $"{i + 1}: {Said(a)}")));

            // ...only for that address: a tablet at another address still gets in with the right code
            // (127.0.0.2 is this machine too, seen by the PC as a different address)
            var fromOther = new System.Net.Sockets.TcpClient(new System.Net.IPEndPoint(System.Net.IPAddress.Parse("127.0.0.2"), 0));
            fromOther.Connect(System.Net.IPAddress.Loopback, port);
            using (var other = new TestTablet(fromOther))
            {
                bool otherIn = other.Pair(PadCode);
                Check(otherIn, "tablet link: wrong codes from one address don't lock out a tablet at another address", otherIn ? "let in" : "refused: " + other.Refused);
            }
            DiagnosticsCheck(expectBlack: false);
        }
        catch (Exception e) when (e is IOException or System.Net.Sockets.SocketException or JsonException or ArgumentException or InvalidDataException or KeyNotFoundException or FormatException)
        {
            Check(false, "tablet link: the stand-in tablet's conversation", e.Message);
        }
    }

    const int SmallPicture = 400;   // the picture width in the padgdi and padsmall runs (the screen is wider)

    /// <summary>
    /// A run of the tablet's picture alone (see the top of this file): the first picture, the picture after the slide
    /// changed, and the picture with a line drawn, each compared with the screen. In the two controls the picture checks
    /// are not counted one by one: what counts is that the ones that must fail did.
    /// </summary>
    static void PadPictureRun(JsonElement st)
    {
        string tag = runMode.ToUpperInvariant();
        bool control = runMode is "padcontrol" or "padfreeze" or "padblackcontrol";
        int port = st.TryGetProperty("padPort", out var pp) ? pp.GetInt32() : 0;
        Check(port > 0, tag + ": the PC listens for a tablet", "port " + port);
        if (port == 0) return;
        try
        {
            using var t = new TestTablet(port);
            bool paired = t.Pair(PadCode);
            Check(paired, tag + ": the stand-in tablet is let in", paired ? "WELCOME opened" : "refused: " + t.Refused);
            if (!paired) return;
            var first = t.Read(g => g.Any(x => x.type == Pad.Frame), 8000).FirstOrDefault(x => x.type == Pad.Frame).payload;
            CapturePathCheck(st);
            if (runMode is "padgdi" or "padsmall")
            {
                int width = 0;
                if (first != null) using (var img = Image.FromStream(new MemoryStream(first))) width = img.Width;
                Check(width == SmallPicture, $"{tag}: the picture is made smaller than the screen ({SmallPicture} px wide)", $"{width} px wide, the screen {screen.Width}");
            }
            counting = !control;
            bool before = PictureIsTheScreen(first, "the first picture", "39-tablet-first");
            bool follows = FollowsSlideChange(t, "39b-tablet-slide-changed");
            byte[]? withLine = DrawLineAndGetPicture(t);
            bool after = PictureIsTheScreen(withLine, "the picture with a line drawn", "40c-tablet-with-line");
            bool during = MidStrokePicture(t, "40d-tablet-mid-stroke");
            counting = true;
            t.Send(Pad.Command, "clear");
            if (runMode == "padblackcontrol")
                Check(first != null && before && !during,
                      "BLACK CONTROL: with the copy black while marks are drawn and the fix off, the first picture matches but the mid-stroke picture check FAILS",
                      $"first {Verdict(before)}, with a line {Verdict(after)}, mid-stroke {Verdict(during)}");
            if (runMode != "padfreeze") DiagnosticsCheck(expectBlack: runMode is "padblack" or "padblackcontrol");   // frozen: no new pictures to note
            if (runMode == "padcontrol")
                Check(first != null && withLine != null && !before && !follows && !after && !during,
                      "PAD CONTROL: with the tablet's picture whitened, the checks of the tablet's picture FAIL",
                      $"pictures came: {first != null && withLine != null}; first {Verdict(before)}, after the slide changed {Verdict(follows)}, with a line {Verdict(after)}, mid-stroke {Verdict(during)}");
            else if (runMode == "padfreeze")
                Check(first != null && before && !follows,
                      "FREEZE CONTROL: with the picture frozen after the first, the first still matches but the check that it follows the slide FAILS",
                      $"first {Verdict(before)}, after the slide changed {Verdict(follows)}, with a line {Verdict(after)}");
        }
        catch (Exception e) when (e is IOException or System.Net.Sockets.SocketException or JsonException or ArgumentException or InvalidDataException or KeyNotFoundException or FormatException)
        {
            counting = true;
            Check(false, tag + ": the stand-in tablet's conversation", e.Message);
        }
    }

    static string Verdict(bool passed) => passed ? "passed" : "failed";

    /// <summary>The next picture after now: the one already on its way is acknowledged and skipped.</summary>
    static byte[]? NextPicture(TestTablet t)
    {
        t.Send(Pad.FrameAck, Array.Empty<byte>());
        t.Read(g => g.Any(x => x.type == Pad.Frame), 3000);
        t.Send(Pad.FrameAck, Array.Empty<byte>());
        return t.Read(g => g.Any(x => x.type == Pad.Frame), 3000).LastOrDefault(x => x.type == Pad.Frame).payload;
    }

    /// <summary>A red line drawn from the tablet across the screen, and the picture after it.</summary>
    static byte[]? DrawLineAndGetPicture(TestTablet t)
    {
        t.Send(Pad.Command, "clear");
        t.Send(Pad.Command, "tool:pen");
        t.Send(Pad.Command, "color:0");
        float fy = (float)(Row(5) - screen.Top) / screen.Height;
        t.Send(Pad.StrokeBegin, PadPoint(0.2f, fy).Concat(new byte[] { 0 }).ToArray());
        var pts = new List<byte> { 0, 10 };
        for (int i = 1; i <= 10; i++) pts.AddRange(PadPoint(0.2f + 0.04f * i, fy));
        t.Send(Pad.StrokePoints, pts.ToArray());
        t.Send(Pad.StrokeEnd, Array.Empty<byte>());
        Thread.Sleep(600);
        return NextPicture(t);
    }

    /// <summary>
    /// A red line drawn as an iPad draws it: STROKE_BEGIN, then two points every 20 ms or so for about 1.6 s, each
    /// picture acknowledged as it arrives (as the iPad does while its pen is down), and then, the pen still down, the
    /// next picture compared with the screen and looked at for the line so far. STROKE_END only after that. The other
    /// checks look at pictures made after STROKE_END; a presenter's tablet went black only while writing.
    /// </summary>
    static bool MidStrokePicture(TestTablet t, string name)
    {
        t.Send(Pad.Command, "clear");
        t.Send(Pad.Command, "tool:pen");
        t.Send(Pad.Command, "color:0");
        Thread.Sleep(300);
        NextPicture(t);   // a picture of the cleared screen first (no marks), as before a presenter writes
        float fy = (float)(Row(7) - screen.Top) / screen.Height;
        const float x0 = 0.15f, x1 = 0.65f;
        const int points = 160;
        t.Send(Pad.StrokeBegin, PadPoint(x0, fy).Concat(new byte[] { 0 }).ToArray());
        int framesWhileMoving = 0;
        var sw = Stopwatch.StartNew();
        for (int i = 1; i <= points; i += 2)
        {
            var batch = new List<byte> { 0, 2 };
            batch.AddRange(PadPoint(x0 + (x1 - x0) * i / points, fy));
            batch.AddRange(PadPoint(x0 + (x1 - x0) * (i + 1) / points, fy));
            t.Send(Pad.StrokePoints, batch.ToArray());
            foreach (var m in t.Read(g => g.Any(x => x.type == Pad.Frame), 20))
                if (m.type == Pad.Frame) { framesWhileMoving++; t.Send(Pad.FrameAck, Array.Empty<byte>()); }
        }
        Check(framesWhileMoving >= 3, "tablet link: pictures keep coming while the tablet's pen moves",
              $"{framesWhileMoving} pictures in {sw.ElapsedMilliseconds} ms of drawing");
        Thread.Sleep(300);
        var during = NextPicture(t);   // made with the pen still down: no STROKE_END yet
        bool same = PictureIsTheScreen(during, "a picture made mid-stroke (the tablet's pen still down)", name);
        var red = ColorTranslator.FromHtml(Settings.Colors[0]);
        Color inPicture = Color.Black;
        int width = 0;
        if (during != null)
            using (var img = new Bitmap(new MemoryStream(during)))
            {
                width = img.Width;
                double k = (double)img.Width / screen.Width;
                inPicture = Closest(img, (int)(screen.Width * 0.4 * k), (int)((Row(7) - screen.Top) * k), red, 4);
            }
        // in the 400 px runs the line is under a pixel wide, blended away: there only the whole picture is compared
        bool line = width > 0 && width < 800 || Diff(inPicture, red) <= 60;
        Check(line, "tablet link: the picture made mid-stroke shows the line drawn so far", width > 0 && width < 800 ? $"not looked for: the picture is {width} px wide" : Hex(inPicture));
        t.Send(Pad.StrokeEnd, Array.Empty<byte>());
        Thread.Sleep(300);
        NextPicture(t);
        return same && line;
    }

    static string DiagFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ContrastInk");
    static string DiagLog => Path.Combine(DiagFolder, "pad-diagnostics.txt");
    static string DiagBlack => Path.Combine(DiagFolder, "pad-black.jpg");
    static string DiagStroke => Path.Combine(DiagFolder, "pad-during-stroke.jpg");

    /// <summary>
    /// The app's notes on the tablet's picture (always on): a line for the tablet connecting, the first picture made
    /// during a tablet stroke noted and kept; with the copy made black, the mostly-black picture noted (made during the
    /// stroke) and kept. The notes are printed and the pictures copied next to the screenshots.
    /// </summary>
    static void DiagnosticsCheck(bool expectBlack)
    {
        Thread.Sleep(300);
        string log = SafeRead(DiagLog);
        Log("      pad-diagnostics.txt:");
        foreach (var l in log.Split('\n', StringSplitOptions.RemoveEmptyEntries).Take(40)) Log("        " + l);
        foreach (var f in new[] { DiagBlack, DiagStroke })
            if (File.Exists(f)) try { File.Copy(f, Path.Combine(outDir, $"{runMode}-{Path.GetFileName(f)}"), overwrite: true); } catch (IOException) { }
        Check(log.Contains("tablet connected (") && log.Contains("| Windows ") && log.Contains("| layer exstyle 0x"),
              "diagnostics: pad-diagnostics.txt notes the tablet connecting (Windows, screen, exstyle)", $"{log.Length} characters");
        Check(log.Contains("first picture during a tablet stroke") && File.Exists(DiagStroke),
              "diagnostics: the first picture made during a tablet stroke is noted, and kept as pad-during-stroke.jpg", $"kept: {File.Exists(DiagStroke)}");
        if (expectBlack)
        {
            bool noted = log.Split('\n').Any(l => l.Contains("mostly-black picture") && l.Contains("tablet stroke in progress"));
            Check(noted && File.Exists(DiagBlack), "diagnostics: the black picture during the stroke is noted, and kept as pad-black.jpg", $"noted {noted}, kept {File.Exists(DiagBlack)}");
        }
    }

    /// <summary>
    /// The slide changes after the tablet's first picture (a large blue block appears on it): the next picture must
    /// show it, as the screen does. A capture that froze on its first frame fails here (the padfreeze control).
    /// </summary>
    static bool FollowsSlideChange(TestTablet t, string name)
    {
        slide.Invoke(() => slide.ShowBlock(true));
        Thread.Sleep(500);
        var pic = NextPicture(t);
        bool same = PictureIsTheScreen(pic, "the picture after the slide changed", name);
        var inPicture = Color.Black;
        if (pic != null)
            using (var img = new Bitmap(new MemoryStream(pic)))
            {
                double k = (double)img.Width / screen.Width;
                var c = slide.BlockCenter;
                inPicture = img.GetPixel(Math.Clamp((int)((c.X - screen.Left) * k), 0, img.Width - 1), Math.Clamp((int)((c.Y - screen.Top) * k), 0, img.Height - 1));
            }
        bool block = Diff(inPicture, Slide.BlockColor) <= 40;
        Check(block, "tablet link: the picture follows the slide (the block that appeared is in it)", $"want {Hex(Slide.BlockColor)}, picture has {Hex(inPicture)}");
        slide.Invoke(() => slide.ShowBlock(false));
        Thread.Sleep(400);
        NextPicture(t);
        return same && block;
    }

    /// <summary>Which way the app made the tablet's picture (it writes it next to its status in test runs): logged,
    /// and it must be the way the user gets: Windows.Graphics.Capture on Windows 11 (build 20348 on), the GDI copy on
    /// Windows 10 (no capture border for the audience) and in the run that forces it.</summary>
    static void CapturePathCheck(JsonElement st)
    {
        string file = statusPath + ".capture.txt", how = "";
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < 3000 && (how = SafeRead(file)).Length == 0) Thread.Sleep(100);
        Log("      tablet picture made by: " + (how.Length > 0 ? how : "(not reported)"));
        int build = st.TryGetProperty("windowsBuild", out var b) ? b.GetInt32() : 0;
        bool ok = runMode == "padgdi" ? how == "gdi (forced by the test)"
                : build >= PadCaptureChoice.BorderlessBuild ? how == "wgc"
                : how.StartsWith("gdi", StringComparison.Ordinal);
        Check(ok, runMode == "padgdi" ? "tablet link: this run's picture is the GDI copy (forced)"
                  : "tablet link: the picture is made the way the user gets it (Windows.Graphics.Capture on Windows 11, the GDI copy on Windows 10)",
              $"Windows build {build}, made by: {(how.Length > 0 ? how : "not reported")}");
    }

    static string SafeRead(string f) { try { return File.Exists(f) ? File.ReadAllText(f).Trim() : ""; } catch (IOException) { return ""; } }

    /// <summary>
    /// The tablet's picture against a capture of the same screen taken now: both cut into a grid of cells, each cell's
    /// mean colour compared, and the mean difference over the whole screen must be small; and the slide's black stripe
    /// must be dark in the tablet's picture (a white picture differs from a white slide only there). True if both hold.
    /// </summary>
    static bool PictureIsTheScreen(byte[]? jpeg, string what, string name)
    {
        if (jpeg == null) { Check(false, $"tablet link: {what} matches the screen", "no picture came"); return false; }
        using var pic = new Bitmap(new MemoryStream(jpeg));
        pic.Save(Path.Combine(outDir, $"{runMode}-{name}-tablet.png"), ImageFormat.Png);
        using var shot = Shot(name + "-screen");
        const int GX = 32, GY = 18;
        var a = CellMeans(pic, GX, GY); var b = CellMeans(shot, GX, GY);
        double sum = 0, worst = 0; int worstCell = 0;
        for (int i = 0; i < a.Length; i++)
        {
            double d = Math.Abs(a[i] - b[i]);
            sum += d;
            if (d > worst) { worst = d; worstCell = i / 3; }
        }
        double mean = sum / a.Length;
        bool same = mean < 8;
        Check(same, $"tablet link: {what} is the screen (grid {GX}x{GY}, mean difference from a capture of the screen under 8 of 255)",
              $"mean {mean:0.0}, worst cell {worst:0} at column {worstCell % GX}, row {worstCell / GX}");
        // the black stripe, away from the rows where lines are drawn
        double k = (double)pic.Width / screen.Width;
        int sx = (int)((slide.StripeCenterX - screen.Left) * k);
        var samples = new[] { 0.12, 0.22, 0.88 }.Select(f => pic.GetPixel(Math.Clamp(sx, 0, pic.Width - 1), Math.Clamp((int)(pic.Height * f), 0, pic.Height - 1))).ToList();
        bool dark = samples.All(c => c.R + c.G + c.B < 150);
        Check(dark, $"tablet link: in {what}, the slide's black stripe is dark", string.Join(" ", samples.Select(Hex)));
        return same && dark;
    }

    /// <summary>The mean colour (B, G, R) of each cell of a gx x gy grid over the picture.</summary>
    static double[] CellMeans(Bitmap bmp, int gx, int gy)
    {
        var res = new double[gx * gy * 3];
        var n = new int[gx * gy];
        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var row = new byte[bmp.Width * 4];
            for (int y = 0; y < bmp.Height; y++)
            {
                Marshal.Copy(data.Scan0 + y * data.Stride, row, 0, row.Length);
                int cy = Math.Min(gy - 1, y * gy / bmp.Height);
                for (int x = 0; x < bmp.Width; x++)
                {
                    int c = cy * gx + Math.Min(gx - 1, x * gx / bmp.Width);
                    res[c * 3] += row[x * 4]; res[c * 3 + 1] += row[x * 4 + 1]; res[c * 3 + 2] += row[x * 4 + 2];
                    n[c]++;
                }
            }
        }
        finally { bmp.UnlockBits(data); }
        for (int c = 0; c < n.Length; c++) for (int j = 0; j < 3; j++) res[c * 3 + j] /= Math.Max(1, n[c]);
        return res;
    }

    /// <summary>
    /// An iPad on the cable, as the PC sees it through Apple's USB service: a stand-in service on 127.0.0.1:27015
    /// lists one iPad; when the PC asks to connect to its port 47830, the stand-in answers "connected" and from then
    /// on plays the iPad on that connection (HELLO with an empty code). A line drawn must appear on the screen.
    /// </summary>
    static void IPadByCable()
    {
        System.Net.Sockets.TcpListener service;
        try { service = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 27015); service.Start(); }
        catch (System.Net.Sockets.SocketException e) { Check(false, "USB: a stand-in Apple USB service could start", e.Message); return; }
        try
        {
            System.Net.Sockets.TcpClient? tunnel = null;
            int askedPort = -1;
            var until = DateTime.UtcNow.AddSeconds(15);
            while (tunnel == null && DateTime.UtcNow < until)
            {
                if (!service.Pending()) { Thread.Sleep(50); continue; }
                var c = service.AcceptTcpClient();
                var s = c.GetStream();
                s.ReadTimeout = 3000;
                string body;
                try
                {
                    var head = ReadN(s, 16);
                    body = System.Text.Encoding.UTF8.GetString(ReadN(s, BitConverter.ToInt32(head, 0) - 16));
                }
                catch (IOException) { c.Dispose(); continue; }   // the PC gave up on a connection (its 0.5 s limit): normal
                string reply;
                if (body.Contains("<string>ListDevices</string>"))
                    reply = "<plist version=\"1.0\"><dict><key>DeviceList</key><array><dict><key>DeviceID</key><integer>7</integer>"
                          + "<key>MessageType</key><string>Attached</string><key>Properties</key><dict><key>ConnectionType</key><string>USB</string>"
                          + "<key>DeviceID</key><integer>7</integer></dict></dict></array></dict></plist>";
                else
                {
                    var m = System.Text.RegularExpressions.Regex.Match(body, "<key>PortNumber</key><integer>(\\d+)</integer>");
                    int sw = m.Success ? int.Parse(m.Groups[1].Value) : -1;
                    askedPort = ((sw & 0xFF) << 8) | ((sw >> 8) & 0xFF);
                    reply = "<plist version=\"1.0\"><dict><key>MessageType</key><string>Result</string><key>Number</key><integer>0</integer></dict></plist>";
                }
                var rb = System.Text.Encoding.UTF8.GetBytes(reply);
                var rh = new byte[16];
                BitConverter.GetBytes(16 + rb.Length).CopyTo(rh, 0); BitConverter.GetBytes(1).CopyTo(rh, 4); BitConverter.GetBytes(8).CopyTo(rh, 8); BitConverter.GetBytes(1).CopyTo(rh, 12);
                s.Write(rh); s.Write(rb);
                if (body.Contains("<string>Connect</string>")) tunnel = c; else c.Dispose();
            }
            Check(tunnel != null && askedPort == Pad.UsbPort, "USB: the PC finds the plugged-in iPad and connects to its pad port through Apple's USB service",
                  tunnel == null ? "never asked to connect" : "asked for port " + askedPort);
            if (tunnel == null) return;
            using var ipad = new TestTablet(tunnel);
            bool inByCable = ipad.Pair("");
            Check(inByCable && ToolbarName("Allow") == null, "USB: the iPad is let in by the cable with no code, and no question for the presenter",
                  inByCable ? "let in, " + (ToolbarName("Allow") == null ? "nothing asked" : "Allow shown") : ipad.Refused);
            if (!inByCable) return;
            ipad.Send(Pad.Command, "clear");
            ipad.Send(Pad.Command, "tool:pen");
            ipad.Send(Pad.Command, "color:0");
            float fy = (float)(Row(6) - screen.Top) / screen.Height;
            ipad.Send(Pad.StrokeBegin, PadPoint(0.2f, fy).Concat(new byte[] { 0 }).ToArray());
            var pts = new List<byte> { 0, 10 };
            for (int i = 1; i <= 10; i++) pts.AddRange(PadPoint(0.2f + 0.04f * i, fy));
            ipad.Send(Pad.StrokePoints, pts.ToArray());
            ipad.Send(Pad.StrokeEnd, Array.Empty<byte>());
            Thread.Sleep(600);
            var red = ColorTranslator.FromHtml(Settings.Colors[0]);
            var drawn = Closest(Shot("42-ipad-by-cable"), screen.Left + (int)(screen.Width * 0.4), Row(6), red, 6);
            Check(Diff(drawn, red) <= 40, "USB: a line drawn on the iPad by the cable appears on the screen", Hex(drawn));
            ipad.Send(Pad.Command, "clear");
            Thread.Sleep(300);
        }
        catch (Exception e) when (e is IOException or System.Net.Sockets.SocketException or JsonException or KeyNotFoundException or FormatException)
        {
            Check(false, "USB: the stand-in iPad's conversation", e.Message);
        }
        finally { service.Stop(); }
    }

    /// <summary>
    /// The Android cable door (127.0.0.1:47830, where adb reverse arrives): any program on the PC, or any app on the
    /// tablet, can reach it, so the first session there in each run waits for the presenter's Allow on the toolbar.
    /// Deny turns it away; Allow lets it in; after that the run doesn't ask again.
    /// </summary>
    static void CableDoorAsksFirst()
    {
        using (var denied = new TestTablet(Pad.UsbPort))
        {
            var pairing = System.Threading.Tasks.Task.Run(() => denied.Pair("", answerMs: 20000));
            WaitFor(() => ToolbarName("Allow") != null || pairing.IsCompleted, 8000);
            bool asked = ToolbarName("An Android tablet on the USB cable") != null && ToolbarName("Allow") != null;
            bool inEarly = pairing.IsCompleted && pairing.Result;
            Shot("43-cable-door-asks");
            Press("Deny");
            bool done = pairing.Wait(8000);
            Check(asked && !inEarly && done && !pairing.Result && denied.Refused == Pad.NotAllowed,
                  "USB: the first tablet on the Android cable door waits for the presenter, and Deny turns it away",
                  $"asked {asked}, let in before an answer {inEarly}, answered {done}, refused: {denied.Refused}");
        }
        WaitFor(() => ToolbarName("Allow") == null, 2000);
        Check(ToolbarName("Allow") == null, "USB: the question goes once answered", ToolbarName("Allow") == null ? "gone" : "still shown");
        using (var cable = new TestTablet(Pad.UsbPort))
        {
            var pairing = System.Threading.Tasks.Task.Run(() => cable.Pair("", answerMs: 20000));
            WaitFor(() => ToolbarName("Allow") != null || pairing.IsCompleted, 8000);
            bool asked = ToolbarName("Allow") != null;
            Press("Allow");
            bool ok = pairing.Wait(8000) && pairing.Result;
            Check(asked && ok, "USB: Allow lets the tablet on the Android cable door in, with no code", $"asked {asked}, let in {ok} {cable.Refused}");
        }
        using (var again = new TestTablet(Pad.UsbPort))
        {
            bool ok = again.Pair("");
            Check(ok && ToolbarName("Allow") == null, "USB: once allowed, the cable door doesn't ask again in this run", ok ? "let in at once" : again.Refused);
        }
    }

    static byte[] ReadN(System.Net.Sockets.NetworkStream s, int n)
    {
        var b = new byte[n];
        for (int got = 0; got < n;) { int k = s.Read(b, got, n - got); if (k <= 0) throw new IOException("closed"); got += k; }
        return b;
    }

    /// <summary>Reads (and drops) whatever is still coming until the PC closes the connection: true if it did in time.</summary>
    static bool ClosedByPc(System.Net.Sockets.NetworkStream s, int ms)
    {
        var buf = new byte[1 << 16];
        var until = DateTime.UtcNow.AddMilliseconds(ms);
        s.ReadTimeout = 250;
        while (DateTime.UtcNow < until)
        {
            try { if (s.Read(buf, 0, buf.Length) <= 0) return true; }
            catch (IOException e) when (e.InnerException is System.Net.Sockets.SocketException { SocketErrorCode: System.Net.Sockets.SocketError.TimedOut }) { }
            catch (Exception) { return true; }   // reset by the PC: closed too
        }
        return false;
    }

    // ---------------------------------------------------------------- undo, every way, and marks for each slide
    const string UndoTitle = "Contrast Ink undo button";
    static readonly Color UndoBlue = ColorTranslator.FromHtml("#2563EB");

    /// <summary>The undo button is on the screen (the app parks it off-screen rather than hiding it).</summary>
    static bool UndoOnScreen() { var b = Native.WindowBox(UndoTitle); return Native.IsVisible(UndoTitle) && b.Width > 0 && b.IntersectsWith(screen); }

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
        bool shown = UndoOnScreen();
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
            Press("Settings");   // closed again before drawing: the open panel covers the top of a 768-high slide
            Line(3);
            int k0 = slide.Keys.Count;
            Key('Z'); Thread.Sleep(300);
            RightClick(blank); Thread.Sleep(400);
            shot = Shot("35-undo-switched-off");
            Check(Red(shot, 3), "settings: with Z and right-click switched off, neither undoes", At(shot, 3));
            Check(slide.Keys.Skip(k0).Contains(Keys.Z), "settings: Z switched off reaches the slides instead", "keys seen: " + string.Join(",", slide.Keys.Skip(k0)));
            Check(!UndoOnScreen(), "settings: the undo button switched off does not appear", "visible " + UndoOnScreen());
            Press("Settings");
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
            Check(Red(shot, 4) && !Red(shot, 5) && UndoOnScreen(), "undo button: one tap takes the last mark only, and it stays for the next",
                  $"first mark {At(shot, 4)}, second {At(shot, 5)}, button visible {UndoOnScreen()}");
            Click(tap); Thread.Sleep(400);
            shot = Shot("45-two-taps");
            Check(!Red(shot, 4), "undo button: a second tap takes the mark before", At(shot, 4));
            Check(!UndoOnScreen(), "undo button: with nothing left to undo on this slide, it goes", "visible " + UndoOnScreen());

            ppt.SlideShowWindows.Show.View.CurrentShowPosition = 2; Thread.Sleep(900);
            ppt.SlideShowWindows.Count = 0; Thread.Sleep(900);          // the slide show ends
            shot = Shot("43-show-ended");
            Check(!Red(shot, 1), "slide show ended: the slides' marks go with it", At(shot, 1));
            ppt.SlideShowWindows.Count = 1; Thread.Sleep(900);          // the same show started again (rehearsal, then the real one)
            shot = Shot("46-show-started-again");
            Check(!Red(shot, 1), "the same slide show started again: the last show's marks don't come back", At(shot, 1));
            ppt.SlideShowWindows.Count = 0; Thread.Sleep(900);
        }
        finally { FakePowerPoint.Revoke(cookie); }
        Thread.Sleep(900);
        Key('C'); Key(VK.F9); Thread.Sleep(300);
    }

    // ---------------------------------------------------------------- recording with OBS, against a stand-in OBS
    static bool OnToolbar(string textStarts) => FindToolbarButton(textStarts) != null;
    static void WaitFor(Func<bool> done, int ms) { var sw = Stopwatch.StartNew(); while (!done() && sw.ElapsedMilliseconds < ms) Thread.Sleep(100); }

    static void RecordingWithObs()
    {
        var ppt = new FakePowerPoint();
        uint cookie = FakePowerPoint.Register(ppt);
        FakeObs? obs = null;
        try
        {
            Thread.Sleep(900);   // the app sees slide 1

            // OBS's remote control switched off (OBS's default)
            Directory.CreateDirectory(Path.GetDirectoryName(FakeObs.ConfigPath)!);
            File.WriteAllText(FakeObs.ConfigPath, "{\"server_enabled\":false,\"server_password\":\"x\"}");
            Press("Record with OBS");
            WaitFor(() => OnToolbar("In OBS, open Tools"), 3000);
            Check(OnToolbar("In OBS, open Tools"), "OBS's remote control off: the toolbar says how to switch it on", OnToolbar("In OBS, open Tools") ? "shown" : "not shown");

            // switched on, OBS not running
            FakeObs.WriteConfig();
            Press("Record with OBS");
            WaitFor(() => OnToolbar("Can't reach OBS"), 6000);
            Check(OnToolbar("Can't reach OBS"), "OBS not running: the toolbar says to open it", OnToolbar("Can't reach OBS") ? "shown" : "not shown");

            // OBS running, with a password that doesn't match what Contrast Ink read
            File.WriteAllText(FakeObs.ConfigPath, File.ReadAllText(FakeObs.ConfigPath).Replace(FakeObs.Password, "not-the-password"));
            // a connection attempt begun before (with the right password read) keeps retrying for ~2 s on Windows:
            // let it give up first, or it reaches the stand-in and this check measures the wrong attempt
            Thread.Sleep(3000);
            obs = new FakeObs { OutputPath = Path.Combine(outDir, "lecture-check.mkv") };
            Press("Record with OBS");
            WaitFor(() => OnToolbar("OBS refused the password"), 6000);
            Check(obs.WrongPassword && obs.Identifications == 0 && OnToolbar("OBS refused the password"), "a wrong password: OBS refuses, and the toolbar says so",
                  $"refused {obs.WrongPassword}, accepted {obs.Identifications} time(s), toolbar {(OnToolbar("OBS refused the password") ? "says so" : "silent")}");
            Check(obs.Count("StartRecord") == 0, "a wrong password records nothing", "StartRecord asked " + obs.Count("StartRecord") + " times");

            // the real thing: OBS's own password, read from OBS's settings
            FakeObs.WriteConfig();
            var recBefore = FindToolbarButton("Record with OBS");
            Press("Record with OBS");
            WaitFor(() => obs.Recording, 6000);
            Thread.Sleep(600);
            var recAfter = FindToolbarButton("Stop recording");
            Check(recBefore != null && recBefore == recAfter, "pressing ⏺ doesn't move the toolbar: ⏹ is where ⏺ was", $"⏺ at {recBefore}, ⏹ at {recAfter}");
            Check(obs.Identified, "Contrast Ink connects with the password from OBS's own settings", "identified " + obs.Identified);
            Check(obs.Recording && obs.Count("StartRecord") == 1, "⏺ starts OBS recording", $"recording {obs.Recording}, StartRecord asked {obs.Count("StartRecord")} time(s)");
            WaitFor(() => OnToolbar("Stop recording"), 2000);
            Check(OnToolbar("Stop recording") && !OnToolbar("OBS refused"), "the toolbar shows ⏹ while recording, and the old message is gone", OnToolbar("Stop recording") ? "⏹ shown" : "no ⏹");
            // slides 11 s apart: YouTube drops a chapter list with a chapter under 10 s, so shorter ones are merged
            Thread.Sleep(11000);
            ppt.SlideShowWindows.Show.View.CurrentShowPosition = 2; Thread.Sleep(11000);
            ppt.SlideShowWindows.Show.View.Hidden = 2;               // two hidden slides: position 3 in the show is slide 5
            ppt.SlideShowWindows.Show.View.HiddenFrom = 3;
            ppt.SlideShowWindows.Show.View.CurrentShowPosition = 3; Thread.Sleep(11000);
            Check(OnToolbar("0:"), "the toolbar shows the recording time", ToolbarName("0:") ?? "no timer");
            var names = string.Join(", ", obs.ChapterNames);
            Check(names == "Slide 2, Slide 5", "each slide change is a chapter in OBS's video, named by PowerPoint's own slide number", "chapters asked: " + names);

            var pausePoint = FindToolbarButton("Pause recording");
            Press("Pause recording");
            WaitFor(() => obs.Paused, 2000);
            Shot("50-paused");
            Check(obs.Paused && OnToolbar("Resume recording"), "⏸ pauses OBS, and the button becomes ▶",
                  $"paused {obs.Paused}, clicked at {pausePoint}, the record button at {FindToolbarButton("Stop recording")}, OBS was asked: {string.Join(",", obs.Requests.Where(r => r != "GetRecordStatus").TakeLast(4))}");
            ppt.SlideShowWindows.Show.View.CurrentShowPosition = 4; Thread.Sleep(1300);   // moved on while paused
            Check(!obs.ChapterNames.Contains("Slide 6"), "no chapter while paused", string.Join(", ", obs.ChapterNames));
            Press("Resume recording");
            WaitFor(() => !obs.Paused, 2000);
            Check(!obs.Paused && obs.Recording, "▶ resumes", $"paused {obs.Paused}, recording {obs.Recording}");
            WaitFor(() => obs.ChapterNames.Contains("Slide 6"), 2000);
            Check(obs.ChapterNames.Contains("Slide 6"), "after ▶, the slide moved to while paused gets its chapter", string.Join(", ", obs.ChapterNames));
            Thread.Sleep(11000);

            // the line to OBS drops while OBS goes on recording; Contrast Ink connects again and takes the same
            // recording over: its chapters so far are kept (before, they were cleared and "Slide 6" stamped at 0:00)
            obs.DropLine();
            WaitFor(() => OnToolbar("Lost contact with OBS"), 4000);
            Check(OnToolbar("Lost contact with OBS"), "the line to OBS dropping mid-recording: the toolbar says so", OnToolbar("Lost contact with OBS") ? "said" : "silent");
            WaitFor(() => obs.Identified && OnToolbar("Stop recording"), 12000);
            Check(OnToolbar("Stop recording"), "OBS reached again while still recording: the toolbar takes the recording over (⏹)", OnToolbar("Stop recording") ? "⏹ shown" : "still ⏺");
            if (OnToolbar("Lost contact with OBS")) Press("Lost contact with OBS");   // dismissed (if a hover hint is not showing instead)

            Press("Stop recording");
            WaitFor(() => !obs.Recording, 3000);
            Thread.Sleep(500);
            Check(!obs.Recording && OnToolbar("Record with OBS"), "⏹ stops OBS recording, and the toolbar is ready again", $"recording {obs.Recording}");
            var chaptersFile = Path.Combine(outDir, "lecture-check chapters.txt");
            var lines = File.Exists(chaptersFile) ? File.ReadAllLines(chaptersFile) : Array.Empty<string>();
            Check(lines.Length == 4 && lines[0] == "0:00 Slide 1" && lines[1].EndsWith(" Slide 2") && lines[2].EndsWith(" Slide 5") && lines[3].EndsWith(" Slide 6") && lines[1] != "0:00 Slide 2",
                  "a chapters file is saved beside the video, ready for a YouTube description (the chapters before the line dropped kept)",
                  File.Exists(chaptersFile) ? string.Join(" | ", lines) : "no file");
            var times = lines.Select(l => l.Split(' ')[0].Split(':').Select(int.Parse).Aggregate(0, (a, b) => a * 60 + b)).ToList();
            Check(times.Count > 1 && times.Zip(times.Skip(1), (a, b) => b - a).All(g => g >= 10), "no chapter is shorter than 10 s (YouTube ignores the list otherwise)", string.Join(", ", times) + " s");

            ppt.SlideShowWindows.Show.View.HiddenFrom = int.MaxValue;
            // started from OBS itself: the toolbar follows
            ppt.SlideShowWindows.Show.View.CurrentShowPosition = 1; Thread.Sleep(900);
            obs.StartByItself().Wait();
            WaitFor(() => OnToolbar("Stop recording"), 3000);
            Check(OnToolbar("Stop recording"), "recording started in OBS itself: the toolbar shows ⏹ too", OnToolbar("Stop recording") ? "⏹ shown" : "still ⏺");

            // ✕ while recording: warned first, so OBS isn't left recording unseen
            Press("Quit Contrast Ink");
            Thread.Sleep(500);
            Check(!app.HasExited && OnToolbar("OBS is still recording"), "✕ while recording: the first press warns instead of quitting",
                  $"app running {!app.HasExited}, warning {(OnToolbar("OBS is still recording") ? "shown" : "not shown")}");
            Press("OBS is still recording");
            Press("Stop recording");
            WaitFor(() => !obs.Recording, 3000);

            // OBS stops by itself
            Press("Record with OBS");
            WaitFor(() => obs.Recording, 3000);
            obs.StopByItself().Wait();
            WaitFor(() => OnToolbar("OBS stopped recording by itself"), 3000);
            Check(OnToolbar("OBS stopped recording by itself") && OnToolbar("Record with OBS"), "OBS stopping by itself: the toolbar says so, and is ready to record again",
                  OnToolbar("OBS stopped recording by itself") ? "said" : "silent");
            Press("OBS stopped recording by itself");
            Check(!OnToolbar("OBS stopped recording by itself"), "clicking a message dismisses it", OnToolbar("OBS stopped recording by itself") ? "still there" : "gone");

            // ⏹ answered late (OBS busy finishing the file): "OBS didn't stop" shows after 5 s, and goes when OBS
            // then reports it stopped (it stayed, wrong, before)
            Press("Record with OBS");
            WaitFor(() => obs.Recording, 3000);
            obs.StopLate = true;
            Press("Stop recording");
            WaitFor(() => OnToolbar("OBS didn't stop"), 7000);
            bool saidLate = OnToolbar("OBS didn't stop");
            WaitFor(() => !obs.Recording && !OnToolbar("OBS didn't stop"), 5000);
            Thread.Sleep(300);
            Check(saidLate && !OnToolbar("OBS didn't stop") && OnToolbar("Record with OBS"), "OBS answering ⏹ late: once it reports it stopped, \"OBS didn't stop\" goes",
                  $"said after 5 s {saidLate}, still said {OnToolbar("OBS didn't stop")}, ready to record {OnToolbar("Record with OBS")}");
            obs.StopLate = false;

            // the disk filling up
            obs.DiskMB = 900;
            Press("Record with OBS");
            WaitFor(() => OnToolbar("Only 0.9 GB left"), 3000);
            Check(OnToolbar("Only 0.9 GB left"), "low disk space while recording: the toolbar warns", OnToolbar("Only 0.9 GB left") ? "warned" : "silent");
            Press("Stop recording");
            WaitFor(() => !obs.Recording, 3000);

            // a scene without Display Capture (the marks would not be in the video)
            obs.DiskMB = 50_000; obs.SceneHasScreen = false;
            Press("Record with OBS");
            WaitFor(() => OnToolbar("OBS's scene \"Lecture\" has no Display Capture"), 3000);
            Check(OnToolbar("OBS's scene \"Lecture\" has no Display Capture"), "a scene without Display Capture: the toolbar warns the marks won't be recorded", "");

            // OBS closes while recording (after a slide change, so there are chapters to keep)
            ppt.SlideShowWindows.Show.View.CurrentShowPosition = 2; Thread.Sleep(1300);
            var closedAt = DateTime.Now.AddSeconds(-1);   // (a file of the same minute, from the dropped line above, is written over)
            obs.Dispose(); obs = null;
            WaitFor(() => OnToolbar("Lost contact with OBS"), 4000);
            Check(OnToolbar("Lost contact with OBS") && OnToolbar("Record with OBS"), "OBS closing mid-recording: the toolbar says so", OnToolbar("Lost contact with OBS") ? "said" : "silent");
            var orphans = Directory.GetFiles(outDir, "Contrast Ink chapters *.txt").Where(f => File.GetLastWriteTime(f) >= closedAt).ToArray();
            Check(orphans.Length > 0 && OnToolbar("Lost contact with OBS"), "OBS closing mid-recording: the chapters are still saved in its recording folder",
                  orphans.Length > 0 ? string.Join(" | ", File.ReadAllLines(orphans[^1])) : "no chapters file");
            Press("Lost contact with OBS");
        }
        finally
        {
            obs?.Dispose();
            FakePowerPoint.Revoke(cookie);
            try { File.Delete(FakeObs.ConfigPath); } catch (IOException) { }
            Thread.Sleep(900);
        }
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

        // the opacity slider dragged end to end: the settings file is written once it stops, not on every step
        // (each write was on the thread that runs the keyboard watcher)
        OpacityDragSavesOnce();

        // ⚙: the tablet link's lines, with the 16-digit PC check; no adb found (none on the PATH, and the one in
        // C:\platform-tools must not count)
        var padText = PadPanelText();
        Check(System.Text.RegularExpressions.Regex.IsMatch(padText, @"PC check [0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}\b"),
              "⚙: the PC check shown is 16 digits (XXXX-XXXX-XXXX-XXXX)", padText.Replace("\n", " | "));
        Check(padText.Contains("(not found)"), "⚙: adb only in C:\\platform-tools counts as not found", padText.Replace("\n", " | "));
        Check(padText.Contains("No shared Wi-Fi? Turn on Windows Mobile hotspot"), "⚙: the tablet link's lines point to the Mobile hotspot when there is no shared Wi-Fi", padText.Replace("\n", " | "));
        CheckPlantedAdbNotRun();

        // settings remembered: green pen chosen above; quit with ✕, start again, draw without choosing
        Press("Green (3)"); Press("Pen (P)"); Press("Draw on / off");   // drawing off before quitting
        Press("Quit Contrast Ink");
        bool quit = app.WaitForExit(5000);
        Check(quit, "✕ quits the app", quit ? "exited" : "still running after 5 s");
        if (!quit) return;
        File.Delete(statusPath);
        startInfo.Environment["PATH"] = PathAdbDir + Path.PathSeparator + startInfo.Environment["PATH"];   // now adb is on the PATH
        app = Process.Start(startInfo)!;
        var sw = Stopwatch.StartNew();
        while (!File.Exists(statusPath) && sw.Elapsed.TotalSeconds < 20) Thread.Sleep(200);
        Thread.Sleep(800);
        Check(File.Exists(statusPath), "it starts again after quitting", File.Exists(statusPath) ? "status written" : "no status");
        WaitFor(() => File.Exists(Path.Combine(PathAdbDir, AdbRan)), 8000);
        var pathRan = Path.Combine(PathAdbDir, AdbRan);
        Check(File.Exists(pathRan), "adb: an adb.exe on the PATH is used (asked for the tablets plugged in)", File.Exists(pathRan) ? File.ReadAllText(pathRan).Trim().Replace("\n", " | ") : "never run");
        padText = PadPanelText();
        Check(padText.Contains("(found)"), "⚙: adb on the PATH shows as found", padText.Replace("\n", " | "));
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
    /// <summary>The whole accessible name of the first toolbar element whose name starts so (visible ones only), or null.</summary>
    static string? ToolbarName(string nameStarts)
    {
        foreach (var hwnd in Native.ProcessWindows("Contrast Ink"))
        {
            var root = System.Windows.Automation.AutomationElement.FromHandle(hwnd);
            foreach (System.Windows.Automation.AutomationElement e in root.FindAll(System.Windows.Automation.TreeScope.Descendants, System.Windows.Automation.Condition.TrueCondition))
                if (e.Current.Name.StartsWith(nameStarts, StringComparison.Ordinal)) return e.Current.Name;
        }
        return null;
    }

    /// <summary>The on-screen rectangle of the first toolbar element whose name starts so, or empty.</summary>
    static Rectangle ToolbarBox(string nameStarts)
    {
        foreach (var hwnd in Native.ProcessWindows("Contrast Ink"))
        {
            var root = System.Windows.Automation.AutomationElement.FromHandle(hwnd);
            foreach (System.Windows.Automation.AutomationElement e in root.FindAll(System.Windows.Automation.TreeScope.Descendants, System.Windows.Automation.Condition.TrueCondition))
                if (e.Current.Name.StartsWith(nameStarts, StringComparison.Ordinal))
                {
                    var r = e.Current.BoundingRectangle;
                    return new Rectangle((int)r.Left, (int)r.Top, (int)r.Width, (int)r.Height);
                }
        }
        return Rectangle.Empty;
    }

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
    public static readonly Color BlockColor = Color.FromArgb(0x20, 0x50, 0xC0);
    readonly Panel block;
    public readonly Point BlockCenter;
    public void ShowBlock(bool on) { block.Visible = on; if (on) block.BringToFront(); Update(); }

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
        // the slide changing: a large block, above the rows the checks draw on, left of the stripe
        block = new Panel { BackColor = BlockColor, Visible = false,
            Bounds = new Rectangle((int)(screen.Width * 0.05), (int)(screen.Height * 0.05), (int)(screen.Width * 0.35), (int)(screen.Height * 0.22)) };
        BlockCenter = new Point(screen.Left + block.Left + block.Width / 2, screen.Top + block.Top + block.Height / 2);
        Controls.Add(block);
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
public class FakeView
{
    public int CurrentShowPosition { get; set; } = 1;
    /// <summary>Hidden slides: from position <see cref="HiddenFrom"/> on, PowerPoint's slide number is the position plus this.</summary>
    public int Hidden { get; set; }
    public int HiddenFrom { get; set; } = int.MaxValue;
    public FakeSlide Slide => new() { SlideNumber = CurrentShowPosition + (CurrentShowPosition >= HiddenFrom ? Hidden : 0) };
}
[ComVisible(true), ClassInterface(ClassInterfaceType.AutoDispatch)]
public class FakeSlide { public int SlideNumber { get; set; } }
[ComVisible(true), ClassInterface(ClassInterfaceType.AutoDispatch)]
public class FakePresentation { public string FullName => @"C:\Lectures\Cardiac MR.pptx"; }

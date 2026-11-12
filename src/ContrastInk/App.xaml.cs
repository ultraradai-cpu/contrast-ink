using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using ContrastInk.Core;

namespace ContrastInk;

/// <summary>
/// Contrast Ink: draw over PowerPoint (or anything) while OBS records the screen.
/// One transparent drawing layer on the chosen screen, one small toolbar that OBS doesn't record.
/// </summary>
public partial class App : Application
{
    static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ContrastInk");
    static readonly string SettingsPath = Path.Combine(Folder, "settings.json");

    Mutex? single;
    Settings settings = new();
    readonly ModeController mode = new();
    OverlayWindow overlay = null!;
    ToolbarWindow toolbar = null!;
    UndoButtonWindow undoButton = null!;
    SlideWatcher? slides;
    Recorder? recorder;
    bool tabletAsMouse;               // a pen tablet's pen is used like the mouse (decided at start)
    TabletMode tabletModeAtStart;     // the setting as it was then (a change takes effect on the next start)
    string? tabletFound;              // the tablets Windows reported, by name
    DateTime quitWarned;   // ✕ pressed while recording: a second press within 15 s quits
    InputHooks? hooks;
    PadServer? pad;   // a tablet used as a pad, when switched on (⚙ Settings)
    List<Native.Monitor> monitors = new();
    bool ctrl, shift, alt, win;
    readonly HashSet<int> swallowed = new();   // keys we kept from PowerPoint: their key-up is kept too


    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, ex) => { Log(ex.Exception); ex.Handled = true; };   // a bug must not end a lecture

        single = new Mutex(true, @"Local\ContrastInk.single", out bool first);
        if (!first) { MessageBox.Show("Contrast Ink is already running. Look for its toolbar at the top of the screen.", "Contrast Ink"); Shutdown(); return; }

        monitors = Native.Monitors();
        CarryOverOldSettings();
        settings = Settings.Load(SettingsPath, monitors.Count);
        // a pen tablet beside the keyboard (Wacom Intuos, XP-Pen Deco, Huion...): WPF's own pen handling is left out,
        // so its pen reaches every window as the mouse it moves (Core's PenTablet explains why). Decided once, before
        // the first window: WPF reads it only then.
        var (tablets, penScreens) = Native.PenDevices();
        tabletAsMouse = PenTablet.UseAsMouse(settings.PenTabletMode, tablets.Count, penScreens.Count);
        if (tabletAsMouse) AppContext.SetSwitch("Switch.System.Windows.Input.Stylus.DisableStylusAndTouchSupport", true);
        tabletModeAtStart = settings.PenTabletMode;
        tabletFound = tablets.Count > 0 ? string.Join(", ", tablets.Distinct()) : null;

        overlay = new OverlayWindow { ShiftHeld = () => shift };
        overlay.Show();
        Cover();

        toolbar = new ToolbarWindow();
        PlaceToolbar();
        toolbar.Show();
        KeepToolbarOnScreen();
        toolbar.SizeChanged += (_, _) => KeepToolbarOnScreen();   // made big again, or a warning line appeared
        toolbar.Moved += () => { settings.ToolbarX = toolbar.Left; settings.ToolbarY = toolbar.Top; settings.Save(SettingsPath); };

        // Everything after the toolbar appears. A failure here once left a toolbar with dead buttons and nothing said
        // (the global handler above swallowed it): now the toolbar says so in red, and the error goes to the log.
        try
        {
            undoButton = new UndoButtonWindow();
            ApplySettings();
            Wire();
            slides = new SlideWatcher(Dispatcher);
            recorder = new Recorder(toolbar, () => slides.Current, Dispatcher);
            toolbar.RecordClicked += recorder.RecordClicked;
            toolbar.PauseClicked += recorder.PauseClicked;
            slides.Changed += slide =>
            {
                if (settings.MarksPerSlide) { overlay.ShowPage(slide); undoButton.Park(); }
                recorder.SlideChanged(slide);
            };

            bool testRun = Environment.GetEnvironmentVariable("CONTRASTINK_TEST") == "1";
            hooks = new InputHooks { Key = OnKey, Pointer = OnPointer, AcceptInjectedKeys = testRun };
            if (!hooks.Working)   // on the toolbar, not a message box: a message box would be in the recording
                toolbar.Warn("Windows didn't allow Contrast Ink to watch the keyboard and pen: F9, Ctrl, the letter keys and pen drawing won't work. Use the toolbar buttons.");

            // a projector plugged in or out, or the resolution changed: cover the right screen again.
            // after sleep, Windows may have dropped the keyboard and mouse hooks without a word: put them back.
            Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (_, _) => Dispatcher.BeginInvoke(() => { monitors = Native.Monitors(); Cover(); hooks?.Reinstall(); Refresh(); });
            Microsoft.Win32.SystemEvents.PowerModeChanged += (_, ev) =>
            {
                if (ev.Mode == Microsoft.Win32.PowerModes.Resume) Dispatcher.BeginInvoke(() => { hooks?.Reinstall(); mode.Escape(); });
            };

            // the tablet link: switched on in ⚙ Settings; the Windows check starts it with a code it knows
            if (testRun && Environment.GetEnvironmentVariable("CONTRASTINK_TEST_PADCODE") is { Length: 6 } testCode) StartPad(testCode);
            else if (settings.TabletPad) StartPad();

            // PowerPoint's slide show likes to come to the front: stay above it
            // test runs: say what Windows answered, for the Windows check to read (never written in normal use)
            if (Environment.GetEnvironmentVariable("CONTRASTINK_STATUS") is { Length: > 0 } statusPath)
            {
                string json;
                try
                {
                    var o = Native.WindowRect(overlay); var t = Native.WindowRect(toolbar);
                    json = "{\"hiddenFromCapture\":" + (toolbar.HiddenFromCapture ? "true" : "false")
                         + ",\"hooksWorking\":" + (hooks.Working ? "true" : "false")
                         + ",\"windowsBuild\":" + Environment.OSVersion.Version.Build
                         + ",\"dpi\":" + Native.Dpi(overlay)
                         + ",\"overlay\":[" + o.Left + "," + o.Top + "," + o.Right + "," + o.Bottom + "]"
                         + ",\"toolbar\":[" + t.Left + "," + t.Top + "," + t.Right + "," + t.Bottom + "]"
                         + ",\"padPort\":" + (pad?.Port ?? 0) + "}";
                }
                catch (Exception ex) { json = "{\"error\":" + System.Text.Json.JsonSerializer.Serialize(ex.ToString()) + "}"; }
                try { File.WriteAllText(statusPath, json); } catch (Exception ex) { Log(ex); }
            }
            var top = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1500) };
            top.Tick += (_, _) => { overlay.KeepOnTop(); undoButton.KeepOnTop(); toolbar.KeepOnTop(); };
            top.Start();
            var rehook = new DispatcherTimer { Interval = TimeSpan.FromMinutes(2) };
            rehook.Tick += (_, _) => hooks?.Reinstall();
            rehook.Start();
            var penClock = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
            penClock.Tick += (_, _) =>
            {
                mode.Tick(DateTime.UtcNow);
                ReconcileModifiers();
                if (undoButton.Shown && !overlay.CanUndo) undoButton.Park();   // its mark faded away
            };
            penClock.Start();
        }
        catch (Exception ex)
        {
            Log(ex);
            toolbar.Warn("Contrast Ink did not start properly, so some buttons or keys may not work. Quit (✕) and start it again; if this stays, send %AppData%\\ContrastInk\\error.log.");
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        hooks?.Dispose();
        pad?.Dispose();
        settings.Save(SettingsPath);
        single?.Dispose();
        base.OnExit(e);
    }

    void Wire()
    {
        mode.Changed += on => { overlay.SetDrawing(on); if (!on) undoButton.Park(); Refresh(); };
        toolbar.DrawClicked += () => mode.Toggle();
        toolbar.ToolClicked += t => { settings.Tool = t; ApplySettings(); if (!mode.Drawing) mode.SetManual(true); };
        toolbar.ColorClicked += c => { settings.Color = c; if (settings.Tool == Tool.Eraser) settings.Tool = Tool.Pen; ApplySettings(); };
        toolbar.WidthClicked += w => { settings.Width = w; ApplySettings(); };
        toolbar.TabletModeChanged += m =>
        {
            settings.PenTabletMode = m;
            ApplySettings();
            toolbar.Notice(m == tabletModeAtStart ? null
                : "Close Contrast Ink (✕) and open it again: the pen tablet setting takes effect when it starts.");
        };
        toolbar.ShowTablet(tabletFound, tabletAsMouse);
        toolbar.OpacityChanged += o => { settings.Opacity = Math.Clamp(o, Settings.MinOpacity, 1); ApplySettings(); };
        toolbar.FadeClicked += () => { settings.FadingInk = !settings.FadingInk; ApplySettings(); };
        toolbar.UndoClicked += Undo;
        toolbar.ClearClicked += () => overlay.ClearAll();
        toolbar.OptionChanged += (name, on) =>
        {
            typeof(Settings).GetProperty(name)!.SetValue(settings, on);
            if (name == nameof(Settings.UndoButtonByPen) && !on) undoButton.Park();
            if (name == nameof(Settings.MarksPerSlide) && on && slides != null) overlay.ShowPage(slides.Current);
            if (name == nameof(Settings.TabletPad)) { if (on) StartPad(); else StopPad(); }

            ApplySettings();
        };
        undoButton.Clicked += Undo;
        overlay.UndoGesture += () => { if (settings.UndoWithRightClick) Undo(); };
        overlay.MarkStarting += () => undoButton.Park();   // never under the pen while drawing
        overlay.MarkDone += p =>
        {
            pad?.SendState(settings, overlay.CanUndo);   // the tablet's undo button follows marks made here too
            if (!settings.UndoButtonByPen || !mode.Drawing || monitors.Count == 0) return;
            undoButton.ShowAt(p.X + 12, p.Y + 12, monitors[settings.Screen].Bounds);
            toolbar.KeepOnTop();
        };
        toolbar.ScreenClicked += NextScreen;
        toolbar.FoldClicked += () => { settings.ToolbarCollapsed = !settings.ToolbarCollapsed; ApplySettings(); };
        toolbar.CloseClicked += () =>
        {
            // quitting mid-recording leaves OBS recording with no ⏹ in reach: say so once, quit on the second press
            if (recorder is { Active: true } && DateTime.UtcNow - quitWarned > TimeSpan.FromSeconds(15))
            {
                quitWarned = DateTime.UtcNow;
                toolbar.Notice("OBS is still recording. Press ⏹ first, or press ✕ again to quit Contrast Ink (OBS keeps recording).");
                return;
            }
            Shutdown();
        };
    }

    void ApplySettings()
    {
        overlay.SetTool(settings.Tool);
        overlay.SetColor((Color)ColorConverter.ConvertFromString(Settings.Colors[settings.Color]));
        overlay.SetWidth(Settings.Widths[settings.Width]);
        overlay.SetOpacity(settings.Opacity);
        overlay.FadingInk = settings.FadingInk;
        overlay.SetPenEraserEnd(settings.PenEraserEnd);
        settings.Save(SettingsPath);
        Refresh();
        pad?.SendState(settings, overlay.CanUndo);
    }

    // ---------- a tablet used as a pad ----------

    /// <summary>Listens for a tablet (switched on in ⚙ Settings, or by the Windows check with its own code).</summary>
    void StartPad(string? code = null)
    {
        if (pad != null) return;
        pad = new PadServer(Dispatcher, ScreenForPad, overlay.Snapshot, code);
        pad.CodeChanged += () => { ShowPad(); toolbar.Notice("Someone kept typing wrong tablet codes: there is a new code (⚙ Settings)."); };
        pad.Received += OnPad;
        pad.ConnectionChanged += name =>
        {
            overlay.RemoteCancel();
            if (name != null) pad?.SendState(settings, overlay.CanUndo);
            toolbar.Notice(name != null ? $"Tablet connected ({name}): what you draw on it appears here." : "The tablet disconnected.");
            ShowPad();
        };
        try { pad.Start(); }
        catch (Exception e)
        {
            Log(e);
            pad.Dispose(); pad = null;
            toolbar.Notice("The tablet link couldn't start: another program may be using its network port. Close Contrast Ink and open it again.");
        }
        ShowPad();
    }

    void StopPad() { pad?.Dispose(); pad = null; overlay.RemoteCancel(); ShowPad(); }

    /// <summary>The screen being drawn on, for the tablet link's threads: the list of screens is read once (the UI
    /// thread may replace it when a projector is plugged in).</summary>
    Native.RECT ScreenForPad()
    {
        var m = monitors;
        return m.Count == 0 ? default : m[Math.Clamp(settings.Screen, 0, m.Count - 1)].Bounds;
    }

    void ShowPad() => toolbar.ShowPad(pad == null ? null
        : pad.Connected != null ? $"Connected: {pad.Connected}."
        : $"On the tablet: Contrast Ink → Use as a pad → {Environment.MachineName}, code {pad.Code}."
          + (PadServer.Addresses() is { Count: > 0 } a ? $" Or type the address {a[0]}" + (pad.Port != Pad.Port ? $":{pad.Port}" : "") + "." : "")
          + " Windows may ask to let Contrast Ink use the network: allow it (lecture-hall Wi-Fi is often a \"public\" network: tick that too). Pictures of this screen go to the tablet over the Wi-Fi: with patient images, use a private network or your own hotspot.");

    void OnPad(byte type, byte[] payload)
    {
        switch (type)
        {
            case Pad.StrokeBegin when Pad.ReadBegin(payload) is { } b: overlay.RemoteBegin(b.x, b.y, b.eraserEnd); break;
            case Pad.StrokePoints: overlay.RemoteMove(Pad.ReadPoints(payload)); break;
            case Pad.StrokeEnd: overlay.RemoteEnd(); pad?.SendState(settings, overlay.CanUndo); break;
            case Pad.StrokeCancel: overlay.RemoteCancel(); break;
            case Pad.Hover when Pad.ReadHover(payload) is { } h: overlay.RemoteHover(h.x, h.y); break;
            case Pad.HoverEnd: overlay.RemoteHoverEnd(); break;
            case Pad.Command when Pad.ReadCommand(payload) is { } c: PadCommand(c); break;
        }
    }

    void PadCommand(PadCommand c)
    {
        switch (c.Action)
        {
            case PadAction.Undo: Undo(); pad?.SendState(settings, overlay.CanUndo); break;
            case PadAction.Clear: overlay.ClearAll(); pad?.SendState(settings, overlay.CanUndo); break;
            case PadAction.Next: Native.PressKey(Native.VK_RIGHT); break;      // the app in front turns the page
            case PadAction.Previous: Native.PressKey(Native.VK_LEFT); break;
            case PadAction.Fade: settings.FadingInk = c.Value == 1; ApplySettings(); break;
            case PadAction.Tool: SetTool((Tool)c.Value); break;
            case PadAction.Color: SetColor(c.Value); break;
            case PadAction.Width: settings.Width = c.Value; ApplySettings(); break;
            case PadAction.Opacity: settings.Opacity = c.Amount; ApplySettings(); break;
        }
    }

    void Undo()
    {
        overlay.Undo();
        pad?.SendState(settings, overlay.CanUndo);
        if (!overlay.CanUndo) undoButton.Park();
    }

    void Refresh() => toolbar.Refresh(mode.Drawing, settings, monitors.Count, settings.ToolbarCollapsed);

    // ---------- screens ----------
    void Cover()
    {
        if (monitors.Count == 0) return;
        settings.Screen = Math.Clamp(settings.Screen, 0, monitors.Count - 1);
        overlay.Cover(monitors[settings.Screen].Bounds);
        toolbar?.KeepOnTop();   // moving the layer puts it on top: the toolbar must be above it again at once
    }

    void NextScreen()
    {
        monitors = Native.Monitors();   // a projector may have been plugged in or out
        settings.Screen = monitors.Count == 0 ? 0 : (settings.Screen + 1) % monitors.Count;
        Cover();
        settings.Save(SettingsPath);
        Refresh();
    }

    void PlaceToolbar()
    {
        double x = settings.ToolbarX ?? double.NaN, y = settings.ToolbarY ?? double.NaN;
        bool visible = !double.IsNaN(x) && !double.IsNaN(y)
            && x > SystemParameters.VirtualScreenLeft - 50 && x < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 80
            && y > SystemParameters.VirtualScreenTop - 10 && y < SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 40;
        if (!visible)   // first start, or its screen was unplugged: top middle of the main screen
        {
            var area = SystemParameters.WorkArea;
            x = area.Left + area.Width / 2 - 330;
            y = area.Top + 8;
        }
        toolbar.Left = x;
        toolbar.Top = y;
    }

    /// <summary>
    /// The toolbar is about 870 points wide: on a 1024-wide projector screen it ran 27 px off the right edge,
    /// half hiding ✕ (seen in the Windows check's screenshots). Pull it back inside the screen it is ON, in real
    /// pixels (the first version used the main screen only and pulled a toolbar on the projector back to the laptop).
    /// </summary>
    void KeepToolbarOnScreen()
    {
        var r = Native.WindowRect(toolbar);
        if (r.Right <= r.Left) return;
        var areas = Native.Monitors().Select(m => new Box(m.Work.Left, m.Work.Top, m.Work.Right, m.Work.Bottom)).ToList();
        // too wide for its screen: the tools go onto two rows (this runs again when the size changes)
        int cx = (r.Left + r.Right) / 2, cy = (r.Top + r.Bottom) / 2;
        var screen = areas.FirstOrDefault(a => a.Contains(cx, cy));
        if (screen != default) toolbar.FitWidth(screen.Width);
        var (x, y) = Placement.KeepInside(new Box(r.Left, r.Top, r.Right, r.Bottom), areas);
        if (x != r.Left || y != r.Top) Native.MoveTo(toolbar, x, y);
    }

    /// <summary>
    /// Windows can swallow a key's release (Ctrl+Alt+Del, Win+L, a UAC prompt). Trusting only what the watcher saw
    /// would leave Ctrl "held" and drawing stuck on, catching every click meant for PowerPoint. Check the real keys.
    /// </summary>
    void ReconcileModifiers()
    {
        mode.CtrlActuallyDown(Native.IsDown(0x11));
        if (ctrl && !Native.IsDown(0x11)) ctrl = false;
        if (shift && !Native.IsDown(0x10)) shift = false;
        if (alt && !Native.IsDown(0x12)) alt = false;
        if (win && !Native.IsDown(0x5B) && !Native.IsDown(0x5C)) win = false;
        // a key we kept whose release Windows never showed us (the watcher dropped, or put back mid-press) would have
        // its NEXT release kept from PowerPoint, which then sees the key as still held: forget it once it is really up
        swallowed.RemoveWhere(vk => !Native.IsDown(vk));
    }

    // ---------- keyboard ----------
    bool OnKey(int vk, bool down)
    {
        switch (vk)
        {
            case 0x11 or 0xA2 or 0xA3:   // Ctrl: hold to draw (never kept from PowerPoint)
                ctrl = down;
                if (down) mode.CtrlDown(); else mode.CtrlUp();   // at once: the next key must already know
                return false;
            case 0x10 or 0xA0 or 0xA1: shift = down; return false;
            case 0x12 or 0xA4 or 0xA5: alt = down; return false;
            case 0x5B or 0x5C: win = down; return false;
        }
        if (!down) return swallowed.Remove(vk);
        bool keep = KeyDown(vk);
        if (keep) swallowed.Add(vk);
        return keep;
    }

    /// <summary>A key was pressed. True = it was ours (draw keys), so PowerPoint doesn't see it.</summary>
    bool KeyDown(int vk)
    {
        // which keys are ours is decided in one tested place (KeyPolicy); this only carries it out
        var (action, color) = KeyPolicy.Decide(vk, mode.Drawing, ctrl, alt || win, settings.UndoWithZ);
        if (ctrl && !alt && !win) mode.KeyWithCtrl(vk == KeyPolicy.VK_Z);   // Ctrl+C etc.: holding Ctrl was a shortcut, not drawing
        Action? act = action switch
        {
            KeyAction.Pass => null,
            KeyAction.ToggleDrawing => mode.Toggle,
            KeyAction.StopDrawing => mode.Escape,
            KeyAction.Undo => () => Later(Undo),
            KeyAction.Pen => () => Later(() => SetTool(Tool.Pen)),
            KeyAction.Highlighter => () => Later(() => SetTool(Tool.Highlighter)),
            KeyAction.Arrow => () => Later(() => SetTool(Tool.Arrow)),
            KeyAction.Oval => () => Later(() => SetTool(Tool.Oval)),
            KeyAction.Eraser => () => Later(() => SetTool(Tool.Eraser)),
            KeyAction.Laser => () => Later(() => SetTool(Tool.Laser)),
            KeyAction.Clear => () => Later(overlay.ClearAll),
            KeyAction.Fade => () => Later(() => { settings.FadingInk = !settings.FadingInk; ApplySettings(); }),
            KeyAction.Thinner => () => Later(() => { settings.Width = Math.Max(0, settings.Width - 1); ApplySettings(); }),
            KeyAction.Thicker => () => Later(() => { settings.Width = Math.Min(Settings.Widths.Length - 1, settings.Width + 1); ApplySettings(); }),
            KeyAction.Color => () => Later(() => SetColor(color)),
            _ => null,
        };
        if (act == null) return false;   // PowerPoint gets it
        act();   // mode changes at once (the next key must already know); the rest right after the hook returns
        return true;
    }

    void SetTool(Tool t) { settings.Tool = t; ApplySettings(); }
    void SetColor(int c) { settings.Color = c; if (settings.Tool == Tool.Eraser) settings.Tool = Tool.Pen; ApplySettings(); }

    // ---------- pen and mouse ----------
    void OnPointer(InputKind kind, int dx, int dy)
    {
        if (kind == InputKind.Pen && tabletAsMouse) kind = InputKind.Mouse;   // a pen tablet's pen is the mouse
        if (kind == InputKind.Pen) mode.PenSeen(DateTime.UtcNow);
        else if (kind == InputKind.Mouse && (dx != 0 || dy != 0)) mode.MouseMoved(dx, dy);
        // a finger (touch) clicks, it never switches drawing on
    }

    /// <summary>Do it right after the hook returns: the hook must answer Windows quickly.</summary>
    void Later(Action a) => Dispatcher.BeginInvoke(a, DispatcherPriority.Send);

    /// <summary>The app was called Lecture Ink before: bring its settings across once, so colours and places stay.</summary>
    static void CarryOverOldSettings()
    {
        try
        {
            var old = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Lecture" + "Ink", "settings.json");
            if (!File.Exists(SettingsPath) && File.Exists(old))
            {
                Directory.CreateDirectory(Folder);
                File.Copy(old, SettingsPath);
            }
        }
        catch (IOException e) { Log(e); }
        catch (UnauthorizedAccessException e) { Log(e); }
    }

    public static void Log(Exception e)
    {
        try
        {
            Directory.CreateDirectory(Folder);
            File.AppendAllText(Path.Combine(Folder, "error.log"), $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {e}\n\n");
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

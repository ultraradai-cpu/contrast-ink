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
    // the screen the layer is on now: the presenter's choice (settings), or the main screen while that one is unplugged
    int screen;
    volatile Native.Monitor? padScreen;   // the same, for the tablet link's threads
    bool ctrl, shift, alt, win;
    bool hooksWarned;          // the toolbar says the keyboard watcher couldn't be put back
    bool frontWarned;          // the toolbar says the app in front runs as administrator
    DispatcherTimer saveTimer = null!;
    readonly object saving = new();
    long saveAsked, saveWritten;   // the newest settings asked to be written, and the newest written
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
        saveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        saveTimer.Tick += (_, _) => { saveTimer.Stop(); SaveNow(); };
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
        toolbar.Moved += () => { settings.ToolbarX = toolbar.Left; settings.ToolbarY = toolbar.Top; SaveSoon(); };

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
            if (!hooks.Working) { toolbar.Warn(HooksWarning); hooksWarned = true; }   // on the toolbar, not a message box: a message box would be in the recording

            // a projector plugged in or out, or the resolution changed: cover the chosen screen again (or the main
            // screen while the chosen one is gone; back on the chosen one when it returns).
            // after sleep, Windows may have dropped the keyboard and mouse hooks without a word: put them back.
            Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (_, _) => Dispatcher.BeginInvoke(() => { monitors = Native.Monitors(); Cover(); Rehook(); Refresh(); });
            Microsoft.Win32.SystemEvents.PowerModeChanged += (_, ev) =>
            {
                if (ev.Mode == Microsoft.Win32.PowerModes.Resume) Dispatcher.BeginInvoke(() => { Rehook(); mode.Escape(); });
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
            top.Tick += (_, _) => { overlay.KeepOnTop(); undoButton.KeepOnTop(); toolbar.KeepOnTop(); CheckFront(); };
            top.Start();
            var rehook = new DispatcherTimer { Interval = TimeSpan.FromMinutes(2) };
            rehook.Tick += (_, _) => Rehook();
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
        // (not when this was a second copy that found one already running: it never read the settings)
        if (saveTimer != null) { saveTimer.Stop(); SaveNow(wait: true); }
        single?.Dispose();
        base.OnExit(e);
    }

    // ---------- saving the settings ----------
    // Not on every change: the opacity slider changes the settings on every pixel it moves, and this thread also runs
    // the keyboard watcher, which Windows drops if it stalls. Half a second after the last change, written on a
    // worker thread (whole or not at all: Settings.Write).

    void SaveSoon() { saveTimer.Stop(); saveTimer.Start(); }

    void SaveNow(bool wait = false)
    {
        var json = settings.Serialize();
        if (json == null) return;
        long n = ++saveAsked;
        void Write()
        {
            lock (saving)
            {
                if (n <= saveWritten) return;   // a newer one was written already
                if (Settings.Write(SettingsPath, json)) saveWritten = n;
            }
        }
        if (wait) Write();
        else System.Threading.Tasks.Task.Run(Write);
    }

    // ---------- the keyboard watcher, and an app in front that runs as administrator ----------
    const string HooksWarning = "Windows didn't allow Contrast Ink to watch the keyboard and pen: F9, Ctrl, the letter keys and pen drawing won't work. Use the toolbar buttons.";
    const string FrontElevated = "The app in front runs as administrator: Contrast Ink's keys and the tablet's ‹ › can't reach it. Open it normally, or start Contrast Ink as administrator too.";

    /// <summary>Puts the keyboard and mouse watcher back; when Windows refuses, the toolbar says so (and stops saying so once it works again).</summary>
    void Rehook()
    {
        if (hooks == null) return;
        bool ok = hooks.Reinstall();
        if (!ok && !hooksWarned) toolbar.Warn(HooksWarning);
        else if (ok && hooksWarned) toolbar.Unwarn(HooksWarning);
        hooksWarned = !ok;
    }

    /// <summary>Every 1.5 s: says on the toolbar while the app in front runs as administrator (Windows keeps
    /// Contrast Ink's keys from it, and its keys from Contrast Ink's watcher, without a word).</summary>
    void CheckFront()
    {
        bool blocked = Native.ForegroundElevated();
        if (blocked && !frontWarned) toolbar.Notice(FrontElevated);
        else if (!blocked && frontWarned) toolbar.ClearNotice(FrontElevated);
        frontWarned = blocked;
    }

    /// <summary>The tablet's ‹ ›: the key for the app in front, or why it can't get there.</summary>
    void PressForTablet(ushort vk)
    {
        if (!Native.PressKey(vk) || Native.ForegroundElevated()) { toolbar.Notice(FrontElevated); frontWarned = true; }
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
            undoButton.ShowAt(p.X + 12, p.Y + 12, monitors[Math.Min(screen, monitors.Count - 1)].Bounds);
            toolbar.KeepOnTop();
        };
        toolbar.ScreenClicked += NextScreen;
        toolbar.AskAnswered += allow => pad?.Answer(allow);
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
        SaveSoon();
        Refresh();
        pad?.SendState(settings, overlay.CanUndo);
    }

    // ---------- a tablet used as a pad ----------

    /// <summary>Listens for a tablet (switched on in ⚙ Settings, or by the Windows check with its own code).</summary>
    void StartPad(string? code = null)
    {
        if (pad != null) return;
        pad = new PadServer(Dispatcher, ScreenForPad, overlay.Snapshot, PadIdentity.Load(), code, usbDoorAlways: code != null);   // code: only the Windows check
        pad.CodeChanged += () => { ShowPad(); toolbar.Notice("Someone kept typing wrong tablet codes: there is a new code (⚙ Settings)."); };
        pad.Received += OnPad;
        pad.ConnectionChanged += name =>
        {
            overlay.RemoteCancel();
            if (name != null) pad?.SendState(settings, overlay.CanUndo);
            toolbar.Notice(name != null ? $"Tablet connected ({name}): what you draw on it appears here." : "The tablet disconnected.");
            ShowPad();
        };
        pad.UsbToolsChanged += ShowPad;
        pad.CableAsk += toolbar.Ask;   // the Android cable door: the presenter allows the first tablet there in each run
        try { pad.Start(); }
        catch (Exception e)
        {
            Log(e);
            pad.Dispose(); pad = null;
            toolbar.Notice("The tablet link couldn't start: another program may be using its network port. Close Contrast Ink and open it again.");
        }
        ShowPad();
    }

    void StopPad() { pad?.Dispose(); pad = null; overlay.RemoteCancel(); toolbar.Ask(null); ShowPad(); }

    /// <summary>The screen being drawn on, for the tablet link's threads (set by the UI thread when it changes).</summary>
    Native.RECT ScreenForPad() => padScreen?.Bounds ?? default;

    /// <summary>Four short lines (a long text here once made ⚙ Settings tall enough to cover the slide); the
    /// details are in the README, and in the hint shown while the pointer rests on them. Whether adb is found is
    /// what the tablet link last saw (looking at the disk here, on every change, held up the keyboard watcher).</summary>
    void ShowPad() => toolbar.ShowPad(pad == null ? null
        : pad.Connected != null ? $"Connected: {pad.Connected}" + (pad.OverUsb ? ", by the USB cable." : ", over Wi-Fi (plug in its cable to switch).")
        : $"Code {pad.Code}  ·  PC check {pad.PcCheck}"
          + (PadServer.Addresses() is { Count: > 0 } a ? "  ·  " + Pad.AddressText(a, pad.Port) : "")
          + $"\nOn the tablet: Use as a pad → {Environment.MachineName} → the code. Encrypted."
          + "\nNo shared Wi-Fi? Turn on Windows Mobile hotspot (Settings → Network & internet) and join it from the tablet, or use the USB cable."
          + "\nUSB: iPad needs iTunes; Android needs USB debugging and platform-tools"
          + (Adb.Found != null ? " (found)." : " (not found)."));

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
            case PadAction.Next: PressForTablet(Native.VK_RIGHT); break;      // the app in front turns the page
            case PadAction.Previous: PressForTablet(Native.VK_LEFT); break;
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

    void Refresh() => toolbar.Refresh(mode.Drawing, settings, monitors.Count, screen, settings.ToolbarCollapsed);

    // ---------- screens ----------
    /// <summary>
    /// Covers the presenter's chosen screen, found by its name and place (Core's ScreenChoice): while it is unplugged,
    /// the main screen, and the chosen one again when it comes back. The fallback is never saved as the choice (a
    /// projector dropping out for a moment once moved the layer to the laptop for good).
    /// </summary>
    void Cover()
    {
        if (monitors.Count == 0) return;
        var b = settings.ScreenBounds;
        screen = ScreenChoice.Resolve(monitors.Select(m => m.Display).ToList(), settings.ScreenDevice,
            b is { Length: 4 } ? new Box(b[0], b[1], b[2], b[3]) : null, settings.Screen);
        padScreen = monitors[screen];
        overlay.Cover(monitors[screen].Bounds);
        toolbar?.KeepOnTop();   // moving the layer puts it on top: the toolbar must be above it again at once
    }

    /// <summary>🖥 pressed: the next screen becomes the presenter's choice, remembered by its name and place.</summary>
    void NextScreen()
    {
        monitors = Native.Monitors();   // a projector may have been plugged in or out
        if (monitors.Count == 0) return;
        var next = monitors[(screen + 1) % monitors.Count];
        settings.Screen = (screen + 1) % monitors.Count;
        settings.ScreenDevice = next.Device;
        settings.ScreenBounds = new[] { next.Bounds.Left, next.Bounds.Top, next.Bounds.Right, next.Bounds.Bottom };
        Cover();
        SaveSoon();
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

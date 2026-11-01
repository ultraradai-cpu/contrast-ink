using System;
using System.Collections.Generic;
using System.IO;
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
    InputHooks? hooks;
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

        overlay = new OverlayWindow { ShiftHeld = () => shift };
        overlay.Show();
        Cover();

        toolbar = new ToolbarWindow();
        PlaceToolbar();
        toolbar.Show();
        toolbar.Moved += () => { settings.ToolbarX = toolbar.Left; settings.ToolbarY = toolbar.Top; settings.Save(SettingsPath); };

        ApplySettings();
        Wire();

        hooks = new InputHooks { Key = OnKey, Pointer = OnPointer };
        if (!hooks.Working)   // on the toolbar, not a message box: a message box would be in the recording
            toolbar.Warn("Windows didn't allow Contrast Ink to watch the keyboard and pen: F9, Ctrl, the letter keys and pen drawing won't work. Use the toolbar buttons.");

        // a projector plugged in or out, or the resolution changed: cover the right screen again.
        // after sleep, Windows may have dropped the keyboard and mouse hooks without a word: put them back.
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (_, _) => Dispatcher.BeginInvoke(() => { monitors = Native.Monitors(); Cover(); hooks?.Reinstall(); Refresh(); });
        Microsoft.Win32.SystemEvents.PowerModeChanged += (_, ev) =>
        {
            if (ev.Mode == Microsoft.Win32.PowerModes.Resume) Dispatcher.BeginInvoke(() => { hooks?.Reinstall(); mode.Escape(); });
        };

        // PowerPoint's slide show likes to come to the front: stay above it
        var top = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1500) };
        top.Tick += (_, _) => { overlay.KeepOnTop(); toolbar.KeepOnTop(); };
        top.Start();
        var rehook = new DispatcherTimer { Interval = TimeSpan.FromMinutes(2) };
        rehook.Tick += (_, _) => hooks?.Reinstall();
        rehook.Start();
        var penClock = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        penClock.Tick += (_, _) => mode.Tick(DateTime.UtcNow);
        penClock.Start();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        hooks?.Dispose();
        settings.Save(SettingsPath);
        single?.Dispose();
        base.OnExit(e);
    }

    void Wire()
    {
        mode.Changed += on => { overlay.SetDrawing(on); Refresh(); };
        toolbar.DrawClicked += () => mode.Toggle();
        toolbar.ToolClicked += t => { settings.Tool = t; ApplySettings(); if (!mode.Drawing) mode.SetManual(true); };
        toolbar.ColorClicked += c => { settings.Color = c; if (settings.Tool == Tool.Eraser) settings.Tool = Tool.Pen; ApplySettings(); };
        toolbar.WidthClicked += w => { settings.Width = w; ApplySettings(); };
        toolbar.FadeClicked += () => { settings.FadingInk = !settings.FadingInk; ApplySettings(); };
        toolbar.UndoClicked += () => overlay.Undo();
        toolbar.ClearClicked += () => overlay.ClearAll();
        toolbar.ScreenClicked += NextScreen;
        toolbar.FoldClicked += () => { settings.ToolbarCollapsed = !settings.ToolbarCollapsed; ApplySettings(); };
        toolbar.CloseClicked += () => Shutdown();
    }

    void ApplySettings()
    {
        overlay.SetTool(settings.Tool);
        overlay.SetColor((Color)ColorConverter.ConvertFromString(Settings.Colors[settings.Color]));
        overlay.SetWidth(Settings.Widths[settings.Width]);
        overlay.FadingInk = settings.FadingInk;
        settings.Save(SettingsPath);
        Refresh();
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
        double x = settings.ToolbarX, y = settings.ToolbarY;
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
        var (action, color) = KeyPolicy.Decide(vk, mode.Drawing, ctrl, alt || win);
        if (ctrl && !alt && !win) mode.KeyWithCtrl(vk == KeyPolicy.VK_Z);   // Ctrl+C etc.: holding Ctrl was a shortcut, not drawing
        Action? act = action switch
        {
            KeyAction.Pass => null,
            KeyAction.ToggleDrawing => mode.Toggle,
            KeyAction.StopDrawing => mode.Escape,
            KeyAction.Undo => () => Later(overlay.Undo),
            KeyAction.Pen => () => Later(() => SetTool(Tool.Pen)),
            KeyAction.Highlighter => () => Later(() => SetTool(Tool.Highlighter)),
            KeyAction.Arrow => () => Later(() => SetTool(Tool.Arrow)),
            KeyAction.Oval => () => Later(() => SetTool(Tool.Oval)),
            KeyAction.Eraser => () => Later(() => SetTool(Tool.Eraser)),
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

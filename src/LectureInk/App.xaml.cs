using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using LectureInk.Core;

namespace LectureInk;

/// <summary>
/// Lecture Ink: draw over PowerPoint (or anything) while OBS records the screen.
/// One transparent drawing layer on the chosen screen, one small toolbar that OBS doesn't record.
/// </summary>
public partial class App : Application
{
    static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "LectureInk");
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

    const int VK_ESC = 0x1B, VK_F9 = 0x78, VK_Z = 0x5A;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, ex) => { Log(ex.Exception); ex.Handled = true; };   // a bug must not end a lecture

        single = new Mutex(true, @"Local\LectureInk.single", out bool first);
        if (!first) { MessageBox.Show("Lecture Ink is already running. Look for its toolbar at the top of the screen.", "Lecture Ink"); Shutdown(); return; }

        monitors = Native.Monitors();
        settings = Settings.Load(SettingsPath, monitors.Count);

        overlay = new OverlayWindow { ShiftHeld = () => shift };
        overlay.Show();
        Cover();

        toolbar = new ToolbarWindow();
        PlaceToolbar();
        toolbar.Show();
        toolbar.LocationChanged += (_, _) => { settings.ToolbarX = toolbar.Left; settings.ToolbarY = toolbar.Top; settings.Save(SettingsPath); };

        ApplySettings();
        Wire();

        hooks = new InputHooks { Key = OnKey, Pointer = OnPointer };
        if (!hooks.Working)
            MessageBox.Show("Windows didn't allow Lecture Ink to watch the keyboard, so F9, Ctrl and the letter keys won't work. Use the toolbar buttons.", "Lecture Ink");

        // PowerPoint's slide show likes to come to the front: stay above it
        var top = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1500) };
        top.Tick += (_, _) => { overlay.KeepOnTop(); toolbar.KeepOnTop(); };
        top.Start();
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
        if (alt || win) return false;
        if (vk == VK_F9) { mode.Toggle(); return true; }
        if (ctrl)
        {
            bool undo = vk == VK_Z, mine = undo && mode.Drawing;
            mode.KeyWithCtrl(undo);
            if (mine) Later(overlay.Undo);
            return mine;
        }
        // letter keys are ours only while drawing; otherwise PowerPoint gets them
        if (!mode.Drawing) return false;
        Action? act = vk switch
        {
            VK_ESC => null,
            0x50 => () => SetTool(Tool.Pen),          // P
            0x48 => () => SetTool(Tool.Highlighter),  // H
            0x41 => () => SetTool(Tool.Arrow),        // A
            0x4F => () => SetTool(Tool.Oval),         // O
            0x45 => () => SetTool(Tool.Eraser),       // E
            0x43 => overlay.ClearAll,                 // C
            0x46 => () => { settings.FadingInk = !settings.FadingInk; ApplySettings(); },   // F
            >= 0x31 and <= 0x35 => () => SetColor(vk - 0x31),   // 1-5
            >= 0x61 and <= 0x65 => () => SetColor(vk - 0x61),   // number pad 1-5
            _ => null,
        };
        if (vk == VK_ESC) { mode.Escape(); return true; }
        if (act == null) return false;   // arrows, Page Down, Space... still change slides while drawing
        Later(act);
        return true;
    }

    void SetTool(Tool t) { settings.Tool = t; ApplySettings(); }
    void SetColor(int c) { settings.Color = c; if (settings.Tool == Tool.Eraser) settings.Tool = Tool.Pen; ApplySettings(); }

    // ---------- pen and mouse ----------
    void OnPointer(InputKind kind, int dx, int dy)
    {
        if (kind == InputKind.Pen) mode.PenSeen();
        else if (kind == InputKind.Mouse && (dx != 0 || dy != 0)) mode.MouseMoved(dx, dy);
        // a finger (touch) clicks, it never switches drawing on
    }

    /// <summary>Do it right after the hook returns: the hook must answer Windows quickly.</summary>
    void Later(Action a) => Dispatcher.BeginInvoke(a, DispatcherPriority.Send);

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

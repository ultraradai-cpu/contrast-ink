using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;

namespace ContrastInk;

/// <summary>
/// A small undo button that appears beside the last mark, so undo is where the pen already is.
/// Hidden from screen recordings exactly like the toolbar; on a Windows that can't hide it, it never appears.
/// </summary>
sealed class UndoButtonWindow : Window
{
    IntPtr hwnd;
    const int WM_GETMINMAXINFO = 0x24;
    public event Action? Clicked;
    /// <summary>True when Windows hides it from recordings. False: it is never shown (it would be recorded).</summary>
    public bool HiddenFromCapture { get; private set; }
    bool mayShow;

    public UndoButtonWindow()
    {
        Title = "Contrast Ink undo button";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        Width = Height = 36;
        // the whole window is the button: one solid Contrast blue square with the undo arrow
        Background = new SolidColorBrush(Color.FromRgb(0x25, 0x63, 0xEB));
        Cursor = System.Windows.Input.Cursors.Hand;
        Content = new TextBlock { Text = "↶", FontSize = 20, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        System.Windows.Automation.AutomationProperties.SetName(this, "Undo the last mark");
        MouseLeftButtonUp += (_, _) => Clicked?.Invoke();
        SourceInitialized += (_, _) =>
        {
            hwnd = new WindowInteropHelper(this).Handle;
            HwndSource.FromHwnd(hwnd)!.AddHook((IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) =>
            {
                if (msg == Native.WM_MOUSEACTIVATE) { handled = true; return new IntPtr(Native.MA_NOACTIVATE); }   // keyboard stays with PowerPoint
                // Windows' smallest window is about 136 px wide (seen in the Windows check): this one may be 36
                if (msg == WM_GETMINMAXINFO) { Marshal.WriteInt32(l, 24, 1); Marshal.WriteInt32(l, 28, 1); }   // MINMAXINFO.ptMinTrackSize
                return IntPtr.Zero;
            });
            Native.RoundCorners(hwnd);
            // CONTRASTINK_TEST_NOHIDE: the test's control run, which must SEE it in a capture
            bool controlRun = Environment.GetEnvironmentVariable("CONTRASTINK_TEST_NOHIDE") == "1";
            HiddenFromCapture = !controlRun && Native.HideFromCapture(hwnd);
            mayShow = HiddenFromCapture || controlRun;   // the control run shows it unhidden, to prove a capture WOULD see it
            if (!Native.SetExStyle(hwnd, Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE, 0))
                App.Log(new InvalidOperationException("undo button: no-activate style was not applied"));
        };
        new WindowInteropHelper(this).EnsureHandle();   // made now: whether it can be hidden is known before it is ever needed
        // Shown once, now, off every screen, and from then on only moved on and off. Showing it fresh at each mark
        // sometimes left it visible but unpainted (the Windows check's control run caught an empty square 2 times in 6).
        if (mayShow) { Left = Top = Parked; Show(); }
    }

    const int Parked = -20000;
    /// <summary>On a screen beside a mark right now.</summary>
    public bool Shown { get; private set; }

    /// <summary>Off the screens (the window stays open, so it is painted and ready).</summary>
    public void Park()
    {
        if (!Shown) return;
        Shown = false;
        if (hwnd != IntPtr.Zero) Native.SetWindowPos(hwnd, IntPtr.Zero, Parked, Parked, 0, 0, Native.SWP_NOSIZE | Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
    }

    /// <summary>Shows the button with its top-left corner at (x, y) in screen pixels, kept inside that screen.</summary>
    public void ShowAt(int x, int y, Native.RECT screen)
    {
        if (!mayShow || hwnd == IntPtr.Zero) return;
        var r = Native.WindowRect(this);
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        x = Math.Clamp(x, screen.Left, screen.Right - w);
        y = Math.Clamp(y, screen.Top, screen.Bottom - h);
        Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, x, y, 0, 0, Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        Shown = true;
    }

    public void KeepOnTop()
    {
        if (hwnd != IntPtr.Zero && Shown) Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
    }
}

using System;
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
        SizeToContent = SizeToContent.WidthAndHeight;
        Background = new SolidColorBrush(Color.FromRgb(0x14, 0x1A, 0x22));
        var button = new Button
        {
            Content = "↶",
            Width = 36, Height = 36, FontSize = 20, Focusable = false, Cursor = System.Windows.Input.Cursors.Hand,
            Foreground = Brushes.White, Background = new SolidColorBrush(Color.FromRgb(0x25, 0x63, 0xEB)), BorderThickness = new Thickness(0),
        };
        System.Windows.Automation.AutomationProperties.SetName(button, "Undo the last mark");
        button.Click += (_, _) => Clicked?.Invoke();
        Content = button;
        SourceInitialized += (_, _) =>
        {
            hwnd = new WindowInteropHelper(this).Handle;
            HwndSource.FromHwnd(hwnd)!.AddHook((IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) =>
            {
                if (msg == Native.WM_MOUSEACTIVATE) { handled = true; return new IntPtr(Native.MA_NOACTIVATE); }   // keyboard stays with PowerPoint
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
        new WindowInteropHelper(this).EnsureHandle();   // made now (not shown): whether it can be hidden is known before it is ever needed
    }

    /// <summary>Shows the button with its top-left corner at (x, y) in screen pixels, kept inside that screen.</summary>
    public void ShowAt(int x, int y, Native.RECT screen)
    {
        if (!mayShow) return;
        Show();
        var r = Native.WindowRect(this);
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        x = Math.Clamp(x, screen.Left, screen.Right - w);
        y = Math.Clamp(y, screen.Top, screen.Bottom - h);
        Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, x, y, 0, 0, Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
    }

    public void KeepOnTop()
    {
        if (hwnd != IntPtr.Zero && IsVisible) Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
    }
}

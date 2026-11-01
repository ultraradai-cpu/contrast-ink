using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using LectureInk.Core;

namespace LectureInk;

public partial class ToolbarWindow : Window
{
    static readonly Brush On = new SolidColorBrush(Color.FromRgb(0xD8, 0xB7, 0x6E));
    static readonly Brush OnText = new SolidColorBrush(Color.FromRgb(0x2A, 0x14, 0x08));
    static readonly Brush OffText = new SolidColorBrush(Color.FromRgb(0xF6, 0xEB, 0xDD));

    IntPtr hwnd;
    readonly List<Button> colorButtons = new(), widthButtons = new();

    /// <summary>True when Windows hides the toolbar from screen recordings (Windows 10 2004 or newer).</summary>
    public bool HiddenFromCapture { get; private set; }

    public event Action? DrawClicked, UndoClicked, ClearClicked, FadeClicked, ScreenClicked, FoldClicked, CloseClicked, Moved;
    public event Action<Tool>? ToolClicked;
    public event Action<int>? ColorClicked, WidthClicked;

    public ToolbarWindow()
    {
        InitializeComponent();
        for (int i = 0; i < Settings.Colors.Length; i++)
        {
            int n = i;
            var dot = new Ellipse { Width = 18, Height = 18, Fill = (Brush)new BrushConverter().ConvertFromString(Settings.Colors[i])!, Stroke = Brushes.Black, StrokeThickness = 0.5 };
            var b = new Button { Style = (Style)Resources["Tb"], Width = 30, Content = dot, ToolTip = $"{Settings.ColorNames[i]} ({i + 1})", BorderBrush = On };
            if (Settings.ColorNames[i] == "Black") dot.Stroke = OffText;   // visible on the dark bar
            b.Click += (_, _) => ColorClicked?.Invoke(n);
            colorButtons.Add(b);
            ColorPanel.Children.Add(b);
        }
        for (int i = 0; i < Settings.Widths.Length; i++)
        {
            int n = i;
            // the dot takes the button's text colour, so it stays visible when the button turns gold
            var line = new Ellipse { Width = Settings.Widths[i] + 2, Height = Settings.Widths[i] + 2 };
            line.SetBinding(Shape.FillProperty, new System.Windows.Data.Binding("Foreground") { RelativeSource = new System.Windows.Data.RelativeSource(System.Windows.Data.RelativeSourceMode.FindAncestor, typeof(Button), 1) });
            var b = new Button { Style = (Style)Resources["Tb"], Width = 28, Content = line, ToolTip = $"{Settings.WidthNames[i]} ([ thinner, ] thicker)" };
            b.Click += (_, _) => WidthClicked?.Invoke(n);
            widthButtons.Add(b);
            WidthPanel.Children.Add(b);
        }
        DrawBtn.Click += (_, _) => DrawClicked?.Invoke();
        PenBtn.Click += (_, _) => ToolClicked?.Invoke(Tool.Pen);
        HighBtn.Click += (_, _) => ToolClicked?.Invoke(Tool.Highlighter);
        ArrowBtn.Click += (_, _) => ToolClicked?.Invoke(Tool.Arrow);
        OvalBtn.Click += (_, _) => ToolClicked?.Invoke(Tool.Oval);
        EraseBtn.Click += (_, _) => ToolClicked?.Invoke(Tool.Eraser);
        UndoBtn.Click += (_, _) => UndoClicked?.Invoke();
        ClearBtn.Click += (_, _) => ClearClicked?.Invoke();
        FadeBtn.Click += (_, _) => FadeClicked?.Invoke();
        ScreenBtn.Click += (_, _) => ScreenClicked?.Invoke();
        FoldBtn.Click += (_, _) => FoldClicked?.Invoke();
        CloseBtn.Click += (_, _) => CloseClicked?.Invoke();
        // DragMove returns when the mouse is let go: save the place once, not on every pixel
        Grip.MouseLeftButtonDown += (_, e) => { if (e.ButtonState == MouseButtonState.Pressed) { DragMove(); Moved?.Invoke(); } };

        HintsInside(this);

        SourceInitialized += (_, _) =>
        {
            hwnd = new WindowInteropHelper(this).Handle;
            Native.SetExStyle(hwnd, Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE, 0);
            HwndSource.FromHwnd(hwnd)!.AddHook((IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) =>
            {
                // tapping a toolbar button leaves the keyboard with PowerPoint
                if (msg == Native.WM_MOUSEACTIVATE) { handled = true; return new IntPtr(Native.MA_NOACTIVATE); }
                return IntPtr.Zero;
            });
            Native.RoundCorners(hwnd);
            HiddenFromCapture = Native.SetWindowDisplayAffinity(hwnd, Native.WDA_EXCLUDEFROMCAPTURE);
            if (!HiddenFromCapture)
            {
                // say so where it can't be missed: the handle turns red
                GripText.Foreground = Brushes.Red;
                Grip.ToolTip = "Windows did not hide this toolbar from recordings (needs Windows 10 version 2004 or newer). It will show in OBS: make it small (‹) or move it to a corner.";
            }
        };
    }

    /// <summary>Every ToolTip becomes a hint line inside the toolbar; no tooltip window ever opens.</summary>
    void HintsInside(DependencyObject root)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root))
        {
            if (child is not FrameworkElement fe) continue;
            if (fe.ToolTip is string text)
            {
                ToolTipService.SetIsEnabled(fe, false);
                fe.MouseEnter += (_, _) => { Hint.Text = fe.ToolTip as string ?? text; Hint.Visibility = Visibility.Visible; };
                fe.MouseLeave += (_, _) => Hint.Visibility = Visibility.Collapsed;
            }
            HintsInside(fe);
        }
    }

    public void KeepOnTop()
    {
        if (hwnd != IntPtr.Zero) Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
    }

    static void Mark(Button b, bool on)
    {
        b.Background = on ? On : Brushes.Transparent;
        b.Foreground = on ? OnText : OffText;
    }

    /// <summary>Shows the current state: which tool, colour, width, and whether drawing is on.</summary>
    public void Refresh(bool drawing, Settings s, int screens, bool folded)
    {
        Mark(DrawBtn, drawing);
        DrawText.Text = drawing ? " On" : " Off";
        Mark(PenBtn, s.Tool == Tool.Pen);
        Mark(HighBtn, s.Tool == Tool.Highlighter);
        Mark(ArrowBtn, s.Tool == Tool.Arrow);
        Mark(OvalBtn, s.Tool == Tool.Oval);
        Mark(EraseBtn, s.Tool == Tool.Eraser);
        Mark(FadeBtn, s.FadingInk);
        for (int i = 0; i < colorButtons.Count; i++) colorButtons[i].BorderThickness = new Thickness(i == s.Color ? 2 : 0);
        for (int i = 0; i < widthButtons.Count; i++) Mark(widthButtons[i], i == s.Width);
        ScreenBtn.Visibility = screens > 1 ? Visibility.Visible : Visibility.Collapsed;
        ScreenText.Text = (s.Screen + 1).ToString();
        Full.Visibility = folded ? Visibility.Collapsed : Visibility.Visible;
        FoldBtn.Content = folded ? "›" : "‹";
    }
}

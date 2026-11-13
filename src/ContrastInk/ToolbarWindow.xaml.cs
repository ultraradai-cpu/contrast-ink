using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using ContrastInk.Core;

namespace ContrastInk;

public partial class ToolbarWindow : Window
{
    // Contrast: logo blue #2563EB with white text when on (5.2:1), light grey #E3E8F0 on dark ink #141A22 when off
    static readonly Brush On = new SolidColorBrush(Color.FromRgb(0x25, 0x63, 0xEB));
    static readonly Brush OnText = Brushes.White;
    static readonly Brush OffText = new SolidColorBrush(Color.FromRgb(0xE3, 0xE8, 0xF0));

    IntPtr hwnd;
    readonly List<Button> colorButtons = new(), widthButtons = new();

    /// <summary>True when Windows hides the toolbar from screen recordings (Windows 10 2004 or newer).</summary>
    public bool HiddenFromCapture { get; private set; }

    /// <summary>A setting was ticked or unticked: (which, on). Names are the Settings property names.</summary>
    public event Action<string, bool>? OptionChanged;
    bool refreshing;

    public event Action? RecordClicked, PauseClicked;
    public event Action? DrawClicked, UndoClicked, ClearClicked, FadeClicked, ScreenClicked, FoldClicked, CloseClicked, Moved;
    public event Action<Tool>? ToolClicked;
    public event Action<int>? ColorClicked, WidthClicked;
    public event Action<double>? OpacityChanged;
    public event Action<TabletMode>? TabletModeChanged;

    public ToolbarWindow()
    {
        InitializeComponent();
        for (int i = 0; i < Settings.Colors.Length; i++)
        {
            int n = i;
            var dot = new Ellipse { Width = 18, Height = 18, Fill = (Brush)new BrushConverter().ConvertFromString(Settings.Colors[i])!, Stroke = Brushes.Black, StrokeThickness = 0.5 };
            var b = new Button { Style = (Style)Resources["Tb"], Width = 28, Content = dot, ToolTip = $"{Settings.ColorNames[i]} ({i + 1})", BorderBrush = On };
            if (Settings.ColorNames[i] == "Black") dot.Stroke = OffText;   // visible on the dark bar
            b.Click += (_, _) => ColorClicked?.Invoke(n);
            colorButtons.Add(b);
            ColorPanel.Children.Add(b);
        }
        for (int i = 0; i < Settings.Widths.Length; i++)
        {
            int n = i;
            // the dot takes the button's text colour, so it stays visible when the button turns blue
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
        LaserBtn.Click += (_, _) => ToolClicked?.Invoke(Tool.Laser);
        foreach (var (radio, m) in new[] { (TabletAuto, TabletMode.Auto), (TabletOn, TabletMode.On), (TabletOff, TabletMode.Off) })
            radio.Checked += (_, _) => { if (!refreshing) TabletModeChanged?.Invoke(m); };
        OpacitySlider.ValueChanged += (_, e) =>
        {
            ShowOpacity(e.NewValue);
            if (!refreshing) OpacityChanged?.Invoke(Math.Round(e.NewValue, 2));
        };
        UndoBtn.Click += (_, _) => UndoClicked?.Invoke();
        ClearBtn.Click += (_, _) => ClearClicked?.Invoke();
        FadeBtn.Click += (_, _) => FadeClicked?.Invoke();
        ScreenBtn.Click += (_, _) => ScreenClicked?.Invoke();
        FoldBtn.Click += (_, _) => FoldClicked?.Invoke();
        CloseBtn.Click += (_, _) => CloseClicked?.Invoke();
        AllowBtn.Click += (_, _) => AskAnswered?.Invoke(true);
        DenyBtn.Click += (_, _) => AskAnswered?.Invoke(false);
        RecBtn.Click += (_, _) => RecordClicked?.Invoke();
        PauseBtn.Click += (_, _) => PauseClicked?.Invoke();
        SettingsBtn.Click += (_, _) =>
        {
            SettingsPanel.Visibility = SettingsPanel.IsVisible ? Visibility.Collapsed : Visibility.Visible;
            Mark(SettingsBtn, SettingsPanel.Visibility == Visibility.Visible);
        };
        foreach (var (box, name) in Options())
        {
            box.Checked += (_, _) => { if (!refreshing) OptionChanged?.Invoke(name, true); };
            box.Unchecked += (_, _) => { if (!refreshing) OptionChanged?.Invoke(name, false); };
        }
        // DragMove returns when the mouse is let go: save the place once, not on every pixel
        Grip.MouseLeftButtonDown += (_, e) => { if (e.ButtonState == MouseButtonState.Pressed) { DragMove(); Moved?.Invoke(); } };

        HintsInside(this);
        // a notice is dismissed by clicking it (a start-up warning stays: it is about this computer, not this moment)
        Hint.MouseLeftButtonUp += (_, _) => { if (notice != null && Hint.Text == Standing(notice, warning)) Notice(null); };

        SourceInitialized += (_, _) =>
        {
            hwnd = new WindowInteropHelper(this).Handle;
            HwndSource.FromHwnd(hwnd)!.AddHook((IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) =>
            {
                // tapping a toolbar button leaves the keyboard with PowerPoint
                if (msg == Native.WM_MOUSEACTIVATE) { handled = true; return new IntPtr(Native.MA_NOACTIVATE); }
                return IntPtr.Zero;
            });
            Native.RoundCorners(hwnd);
            // CONTRASTINK_TEST_NOHIDE: the test's control run, which must see the toolbar in a capture
            HiddenFromCapture = Environment.GetEnvironmentVariable("CONTRASTINK_TEST_NOHIDE") != "1" && Native.HideFromCapture(hwnd);
            if (!HiddenFromCapture)
                Warn("This toolbar is NOT hidden from recordings (it needs Windows 10 version 2004 or newer). It will show in OBS: make it small (‹) or move it to a corner.");
            if (!Native.SetExStyle(hwnd, Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE, 0))
                App.Log(new InvalidOperationException("toolbar: no-activate style was not applied"));
        };
    }

    string? warning, notice;

    /// <summary>
    /// Something the presenter should know about recording (OBS not reachable, stopped by itself, disk filling up),
    /// shown under the buttons until it is replaced or cleared with null. A start-up warning still comes first.
    /// </summary>
    public void Notice(string? text)
    {
        notice = text;
        Standing();
    }

    /// <summary>
    /// Shows the standing messages, or nothing. A notice (OBS stopped, disk filling up) comes first and a start-up
    /// warning stays under it: before, a warning that never goes away (older Windows 10) hid every recording notice.
    /// </summary>
    void Standing()
    {
        var text = Standing(notice, warning);
        if (text == null) { Hint.Visibility = Visibility.Collapsed; return; }
        Hint.Text = text;
        Hint.Foreground = Brushes.Salmon;
        Hint.Visibility = Visibility.Visible;
    }

    static string? Standing(string? notice, string? warning) =>
        notice != null && warning != null ? notice + "\n" + warning : notice ?? warning;

    static readonly Brush Grey = new SolidColorBrush(Color.FromRgb(0x8A, 0x95, 0xA6));
    static readonly Brush RecRed = new SolidColorBrush(Color.FromRgb(0xFF, 0x3B, 0x30));
    static readonly Brush Amber = new SolidColorBrush(Color.FromRgb(0xFF, 0xB0, 0x20));

    /// <summary>The recording buttons: grey ⏺ when OBS isn't connected, white when ready, red ⏹ and a timer while recording.</summary>
    internal void ShowRecording(Recorder.State state, bool connected, TimeSpan elapsed)
    {
        bool on = state is Recorder.State.Recording or Recorder.State.Paused or Recorder.State.Stopping;
        RecDot.Text = on ? "⏹" : "⏺";
        RecDot.Foreground = state == Recorder.State.Paused ? Amber : on ? RecRed : connected ? RecRed : Grey;
        Label(RecBtn, on ? "Stop recording (OBS)" : state == Recorder.State.Starting ? "Starting OBS recording" : connected ? "Record with OBS (start / stop)" : "Record with OBS (OBS not connected yet: press to connect)");
        PauseBtn.Visibility = on ? Visibility.Visible : Visibility.Hidden;
        PauseBtn.Content = state == Recorder.State.Paused ? "▶" : "⏸";
        Label(PauseBtn, state == Recorder.State.Paused ? "Resume recording" : "Pause recording");
        RecTime.Visibility = on ? Visibility.Visible : Visibility.Hidden;
        RecTime.Text = Obs.Time(elapsed, elapsed.TotalHours >= 1);   // paused shows as the amber ⏹ and the ▶ button
    }

    /// <summary>A button's hint and its name for screen readers (and the Windows check), kept the same.</summary>
    static void Label(FrameworkElement e, string text)
    {
        e.ToolTip = text;
        System.Windows.Automation.AutomationProperties.SetName(e, text);
    }

    /// <summary>
    /// A problem the presenter must know about: the handle turns red and the line under the buttons stays visible.
    /// (Inside the toolbar, so it is no more recorded than the toolbar is; a message box would be.)
    /// </summary>
    public void Warn(string text)
    {
        // a second warning joins the first instead of replacing it (both are about this computer)
        if (!warnings.Contains(text)) warnings.Add(text);
        ShowWarnings();
    }

    /// <summary>A warning that is no longer true (the keyboard watcher is back) goes.</summary>
    public void Unwarn(string text)
    {
        if (warnings.Remove(text)) ShowWarnings();
    }

    readonly List<string> warnings = new();

    void ShowWarnings()
    {
        warning = warnings.Count == 0 ? null : string.Join("\n", warnings);
        GripText.Foreground = warning != null ? Brushes.Red : (Brush)Resources["Blue"];
        Grip.ToolTip = warning ?? "Contrast Ink. Drag to move. The toolbar is hidden from OBS recordings.";
        Standing();
    }

    /// <summary>Clears the notice only if it is still this one (another may have replaced it since).</summary>
    public void ClearNotice(string text)
    {
        if (notice == text) Notice(null);
    }

    /// <summary>A tablet on the cable asks to draw: <paramref name="text"/> with Allow and Deny (null: the question is gone).</summary>
    public void Ask(string? text)
    {
        AskText.Text = text ?? "";
        AskPanel.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
    }

    public event Action<bool>? AskAnswered;

    /// <summary>Every ToolTip becomes a hint line inside the toolbar; no tooltip window ever opens.</summary>
    void HintsInside(DependencyObject root)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root))
        {
            if (child is not FrameworkElement fe) continue;
            if (fe.ToolTip is string text)
            {
                ToolTipService.SetIsEnabled(fe, false);
                // screen readers name the button by its hint (the visible label is only a symbol)
                System.Windows.Automation.AutomationProperties.SetName(fe, text);
                fe.MouseEnter += (_, _) =>
                {
                    if (!showNames) return;
                    Hint.Text = fe.ToolTip as string ?? text; Hint.Foreground = OffText; Hint.Visibility = Visibility.Visible;
                };
                fe.MouseLeave += (_, _) => Standing();   // a standing warning or notice comes back; an ordinary hint goes
            }
            HintsInside(fe);
        }
    }

    public void KeepOnTop()
    {
        if (hwnd != IntPtr.Zero) Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
    }

    (CheckBox box, string name)[] Options() => new[]
    {
        (OptZ, nameof(Settings.UndoWithZ)), (OptRightClick, nameof(Settings.UndoWithRightClick)), (OptButton, nameof(Settings.UndoButtonByPen)),
        (OptEraserEnd, nameof(Settings.PenEraserEnd)), (OptSlides, nameof(Settings.MarksPerSlide)),
        (OptNames, nameof(Settings.ShowButtonNames)), (OptPad, nameof(Settings.TabletPad)),
    };

    static void Mark(Button b, bool on)
    {
        b.Background = on ? On : Brushes.Transparent;
        b.Foreground = on ? OnText : OffText;
    }

    /// <summary>Shows the current state: which tool, colour, width, and whether drawing is on.</summary>
    /// <param name="screen">The screen the drawing layer is on now (0 = the first): the presenter's choice, or the
    /// main screen while the chosen one is unplugged.</param>
    public void Refresh(bool drawing, Settings s, int screens, int screen, bool folded)
    {
        Mark(DrawBtn, drawing);
        DrawText.Text = drawing ? " On" : " Off";
        Mark(PenBtn, s.Tool == Tool.Pen);
        Mark(HighBtn, s.Tool == Tool.Highlighter);
        Mark(ArrowBtn, s.Tool == Tool.Arrow);
        Mark(OvalBtn, s.Tool == Tool.Oval);
        Mark(EraseBtn, s.Tool == Tool.Eraser);
        Mark(LaserBtn, s.Tool == Tool.Laser);
        Mark(FadeBtn, s.FadingInk);
        for (int i = 0; i < colorButtons.Count; i++) colorButtons[i].BorderThickness = new Thickness(i == s.Color ? 2 : 0);
        for (int i = 0; i < widthButtons.Count; i++) Mark(widthButtons[i], i == s.Width);
        ScreenBtn.Visibility = screens > 1 ? Visibility.Visible : Visibility.Collapsed;
        ScreenText.Text = (screen + 1).ToString();
        Full.Visibility = folded ? Visibility.Collapsed : Visibility.Visible;
        if (folded) { SettingsPanel.Visibility = Visibility.Collapsed; Mark(SettingsBtn, false); }
        refreshing = true;
        try
        {
            OptZ.IsChecked = s.UndoWithZ; OptRightClick.IsChecked = s.UndoWithRightClick; OptButton.IsChecked = s.UndoButtonByPen;
            OptEraserEnd.IsChecked = s.PenEraserEnd; OptSlides.IsChecked = s.MarksPerSlide;
            OptNames.IsChecked = s.ShowButtonNames;
            OptPad.IsChecked = s.TabletPad;
            TabletAuto.IsChecked = s.PenTabletMode == TabletMode.Auto;
            TabletOn.IsChecked = s.PenTabletMode == TabletMode.On;
            TabletOff.IsChecked = s.PenTabletMode == TabletMode.Off;
            if (Math.Abs(OpacitySlider.Value - s.Opacity) > 0.001) OpacitySlider.Value = s.Opacity;
            ShowOpacity(s.Opacity);
        }
        finally { refreshing = false; }
        FoldBtn.Content = folded ? "›" : "‹";
        if (showNames != s.ShowButtonNames) { showNames = s.ShowButtonNames; if (!showNames) Standing(); }
    }

    void ShowOpacity(double o)
    {
        Label(OpacitySlider, $"Opacity {Math.Round(o * 100)}%: of the pen, arrow and circle (new marks). The highlighter keeps its own see-through look.");
        if (OpacitySlider.IsMouseOver && showNames) Hint.Text = (string)OpacitySlider.ToolTip;   // dragging: the % follows
    }

    /// <summary>
    /// The toolbar fits a screen <paramref name="screenWidth"/> device pixels wide: the tools wrap onto a second row
    /// when one row would run past its edge (a 1024-wide projector, a laptop at 150%).
    /// </summary>
    public void FitWidth(int screenWidth)
    {
        var source = PresentationSource.FromVisual(this);
        if (source?.CompositionTarget == null || Full.Visibility != Visibility.Visible) return;
        double dip = screenWidth / source.CompositionTarget.TransformToDevice.M11;
        // handle, ✏, recording, ‹, ✕: they always stay in the row (measured one by one: a window wider than its
        // screen is cut short by Windows, so the window's own width can't be trusted here)
        double others = 24;   // the row's own margins and the window's edge, with room to spare
        if (Full.Parent is Panel row)
            foreach (UIElement c in row.Children)
                if (c != Full && c is FrameworkElement f && f.Visibility != Visibility.Collapsed)
                    others += f.ActualWidth + f.Margin.Left + f.Margin.Right;
        double room = Math.Max(200, dip - others);
        if (double.IsInfinity(Full.MaxWidth) ? room < Full.ActualWidth + 1 : Math.Abs(Full.MaxWidth - room) > 1)
            Full.MaxWidth = room;
    }

    /// <summary>How to connect a tablet (this run's code, the address), or that one is connected; null: switched off.</summary>
    public void ShowPad(string? text)
    {
        PadText.Text = text ?? "";
        PadText.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>Says under the choice what was found at start, and how its pen is used now.</summary>
    public void ShowTablet(string? found, bool asMouse) =>
        TabletText.Text = (found != null ? $"Found: {found}. " : "No pen tablet found (with Windows Ink off in its own settings, it is a mouse already). ")
            + (asMouse ? "Its pen works like the mouse: switch drawing on with ✏, F9 or Ctrl." : "Pens work as pens.");

    bool showNames = true;   // ⚙ → Toolbar: names of buttons on hover (warnings and notices show either way)
}

using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Ink;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using ContrastInk.Core;

namespace ContrastInk;

public partial class OverlayWindow : Window
{
    // almost invisible (1/255): enough for Windows to send clicks to this layer while drawing
    static readonly Brush Catch = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0));

    IntPtr hwnd;
    bool drawing;
    Tool tool = Tool.Pen;
    Color color = Colors.Red;
    double width = 5;
    double opacity = 1;     // of new pen, arrow and circle marks
    bool laserDown;         // the laser's line is being drawn

    // undo history: what was added or removed, newest last (each slide has its own)
    List<(bool added, StrokeCollection strokes)> history = new();

    // each PowerPoint slide's marks and undo history, by "file#position"; "" is everything outside a slide show
    sealed record Page(StrokeCollection Strokes, List<(bool added, StrokeCollection strokes)> History);
    readonly Dictionary<string, Page> pages = new();
    string pageKey = "";

    /// <summary>A mark was finished: where its bottom-right corner is, in screen pixels (for the undo button beside it).</summary>
    public event Action<System.Drawing.Point>? MarkDone;
    /// <summary>The pen or mouse went down on the layer: a new mark is starting.</summary>
    public event Action? MarkStarting;
    /// <summary>A right-click or the pen's side button while drawing: the app decides (it may be switched off).</summary>
    public event Action? UndoGesture;
    DateTime lastGesture;

    /// <summary>The pen's eraser end removes marks (WPF: the "inverted" stylus).</summary>
    public bool PenEraserEnd { get; set; } = true;
    bool quiet;   // changes made by undo or fading are not history

    // fading ink
    readonly Dictionary<Stroke, (DateTime born, Color baseColor)> fading = new();
    readonly DispatcherTimer fadeTimer = new() { Interval = TimeSpan.FromMilliseconds(40) };
    public bool FadingInk { get; set; }
    public Func<bool> ShiftHeld { get; set; } = () => false;

    // arrow and oval: the mark being dragged
    Stroke? shape;
    Pt shapeStart;

    public OverlayWindow()
    {
        InitializeComponent();
        Ink.Strokes.StrokesChanged += (_, e) =>
        {
            if (quiet || shape != null) return;
            if (e.Added.Count > 0) Remember(true, e.Added);
            if (e.Removed.Count > 0) Remember(false, e.Removed);
        };
        Ink.StrokeCollected += (_, e) => { StartFading(e.Stroke); Done(e.Stroke); };
        Ink.PreviewMouseLeftButtonDown += (_, _) => { if (drawing && tool != Tool.Laser) MarkStarting?.Invoke(); };
        Ink.PreviewStylusDown += (_, _) => { if (drawing && tool != Tool.Laser) MarkStarting?.Invoke(); };
        // right-click, and the pen's side button (Windows turns side button + touch into a right-click as well:
        // one press must be one undo, so a second within 0.4 s is the same press)
        Ink.PreviewMouseRightButtonDown += (_, e) => { if (drawing) { Gesture(); e.Handled = true; } };
        Ink.PreviewMouseRightButtonUp += (_, e) => { if (drawing) e.Handled = true; };
        Ink.PreviewStylusButtonDown += (_, e) =>
        {
            if (drawing && e.StylusButton.Guid == StylusPointProperties.BarrelButton.Id) { Gesture(); e.Handled = true; }
        };
        Ink.PreviewMouseLeftButtonDown += ShapeDown;
        Ink.PreviewMouseMove += ShapeMove;
        Ink.PreviewMouseLeftButtonUp += ShapeUp;
        Ink.PreviewMouseLeftButtonDown += LaserDown;
        Ink.PreviewMouseMove += LaserMove;   // a pen hovering moves the mouse too: the dot follows it
        Ink.PreviewMouseLeftButtonUp += LaserUp;
        Ink.MouseLeave += (_, _) => { if (!laserDown) LaserLayer.HideDot(); };
        fadeTimer.Tick += (_, _) => FadeTick();
        SourceInitialized += (_, _) =>
        {
            hwnd = new WindowInteropHelper(this).Handle;
            if (!Native.SetExStyle(hwnd, Native.WS_EX_LAYERED | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE | Native.WS_EX_TRANSPARENT, 0))
                App.Log(new InvalidOperationException("overlay: click-through style was not applied at start"));
            HwndSource.FromHwnd(hwnd)!.AddHook((IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) =>
            {
                // clicking the drawing layer must never take the keyboard away from PowerPoint
                if (msg == Native.WM_MOUSEACTIVATE) { handled = true; return new IntPtr(Native.MA_NOACTIVATE); }
                return IntPtr.Zero;
            });
        };
        ApplyTool();
    }

    /// <summary>Cover this monitor exactly (in real pixels, whatever the display scale).</summary>
    internal void Cover(Native.RECT r)
    {
        if (hwnd == IntPtr.Zero) return;
        for (int i = 0; i < 2; i++)   // twice: moving to a monitor with another scale resizes the window once
            Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
    }

    public void KeepOnTop()
    {
        if (hwnd != IntPtr.Zero) Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
    }

    /// <summary>Drawing: this layer takes the mouse and pen. Not drawing: every click goes through to the app below.</summary>
    public void SetDrawing(bool on)
    {
        if (drawing == on) return;
        drawing = on;
        if (!on) { FinishShape(); EndLaser(); }
        // read back: a layer stuck in the wrong mode either blocks PowerPoint or never draws, and says nothing
        if (hwnd != IntPtr.Zero && !Native.SetExStyle(hwnd, on ? 0 : Native.WS_EX_TRANSPARENT, on ? Native.WS_EX_TRANSPARENT : 0))
            App.Log(new InvalidOperationException("overlay: could not switch drawing " + (on ? "on" : "off")));
        Ink.Background = on ? Catch : Brushes.Transparent;
    }

    public void SetTool(Tool t) { tool = t; ApplyTool(); }
    public void SetPenEraserEnd(bool on) { PenEraserEnd = on; ApplyTool(); }

    void Gesture()
    {
        var now = DateTime.UtcNow;
        if (now - lastGesture < TimeSpan.FromMilliseconds(400)) return;
        lastGesture = now;
        UndoGesture?.Invoke();
    }

    void Done(Stroke s)
    {
        if (MarkDone == null || hwnd == IntPtr.Zero) return;
        var b = s.GetBounds();
        var p = Ink.PointToScreen(new Point(b.Right, b.Bottom));   // real screen pixels, whatever the display scale
        MarkDone(new System.Drawing.Point((int)p.X, (int)p.Y));
    }

    /// <summary>
    /// Shows one slide's marks, keeping the ones on screen for when their slide comes back. A slide never seen starts clean.
    /// Fading marks are not kept: they were going anyway.
    /// The slide show ending ("") forgets every slide's marks: starting the show again (a rehearsal, then the real
    /// recording) must start clean, not bring the rehearsal's marks back into the video.
    /// </summary>
    public void ShowPage(string key)
    {
        if (key == pageKey) return;
        FinishShape();
        RemoteEnd();   // a tablet stroke under way stays on the slide it was drawn on
        pages[pageKey] = new Page(new StrokeCollection(Ink.Strokes.Where(s => !fading.ContainsKey(s))), history);
        if (key == "")
            foreach (var slide in pages.Keys.Where(k => k != "").ToList()) pages.Remove(slide);
        var next = pages.TryGetValue(key, out var p) ? p : new Page(new StrokeCollection(), new());
        quiet = true;
        try
        {
            Ink.Strokes.Clear();
            Ink.Strokes.Add(next.Strokes);
        }
        finally { quiet = false; }
        history = next.History;
        pageKey = key;
    }

    /// <summary>Whether Undo would change anything on this slide.</summary>
    public bool CanUndo => history.Any(h => !h.added || h.strokes.Any(Ink.Strokes.Contains));
    public void SetColor(Color c) { color = c; ApplyTool(); }
    public void SetWidth(double w) { width = w; ApplyTool(); }
    public void SetOpacity(double o) { opacity = Math.Clamp(o, Settings.MinOpacity, 1); ApplyTool(); }

    void ApplyTool()
    {
        FinishShape();
        if (tool != Tool.Laser) EndLaser();
        LaserLayer.SetWidth(width);
        Ink.EditingMode = tool switch
        {
            Tool.Pen or Tool.Highlighter => InkCanvasEditingMode.Ink,
            Tool.Eraser => InkCanvasEditingMode.EraseByStroke,
            _ => InkCanvasEditingMode.None,   // arrow and oval: ShapeDown/Move/Up; the laser: LaserDown/Move/Up
        };
        Ink.DefaultDrawingAttributes = Attributes();
        // the eraser end of a pen erases whatever tool is chosen (or, switched off, does what the tip does)
        Ink.EditingModeInverted = PenEraserEnd ? InkCanvasEditingMode.EraseByStroke : Ink.EditingMode;
        Ink.Cursor = tool == Tool.Eraser ? null : tool == Tool.Laser ? Cursors.None : Cursors.Pen;   // the laser's dot is the cursor
        Ink.UseCustomCursor = tool != Tool.Eraser;
    }

    DrawingAttributes Attributes() => tool == Tool.Highlighter
        ? new DrawingAttributes { Color = color, Width = Settings.HighlighterWidth(width), Height = Settings.HighlighterWidth(width), IsHighlighter = true, IgnorePressure = true, FitToCurve = true }
        : new DrawingAttributes { Color = Color.FromArgb((byte)Math.Round(color.A * opacity), color.R, color.G, color.B), Width = width, Height = width, FitToCurve = tool == Tool.Pen, IgnorePressure = tool != Tool.Pen, StylusTip = StylusTip.Ellipse };

    // ---------- a tablet used as a pad (PadServer): its strokes, drawn here so OBS records them ----------
    Stroke? remote;            // the pen or highlighter line, or the arrow or oval, being drawn on the tablet
    Pt remoteStart;
    bool remoteErasing, remoteLaser;

    Point FromPad(float fx, float fy) => new(fx * Ink.ActualWidth, fy * Ink.ActualHeight);

    /// <summary>The tablet's pen touched, at fractions of this screen; <paramref name="eraserEnd"/>: its eraser end.</summary>
    public void RemoteBegin(float fx, float fy, bool eraserEnd)
    {
        RemoteCancel();
        var p = FromPad(fx, fy);
        remoteErasing = eraserEnd || tool == Tool.Eraser;
        remoteLaser = !remoteErasing && tool == Tool.Laser;
        if (remoteErasing) { RemoteErase(p); return; }
        if (remoteLaser) { LaserLayer.Down(p); return; }
        remoteStart = new Pt(p.X, p.Y);
        remote = new Stroke(Points(new[] { remoteStart, remoteStart })) { DrawingAttributes = Attributes() };
        quiet = true;   // remembered for undo once, when it ends
        try { Ink.Strokes.Add(remote); } finally { quiet = false; }
    }

    const int MaxRemotePoints = 20000;   // a stroke longer than this is a flood, not a hand

    public void RemoteMove(IEnumerable<(float x, float y)> points)
    {
        foreach (var (fx, fy) in points)
        {
            if (remote != null && remote.StylusPoints.Count >= MaxRemotePoints) return;
            var p = FromPad(fx, fy);
            if (remoteErasing) RemoteErase(p);
            else if (remoteLaser) LaserLayer.Move(p, touching: true);
            else if (remote != null && tool is Tool.Arrow or Tool.Oval)
            {
                var end = new Pt(p.X, p.Y);
                remote.StylusPoints = Points(tool == Tool.Arrow ? Shapes.Arrow(remoteStart, end, width) : Shapes.Oval(remoteStart, end));
            }
            else remote?.StylusPoints.Add(new StylusPoint(p.X, p.Y));
        }
    }

    public void RemoteEnd()
    {
        if (remoteLaser) { LaserLayer.HideDot(); remoteLaser = false; }
        remoteErasing = false;
        if (remote == null) return;
        var done = remote;
        remote = null;
        var b = done.GetBounds();
        if (tool is Tool.Arrow or Tool.Oval && b.Width < 4 && b.Height < 4) { quiet = true; Ink.Strokes.Remove(done); quiet = false; return; }
        Remember(true, new StrokeCollection { done });
        StartFading(done);
        Done(done);
    }

    /// <summary>A palm or a second finger on the tablet, or the tablet went: the stroke being drawn goes.</summary>
    public void RemoteCancel()
    {
        if (remoteLaser) { LaserLayer.HideDot(); remoteLaser = false; }
        remoteErasing = false;
        if (remote == null) return;
        quiet = true;
        try { Ink.Strokes.Remove(remote); } finally { quiet = false; }
        remote = null;
    }

    /// <summary>The tablet's pen above the glass: with the laser chosen, its dot follows.</summary>
    public void RemoteHover(float fx, float fy) { if (tool == Tool.Laser) LaserLayer.Move(FromPad(fx, fy), touching: false); }
    public void RemoteHoverEnd() { if (tool == Tool.Laser && !remoteLaser) LaserLayer.HideDot(); }

    void RemoteErase(Point p)
    {
        var hit = Ink.Strokes.HitTest(p, 16);
        if (hit.Count > 0) Ink.Strokes.Remove(hit);   // remembered for undo, like the eraser
    }

    /// <summary>
    /// The marks (and the laser) as a picture at most 1600 px wide, for the tablet's view of the screen; null when
    /// there are none. Asked by the tablet link a few times a second, on the UI thread.
    /// </summary>
    public System.Windows.Media.Imaging.BitmapSource? Snapshot()
    {
        if (Ink.Strokes.Count == 0 && !LaserLayer.Showing) return null;
        if (Content is not FrameworkElement root || root.ActualWidth < 1 || root.ActualHeight < 1) return null;
        var toDevice = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformToDevice.M11 ?? 1;
        double px = root.ActualWidth * toDevice, s = Math.Min(1, 1600 / px) * toDevice;
        var bmp = new System.Windows.Media.Imaging.RenderTargetBitmap(
            Math.Max(1, (int)(root.ActualWidth * s)), Math.Max(1, (int)(root.ActualHeight * s)), 96 * s, 96 * s, PixelFormats.Pbgra32);
        bmp.Render(root);
        bmp.Freeze();
        return bmp;
    }

    // ---------- laser pointer ----------
    void LaserDown(object sender, MouseButtonEventArgs e)
    {
        if (!drawing || tool != Tool.Laser) return;
        laserDown = true;
        LaserLayer.Down(e.GetPosition(Ink));
        Ink.CaptureMouse();
        e.Handled = true;
    }

    void LaserMove(object sender, MouseEventArgs e)
    {
        if (!drawing || tool != Tool.Laser) return;
        LaserLayer.Move(e.GetPosition(Ink), laserDown);
    }

    void LaserUp(object sender, MouseButtonEventArgs e)
    {
        if (!laserDown) return;
        laserDown = false;
        Ink.ReleaseMouseCapture();
        e.Handled = true;
    }

    void EndLaser()
    {
        if (laserDown) { laserDown = false; Ink.ReleaseMouseCapture(); }
        LaserLayer.HideDot();   // a line still fading finishes fading
    }

    // ---------- arrow and oval ----------
    static StylusPointCollection Points(IEnumerable<Pt> pts) => new(pts.Select(p => new StylusPoint(p.X, p.Y)));

    void ShapeDown(object sender, MouseButtonEventArgs e)
    {
        if (!drawing || tool is not (Tool.Arrow or Tool.Oval)) return;
        var p = e.GetPosition(Ink);
        shapeStart = new Pt(p.X, p.Y);
        shape = new Stroke(Points(new[] { shapeStart, shapeStart })) { DrawingAttributes = Attributes() };
        Ink.Strokes.Add(shape);
        Ink.CaptureMouse();
        e.Handled = true;
    }

    void ShapeMove(object sender, MouseEventArgs e)
    {
        if (shape == null) return;
        var p = e.GetPosition(Ink);
        var end = new Pt(p.X, p.Y);
        shape.StylusPoints = Points(tool == Tool.Arrow
            ? Shapes.Arrow(shapeStart, end, width)
            : Shapes.Oval(shapeStart, ShiftHeld() ? Shapes.Square(shapeStart, end) : end));
    }

    void ShapeUp(object sender, MouseButtonEventArgs e) { if (shape != null) { FinishShape(); e.Handled = true; } }

    void FinishShape()
    {
        if (shape == null) return;
        var done = shape;
        shape = null;
        Ink.ReleaseMouseCapture();
        // a click without a drag leaves nothing behind
        var b = done.GetBounds();
        if (b.Width < 4 && b.Height < 4) { quiet = true; Ink.Strokes.Remove(done); quiet = false; return; }
        Remember(true, new StrokeCollection { done });
        StartFading(done);
        Done(done);
    }

    // ---------- undo and clear ----------
    void Remember(bool added, StrokeCollection strokes)
    {
        history.Add((added, new StrokeCollection(strokes)));
        if (history.Count > 300) history.RemoveAt(0);
    }

    public void Undo()
    {
        FinishShape();
        while (history.Count > 0)
        {
            var (added, strokes) = history[^1];
            history.RemoveAt(history.Count - 1);
            quiet = true;
            try
            {
                if (added)
                {
                    var still = strokes.Where(Ink.Strokes.Contains).ToList();
                    if (still.Count == 0) continue;   // already faded away: undo the step before it
                    foreach (var s in still) Ink.Strokes.Remove(s);
                }
                else foreach (var s in strokes)
                {
                    if (Ink.Strokes.Contains(s)) continue;
                    if (fading.TryGetValue(s, out var f)) { s.DrawingAttributes.Color = f.baseColor; fading[s] = (DateTime.UtcNow, f.baseColor); fadeTimer.Start(); }
                    Ink.Strokes.Add(s);
                }
            }
            finally { quiet = false; }
            return;
        }
    }

    /// <summary>Removes every mark (Undo brings them back).</summary>
    public void ClearAll()
    {
        FinishShape();
        RemoteCancel();
        if (Ink.Strokes.Count > 0) Ink.Strokes.Clear();   // fading marks stay listed, so Undo can bring them back properly
    }

    public bool HasInk => Ink.Strokes.Count > 0;

    // ---------- fading ink ----------
    void StartFading(Stroke s)
    {
        if (!FadingInk || ShiftHeld()) return;   // Shift while drawing keeps the mark
        fading[s] = (DateTime.UtcNow, s.DrawingAttributes.Color);
        fadeTimer.Start();
    }

    void FadeTick()
    {
        var now = DateTime.UtcNow;
        foreach (var (s, (born, baseColor)) in fading.ToList())
        {
            if (!Ink.Strokes.Contains(s))   // cleared or erased: forget it once it could no longer be undone sensibly
            {
                if (now - born > TimeSpan.FromMinutes(2)) fading.Remove(s);
                continue;
            }
            double o = Fade.Opacity(now - born);
            if (o <= 0)
            {
                quiet = true;
                try { Ink.Strokes.Remove(s); } finally { quiet = false; }
                fading.Remove(s);
            }
            else s.DrawingAttributes.Color = Color.FromArgb((byte)(baseColor.A * o), baseColor.R, baseColor.G, baseColor.B);
        }
        if (!fading.Keys.Any(Ink.Strokes.Contains)) fadeTimer.Stop();
    }
}

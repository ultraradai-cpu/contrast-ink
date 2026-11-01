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
using LectureInk.Core;

namespace LectureInk;

public partial class OverlayWindow : Window
{
    // almost invisible (1/255): enough for Windows to send clicks to this layer while drawing
    static readonly Brush Catch = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0));

    IntPtr hwnd;
    bool drawing;
    Tool tool = Tool.Pen;
    Color color = Colors.Red;
    double width = 5;

    // undo history: what was added or removed, newest last
    readonly List<(bool added, StrokeCollection strokes)> history = new();
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
        Ink.StrokeCollected += (_, e) => StartFading(e.Stroke);
        Ink.PreviewMouseLeftButtonDown += ShapeDown;
        Ink.PreviewMouseMove += ShapeMove;
        Ink.PreviewMouseLeftButtonUp += ShapeUp;
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
        if (!on) FinishShape();
        // read back: a layer stuck in the wrong mode either blocks PowerPoint or never draws, and says nothing
        if (hwnd != IntPtr.Zero && !Native.SetExStyle(hwnd, on ? 0 : Native.WS_EX_TRANSPARENT, on ? Native.WS_EX_TRANSPARENT : 0))
            App.Log(new InvalidOperationException("overlay: could not switch drawing " + (on ? "on" : "off")));
        Ink.Background = on ? Catch : Brushes.Transparent;
    }

    public void SetTool(Tool t) { tool = t; ApplyTool(); }
    public void SetColor(Color c) { color = c; ApplyTool(); }
    public void SetWidth(double w) { width = w; ApplyTool(); }

    void ApplyTool()
    {
        FinishShape();
        Ink.EditingMode = tool switch
        {
            Tool.Pen or Tool.Highlighter => InkCanvasEditingMode.Ink,
            Tool.Eraser => InkCanvasEditingMode.EraseByStroke,
            _ => InkCanvasEditingMode.None,   // arrow and oval are drawn by ShapeDown/Move/Up
        };
        Ink.DefaultDrawingAttributes = Attributes();
        Ink.Cursor = tool == Tool.Eraser ? null : Cursors.Pen;
        Ink.UseCustomCursor = tool != Tool.Eraser;
    }

    DrawingAttributes Attributes() => tool == Tool.Highlighter
        ? new DrawingAttributes { Color = color, Width = Settings.HighlighterWidth(width), Height = Settings.HighlighterWidth(width), IsHighlighter = true, IgnorePressure = true, FitToCurve = true }
        : new DrawingAttributes { Color = color, Width = width, Height = width, FitToCurve = tool == Tool.Pen, IgnorePressure = tool != Tool.Pen, StylusTip = StylusTip.Ellipse };

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

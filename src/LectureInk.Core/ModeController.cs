namespace LectureInk.Core;

/// <summary>
/// Decides whether the overlay is drawing or letting clicks through to PowerPoint.
/// Four ways to draw, any of which is enough:
///  - F9 or the toolbar pen button toggles draw mode on and off ("manual");
///  - holding Ctrl draws while it is held;
///  - a pen or stylus near the screen draws, and moving the real mouse goes back to clicking.
/// Esc always goes back to clicking.
/// </summary>
public sealed class ModeController
{
    bool manual, ctrlHeld, ctrlUsedForShortcut, penActive;
    int mouseTravel;

    /// <summary>How far (in pixels) the real mouse must move before it takes over from the pen.</summary>
    public int MouseTakeoverPixels { get; init; } = 8;

    public bool Drawing => manual || (ctrlHeld && !ctrlUsedForShortcut) || penActive;
    public bool Manual => manual;

    /// <summary>Raised with the new value whenever <see cref="Drawing"/> changes.</summary>
    public event Action<bool>? Changed;

    public void Toggle() => Set(() => { manual = !manual; if (!manual) penActive = false; });
    public void SetManual(bool on) => Set(() => manual = on);

    public void CtrlDown() => Set(() => { if (!ctrlHeld) { ctrlHeld = true; ctrlUsedForShortcut = false; } });
    public void CtrlUp() => Set(() => { ctrlHeld = false; ctrlUsedForShortcut = false; });

    /// <summary>
    /// Another key pressed while Ctrl is held: that is a PowerPoint shortcut (Ctrl+C, Ctrl+S...),
    /// not drawing, so holding Ctrl stops counting until it is released. Ctrl+Z stays ours (undo).
    /// </summary>
    public void KeyWithCtrl(bool isUndo) => Set(() => { if (ctrlHeld && !isUndo) ctrlUsedForShortcut = true; });

    /// <summary>The pen or stylus moved or touched (Windows marks its input).</summary>
    public void PenSeen() => Set(() => { penActive = true; mouseTravel = 0; });

    /// <summary>The real mouse moved by (dx, dy) pixels.</summary>
    public void MouseMoved(int dx, int dy) => Set(() =>
    {
        if (!penActive) return;
        mouseTravel += Math.Abs(dx) + Math.Abs(dy);
        if (mouseTravel >= MouseTakeoverPixels) { penActive = false; mouseTravel = 0; }
    });

    public void Escape() => Set(() => { manual = false; penActive = false; ctrlUsedForShortcut = ctrlHeld; });

    void Set(Action change)
    {
        bool before = Drawing;
        change();
        if (Drawing != before) Changed?.Invoke(Drawing);
    }
}

namespace ContrastInk.Core;

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
    DateTime lastPen;

    /// <summary>How far (in pixels) the real mouse must move before it takes over from the pen.</summary>
    public int MouseTakeoverPixels { get; init; } = 8;

    /// <summary>
    /// The pen gives no signal when it is put down or moves away, so pen drawing ends this long after
    /// the pen was last seen (otherwise the letter keys would stay taken until the mouse moves).
    /// </summary>
    public TimeSpan PenTimeout { get; init; } = TimeSpan.FromSeconds(3);

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
    public void PenSeen(DateTime now) => Set(() => { penActive = true; mouseTravel = 0; lastPen = now; });

    /// <summary>Called a few times a second: ends pen drawing once the pen has been away for <see cref="PenTimeout"/>.</summary>
    public void Tick(DateTime now) => Set(() => { if (penActive && now - lastPen >= PenTimeout) penActive = false; });

    /// <summary>The real mouse moved by (dx, dy) pixels.</summary>
    public void MouseMoved(int dx, int dy) => Set(() =>
    {
        if (!penActive) return;
        mouseTravel += Math.Abs(dx) + Math.Abs(dy);
        if (mouseTravel >= MouseTakeoverPixels) { penActive = false; mouseTravel = 0; }
    });

    /// <summary>
    /// What the keyboard says right now about Ctrl. Windows can swallow a key's release (Ctrl+Alt+Del, Win+L,
    /// a UAC prompt), which would leave "Ctrl held" on and drawing stuck on, catching every click meant for PowerPoint.
    /// Called a few times a second with the real key state; it can only end Ctrl drawing, never start it.
    /// </summary>
    public void CtrlActuallyDown(bool down) => Set(() => { if (ctrlHeld && !down) { ctrlHeld = false; ctrlUsedForShortcut = false; } });

    public void Escape() => Set(() => { manual = false; penActive = false; ctrlUsedForShortcut = ctrlHeld; });

    void Set(Action change)
    {
        bool before = Drawing;
        change();
        if (Drawing != before) Changed?.Invoke(Drawing);
    }
}

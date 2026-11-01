using ContrastInk.Core;
using Xunit;

public class ModeControllerTests
{
    static readonly DateTime T0 = new(2026, 11, 1, 9, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void PenDrawingEndsThreeSecondsAfterThePenLeaves()
    {
        var m = new ModeController();
        m.PenSeen(T0);
        m.Tick(T0.AddSeconds(2.9)); Assert.True(m.Drawing);
        m.PenSeen(T0.AddSeconds(2.9));                  // still hovering: the clock restarts
        m.Tick(T0.AddSeconds(5)); Assert.True(m.Drawing);
        m.Tick(T0.AddSeconds(5.9)); Assert.False(m.Drawing);
    }

    [Fact]
    public void PenTimeoutDoesNotEndF9OrCtrlDrawing()
    {
        var m = new ModeController();
        m.Toggle(); m.PenSeen(T0); m.Tick(T0.AddMinutes(1));
        Assert.True(m.Drawing);
        var c = new ModeController();
        c.CtrlDown(); c.PenSeen(T0); c.Tick(T0.AddMinutes(1));
        Assert.True(c.Drawing);
    }

    static (ModeController m, List<bool> changes) New()
    {
        var m = new ModeController();
        var changes = new List<bool>();
        m.Changed += changes.Add;
        return (m, changes);
    }

    [Fact]
    public void StartsInClickMode() => Assert.False(new ModeController().Drawing);

    [Fact]
    public void F9TogglesAndRaisesChangeOncePerFlip()
    {
        var (m, ch) = New();
        m.Toggle(); Assert.True(m.Drawing);
        m.Toggle(); Assert.False(m.Drawing);
        Assert.Equal(new[] { true, false }, ch);
    }

    [Fact]
    public void HoldingCtrlDrawsOnlyWhileHeld()
    {
        var (m, _) = New();
        m.CtrlDown(); Assert.True(m.Drawing);
        m.CtrlDown(); Assert.True(m.Drawing);   // key repeat while held
        m.CtrlUp(); Assert.False(m.Drawing);
    }

    [Fact]
    public void CtrlShortcutForPowerPointStopsCtrlDrawingUntilReleased()
    {
        var (m, _) = New();
        m.CtrlDown();
        m.KeyWithCtrl(isUndo: false);           // e.g. Ctrl+C in PowerPoint
        Assert.False(m.Drawing);
        m.CtrlDown();                           // auto-repeat must not bring it back
        Assert.False(m.Drawing);
        m.CtrlUp(); m.CtrlDown();
        Assert.True(m.Drawing);                 // a fresh press draws again
    }

    [Fact]
    public void CtrlZKeepsDrawing()
    {
        var (m, _) = New();
        m.CtrlDown(); m.KeyWithCtrl(isUndo: true);
        Assert.True(m.Drawing);
    }

    [Fact]
    public void PenDrawsAndRealMouseTakesBackAfterSmallTravel()
    {
        var (m, _) = New();
        m.PenSeen(T0); Assert.True(m.Drawing);
        m.MouseMoved(2, 1); Assert.True(m.Drawing);    // a nudge of the desk is not a takeover
        m.MouseMoved(3, 3); Assert.False(m.Drawing);   // 9 px in total
    }

    [Fact]
    public void PenSeenResetsMouseTravel()
    {
        var (m, _) = New();
        m.PenSeen(T0); m.MouseMoved(5, 0); m.PenSeen(T0); m.MouseMoved(5, 0);
        Assert.True(m.Drawing);
    }

    [Fact]
    public void MouseDoesNotEndManualDrawMode()
    {
        var (m, _) = New();
        m.Toggle(); m.PenSeen(T0); m.MouseMoved(100, 100);
        Assert.True(m.Drawing);
    }

    [Fact]
    public void EscapeLeavesEveryMode()
    {
        var (m, _) = New();
        m.Toggle(); m.PenSeen(T0); m.CtrlDown();
        m.Escape();
        Assert.False(m.Drawing);
        m.CtrlUp(); m.CtrlDown();
        Assert.True(m.Drawing);
    }

    [Fact]
    public void TurningManualOffAlsoDropsPen()
    {
        var (m, _) = New();
        m.Toggle(); m.PenSeen(T0); m.Toggle();
        Assert.False(m.Drawing);
    }
}

public class ShapeTests
{
    [Fact]
    public void ArrowGoesFromStartToTipThenTwoSidesBehindTheTip()
    {
        var p = Shapes.Arrow(new Pt(0, 0), new Pt(100, 0), 5);
        Assert.Equal(5, p.Count);
        Assert.Equal(new Pt(0, 0), p[0]);
        Assert.Equal(new Pt(100, 0), p[1]);
        Assert.Equal(new Pt(100, 0), p[3]);
        Assert.True(p[2].X < 100 && p[4].X < 100);          // head points backwards
        Assert.True(p[2].Y * p[4].Y < 0);                    // one side above, one below
        Assert.Equal(Math.Abs(p[2].Y), Math.Abs(p[4].Y), 6); // symmetric
    }

    [Fact]
    public void ArrowHeadNeverLongerThanHalfTheArrow()
    {
        var p = Shapes.Arrow(new Pt(0, 0), new Pt(10, 0), 9);
        double head = Math.Sqrt(Math.Pow(p[2].X - 10, 2) + Math.Pow(p[2].Y, 2));
        Assert.True(head <= 5.0001);
    }

    [Fact]
    public void ZeroLengthArrowIsADot() => Assert.Equal(2, Shapes.Arrow(new Pt(5, 5), new Pt(5, 5), 3).Count);

    [Fact]
    public void OvalIsClosedAndInsideItsBox()
    {
        var p = Shapes.Oval(new Pt(100, 50), new Pt(0, 0));   // dragged up-left
        Assert.Equal(p[0], p[^1]);
        Assert.All(p, q => Assert.InRange(q.X, -1e-9, 100 + 1e-9));
        Assert.All(p, q => Assert.InRange(q.Y, -1e-9, 50 + 1e-9));
    }

    [Theory]
    [InlineData(30, 10, 30, 30)]
    [InlineData(-30, 10, -30, 30)]
    [InlineData(10, -40, 40, -40)]
    public void ShiftMakesASquareBoxKeepingDirection(double w, double h, double ew, double eh)
    {
        var e = Shapes.Square(new Pt(0, 0), new Pt(w, h));
        Assert.Equal(new Pt(ew, eh), e);
    }
}

public class FadeTests
{
    [Fact]
    public void FullyVisibleThenFadesThenGone()
    {
        Assert.Equal(1, Fade.Opacity(TimeSpan.Zero));
        Assert.Equal(1, Fade.Opacity(TimeSpan.FromSeconds(2)));
        Assert.Equal(0.5, Fade.Opacity(TimeSpan.FromSeconds(2.5)), 6);
        Assert.Equal(0, Fade.Opacity(TimeSpan.FromSeconds(3)));
        Assert.Equal(0, Fade.Opacity(TimeSpan.FromSeconds(30)));
    }
}

public class PenInputTests
{
    [Theory]
    [InlineData(0UL, InputKind.Mouse)]
    [InlineData(0xFF515700UL, InputKind.Pen)]
    [InlineData(0xFF515701UL, InputKind.Pen)]
    [InlineData(0xFF515780UL, InputKind.Touch)]
    [InlineData(0xFF515781UL, InputKind.Touch)]
    [InlineData(0xFF515600UL, InputKind.Mouse)]
    [InlineData(0x12345678UL, InputKind.Mouse)]
    public void ReadsTheWindowsSignature(ulong extra, InputKind kind) => Assert.Equal(kind, PenInput.Kind(extra));
}

public class SettingsTests
{
    [Fact]
    public void OutOfRangeValuesAreFixed()
    {
        var s = new Settings { Color = 99, Width = -3, Screen = 7, Tool = (Tool)42, ToolbarX = double.PositiveInfinity }.Clean(screens: 2);
        Assert.Equal(Settings.Colors.Length - 1, s.Color);
        Assert.Equal(0, s.Width);
        Assert.Equal(1, s.Screen);
        Assert.Equal(Tool.Pen, s.Tool);
        Assert.True(double.IsNaN(s.ToolbarX));
    }

    [Fact]
    public void SavesAndLoads()
    {
        var path = Path.Combine(Path.GetTempPath(), "contrastink-" + Guid.NewGuid() + "/settings.json");
        new Settings { Color = 2, Width = 2, FadingInk = true, Tool = Tool.Arrow, Screen = 1, ToolbarX = 40, ToolbarY = 60 }.Save(path);
        var s = Settings.Load(path, screens: 2);
        Assert.Equal((2, 2, true, Tool.Arrow, 1, 40.0, 60.0), (s.Color, s.Width, s.FadingInk, s.Tool, s.Screen, s.ToolbarX, s.ToolbarY));
    }

    [Fact]
    public void BrokenOrMissingFileGivesDefaults()
    {
        var dir = Path.Combine(Path.GetTempPath(), "contrastink-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "bad.json"), "{ not json");
        Assert.Equal(Tool.Pen, Settings.Load(Path.Combine(dir, "bad.json"), 1).Tool);
        Assert.Equal(Tool.Pen, Settings.Load(Path.Combine(dir, "missing.json"), 1).Tool);
    }

    [Fact]
    public void ScreenFallsBackWhenAMonitorIsUnplugged() => Assert.Equal(0, new Settings { Screen = 1 }.Clean(screens: 1).Screen);
}

public class ColorTests
{
    // WCAG relative luminance and contrast ratio
    static double Lum(string hex)
    {
        double C(int i) { double c = Convert.ToInt32(hex.Substring(i, 2), 16) / 255.0; return c <= 0.03928 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4); }
        return 0.2126 * C(1) + 0.7152 * C(3) + 0.0722 * C(5);
    }
    static double Contrast(string a, string b) { double x = Lum(a), y = Lum(b); return (Math.Max(x, y) + 0.05) / (Math.Min(x, y) + 0.05); }

    [Fact]
    public void EveryColourHasANameAndIsValid()
    {
        Assert.Equal(Settings.Colors.Length, Settings.ColorNames.Length);
        Assert.All(Settings.Colors, c => Assert.Matches("^#[0-9A-F]{6}$", c));
        Assert.Equal(Settings.Widths.Length, Settings.WidthNames.Length);
    }

    [Fact]
    public void BrightColoursStandOutOnBlackImages()
    {
        for (int i = 0; i < Settings.Colors.Length; i++)
            if (Settings.ColorNames[i] != "Black")
                Assert.True(Contrast(Settings.Colors[i], "#000000") >= 4.5, $"{Settings.ColorNames[i]} on black: {Contrast(Settings.Colors[i], "#000000"):0.0}");
    }

    [Fact]
    public void BlackAndRedWorkOnWhiteSlides()
    {
        Assert.True(Contrast(Settings.Colors[Array.IndexOf(Settings.ColorNames, "Black")], "#FFFFFF") >= 7);
        Assert.True(Contrast(Settings.Colors[Array.IndexOf(Settings.ColorNames, "Red")], "#FFFFFF") >= 3);
    }

    [Fact]
    public void WidthsGrowAndThickIsVisibleInA1080pVideo()
    {
        Assert.True(Settings.Widths.Zip(Settings.Widths.Skip(1)).All(p => p.First < p.Second));
        Assert.True(Settings.Widths[^1] >= 8);
        Assert.True(Settings.HighlighterWidth(Settings.Widths[0]) > Settings.Widths[^1]);
    }
}

public class KeyPolicyTests
{
    static KeyAction A(int vk, bool drawing, bool ctrl = false, bool altOrWin = false) => KeyPolicy.Decide(vk, drawing, ctrl, altOrWin).action;
    const int Right = 0x27, PageDown = 0x22, Space = 0x20, Esc = 0x1B, F9 = 0x78, Z = 0x5A, P = 0x50, B = 0x42, W = 0x57, Tab = 0x09;

    [Theory]
    [InlineData(0x50)] [InlineData(0x48)] [InlineData(0x45)] [InlineData(0x43)] [InlineData(0x31)] [InlineData(Esc)] [InlineData(0xDB)]
    public void NotDrawingEveryKeyIsPowerPoints(int vk) => Assert.Equal(KeyAction.Pass, A(vk, drawing: false));

    [Theory]
    [InlineData(Right)] [InlineData(PageDown)] [InlineData(Space)] [InlineData(B)] [InlineData(W)] [InlineData(0x25)] [InlineData(0x21)]
    public void SlideKeysAndBlackWhiteScreenReachPowerPointWhileDrawing(int vk) => Assert.Equal(KeyAction.Pass, A(vk, drawing: true));

    [Fact]
    public void ToolKeysAreOursOnlyWhileDrawing()
    {
        Assert.Equal(KeyAction.Pen, A(P, true));
        Assert.Equal(KeyAction.Highlighter, A(0x48, true));
        Assert.Equal(KeyAction.Arrow, A(0x41, true));
        Assert.Equal(KeyAction.Oval, A(0x4F, true));
        Assert.Equal(KeyAction.Eraser, A(0x45, true));
        Assert.Equal(KeyAction.Clear, A(0x43, true));
        Assert.Equal(KeyAction.Fade, A(0x46, true));
        Assert.Equal(KeyAction.Thinner, A(0xDB, true));
        Assert.Equal(KeyAction.Thicker, A(0xDD, true));
        Assert.Equal(KeyAction.StopDrawing, A(Esc, true));
    }

    [Fact]
    public void ColoursOneToSixOnBothRowsAndSevenPasses()
    {
        for (int i = 0; i < Settings.Colors.Length; i++)
        {
            Assert.Equal((KeyAction.Color, i), KeyPolicy.Decide(0x31 + i, true, false, false));
            Assert.Equal((KeyAction.Color, i), KeyPolicy.Decide(0x61 + i, true, false, false));
        }
        Assert.Equal(KeyAction.Pass, A(0x31 + Settings.Colors.Length, true));
        Assert.Equal(KeyAction.Pass, A(0x61 + Settings.Colors.Length, true));
    }

    [Fact]
    public void F9TogglesInEveryState()
    {
        Assert.Equal(KeyAction.ToggleDrawing, A(F9, false));
        Assert.Equal(KeyAction.ToggleDrawing, A(F9, true));
    }

    [Fact]
    public void CtrlShortcutsArePowerPointsExceptUndoWhileDrawing()
    {
        Assert.Equal(KeyAction.Undo, A(Z, drawing: true, ctrl: true));
        Assert.Equal(KeyAction.Pass, A(Z, drawing: false, ctrl: true));   // PowerPoint's own undo
        Assert.Equal(KeyAction.Pass, A(0x43, drawing: true, ctrl: true)); // Ctrl+C copies, never clears
        Assert.Equal(KeyAction.Pass, A(P, drawing: true, ctrl: true));    // Ctrl+P prints, never picks the pen
    }

    [Fact]
    public void AltAndWindowsKeyCombinationsAreNeverOurs()
    {
        Assert.Equal(KeyAction.Pass, A(Tab, true, altOrWin: true));
        Assert.Equal(KeyAction.Pass, A(F9, true, altOrWin: true));
        Assert.Equal(KeyAction.Pass, A(P, true, altOrWin: true));
    }
}

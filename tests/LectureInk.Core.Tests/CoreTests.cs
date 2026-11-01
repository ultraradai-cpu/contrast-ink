using LectureInk.Core;
using Xunit;

public class ModeControllerTests
{
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
        m.PenSeen(); Assert.True(m.Drawing);
        m.MouseMoved(2, 1); Assert.True(m.Drawing);    // a nudge of the desk is not a takeover
        m.MouseMoved(3, 3); Assert.False(m.Drawing);   // 9 px in total
    }

    [Fact]
    public void PenSeenResetsMouseTravel()
    {
        var (m, _) = New();
        m.PenSeen(); m.MouseMoved(5, 0); m.PenSeen(); m.MouseMoved(5, 0);
        Assert.True(m.Drawing);
    }

    [Fact]
    public void MouseDoesNotEndManualDrawMode()
    {
        var (m, _) = New();
        m.Toggle(); m.PenSeen(); m.MouseMoved(100, 100);
        Assert.True(m.Drawing);
    }

    [Fact]
    public void EscapeLeavesEveryMode()
    {
        var (m, _) = New();
        m.Toggle(); m.PenSeen(); m.CtrlDown();
        m.Escape();
        Assert.False(m.Drawing);
        m.CtrlUp(); m.CtrlDown();
        Assert.True(m.Drawing);
    }

    [Fact]
    public void TurningManualOffAlsoDropsPen()
    {
        var (m, _) = New();
        m.Toggle(); m.PenSeen(); m.Toggle();
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
        var path = Path.Combine(Path.GetTempPath(), "lectureink-" + Guid.NewGuid() + "/settings.json");
        new Settings { Color = 2, Width = 2, FadingInk = true, Tool = Tool.Arrow, Screen = 1, ToolbarX = 40, ToolbarY = 60 }.Save(path);
        var s = Settings.Load(path, screens: 2);
        Assert.Equal((2, 2, true, Tool.Arrow, 1, 40.0, 60.0), (s.Color, s.Width, s.FadingInk, s.Tool, s.Screen, s.ToolbarX, s.ToolbarY));
    }

    [Fact]
    public void BrokenOrMissingFileGivesDefaults()
    {
        var dir = Path.Combine(Path.GetTempPath(), "lectureink-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "bad.json"), "{ not json");
        Assert.Equal(Tool.Pen, Settings.Load(Path.Combine(dir, "bad.json"), 1).Tool);
        Assert.Equal(Tool.Pen, Settings.Load(Path.Combine(dir, "missing.json"), 1).Tool);
    }

    [Fact]
    public void ScreenFallsBackWhenAMonitorIsUnplugged() => Assert.Equal(0, new Settings { Screen = 1 }.Clean(screens: 1).Screen);
}

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
        Assert.Null(s.ToolbarX);
    }

    [Fact]
    public void SavesAndLoads()
    {
        var path = Path.Combine(Path.GetTempPath(), "contrastink-" + Guid.NewGuid() + "/settings.json");
        new Settings { Color = 2, Width = 2, FadingInk = true, Tool = Tool.Arrow, Screen = 1, ToolbarX = 40, ToolbarY = 60 }.Save(path);
        var s = Settings.Load(path, screens: 2);
        Assert.Equal((2, 2, true, Tool.Arrow, 1, (double?)40.0, (double?)60.0), (s.Color, s.Width, s.FadingInk, s.Tool, s.Screen, s.ToolbarX, s.ToolbarY));
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
    public void BrandNewDefaultSettingsSaveAndLoad()
    {
        // the first launch: nothing chosen yet, no toolbar position. This crashed start-up on Windows once.
        var path = Path.Combine(Path.GetTempPath(), "contrastink-" + Guid.NewGuid() + "/settings.json");
        new Settings().Save(path);
        Assert.True(File.Exists(path), "the default settings were not written");
        var s = Settings.Load(path, screens: 1);
        Assert.Equal(Tool.Pen, s.Tool);
    }

    [Fact]
    public void SavingNeverThrowsWhateverIsInTheSettings()
    {
        var path = Path.Combine(Path.GetTempPath(), "contrastink-" + Guid.NewGuid() + "/settings.json");
        var odd = new Settings();
        typeof(Settings).GetProperty("ToolbarX")!.SetValue(odd, typeof(Settings).GetProperty("ToolbarX")!.PropertyType == typeof(double) ? double.NaN : (double?)double.PositiveInfinity);
        odd.Save(path);   // must not throw: settings are a convenience, never a reason for the app to stop
    }

    [Fact]
    public void UndoAndSlideOptionsAreOnForASettingsFileFromBeforeThem()
    {
        var path = Path.Combine(Path.GetTempPath(), "contrastink-" + Guid.NewGuid() + "/settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, "{ \"Color\": 2, \"Width\": 1 }");   // an older version's file
        var s = Settings.Load(path, 1);
        Assert.True(s.UndoWithZ && s.UndoWithRightClick && s.PenEraserEnd && s.UndoButtonByPen && s.MarksPerSlide);
        Assert.Equal(2, s.Color);
    }

    [Fact]
    public void UndoOptionsSwitchedOffStayOff()
    {
        var path = Path.Combine(Path.GetTempPath(), "contrastink-" + Guid.NewGuid() + "/settings.json");
        new Settings { UndoWithZ = false, UndoWithRightClick = false, PenEraserEnd = false, UndoButtonByPen = false, MarksPerSlide = false }.Save(path);
        var s = Settings.Load(path, 1);
        Assert.False(s.UndoWithZ || s.UndoWithRightClick || s.PenEraserEnd || s.UndoButtonByPen || s.MarksPerSlide);
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
    public void ZAloneUndoesOnlyWhenTheSettingIsOnAndWhileDrawing()
    {
        Assert.Equal(KeyAction.Undo, KeyPolicy.Decide(Z, true, false, false, zUndoes: true).action);
        Assert.Equal(KeyAction.Pass, KeyPolicy.Decide(Z, true, false, false, zUndoes: false).action);   // setting off: PowerPoint's
        Assert.Equal(KeyAction.Pass, KeyPolicy.Decide(Z, false, false, false, zUndoes: true).action);   // not drawing: PowerPoint's
        Assert.Equal(KeyAction.Pass, KeyPolicy.Decide(Z, true, false, true, zUndoes: true).action);     // Alt+Z / Win+Z: Windows'
    }

    [Fact]
    public void AltAndWindowsKeyCombinationsAreNeverOurs()
    {
        Assert.Equal(KeyAction.Pass, A(Tab, true, altOrWin: true));
        Assert.Equal(KeyAction.Pass, A(F9, true, altOrWin: true));
        Assert.Equal(KeyAction.Pass, A(P, true, altOrWin: true));
    }
}

public class LostKeyReleaseTests
{
    [Fact]
    public void ALostCtrlReleaseIsNoticedFromTheRealKeyState()
    {
        var m = new ModeController();
        m.CtrlDown();                 // ...then Windows swallowed the release (e.g. Ctrl+Alt+Del)
        Assert.True(m.Drawing);
        m.CtrlActuallyDown(false);
        Assert.False(m.Drawing);
    }

    [Fact]
    public void TheRealKeyStateNeverStartsDrawingAndLeavesF9Alone()
    {
        var m = new ModeController();
        m.CtrlActuallyDown(true);
        Assert.False(m.Drawing);
        m.Toggle(); m.CtrlActuallyDown(false);
        Assert.True(m.Drawing);
    }
}

public class PlacementTests
{
    // laptop 1920x1040 work area, projector to its right 1024x768
    static readonly Box Laptop = new(0, 0, 1920, 1040), Projector = new(1920, 0, 2944, 768);
    static readonly Box[] Both = { Laptop, Projector };

    [Fact]
    public void AToolbarOnTheProjectorStaysOnTheProjector()
        => Assert.Equal((2000, 10), Placement.KeepInside(new Box(2000, 10, 2870, 60), Both));

    [Fact]
    public void ARunOffOnTheProjectorIsPulledInOnTheProjector()
        => Assert.Equal((2944 - 870, 10), Placement.KeepInside(new Box(2100, 10, 2970, 60), Both));

    [Fact]
    public void ARunOffOnTheLaptopIsPulledInOnTheLaptop()
        => Assert.Equal((1920 - 870, 10), Placement.KeepInside(new Box(1500, 10, 2370, 60), new[] { Laptop }));

    [Fact]
    public void TheWindowsCheckCase1024Wide()
        => Assert.Equal((154, 8), Placement.KeepInside(new Box(182, 8, 1052, 58), new[] { new Box(0, 0, 1024, 768) }));

    [Fact]
    public void OffEveryScreenGoesToTheNearestOne()
        => Assert.Equal((Projector.Right - 870, 0), Placement.KeepInside(new Box(4000, -200, 4870, -150), Both));

    [Fact]
    public void NothingToDoLeavesItWhereItIs()
        => Assert.Equal((300, 40), Placement.KeepInside(new Box(300, 40, 1170, 90), Both));
}

public class ObsTests
{
    [Fact]
    public void PasswordAnswerMatchesTheProtocolsRecipe()
    {
        // the salt and challenge from obs-websocket's protocol.md example; the answer worked out separately in Python
        // (hashlib + base64), so this is not the C# checking itself
        Assert.Equal("1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=",
            Obs.Auth("supersecretpassword", "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=", "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY="));
    }

    static string AppData(Action<string> write)
    {
        var dir = Path.Combine(Path.GetTempPath(), "contrastink-obs-" + Guid.NewGuid());
        Directory.CreateDirectory(Path.Combine(dir, "obs-studio", "plugin_config", "obs-websocket"));
        write(Path.Combine(dir, "obs-studio"));
        return dir;
    }

    [Fact]
    public void ReadsObs30Settings()
    {
        var dir = AppData(obs => File.WriteAllText(Path.Combine(obs, "plugin_config", "obs-websocket", "config.json"),
            "{\"alerts_enabled\":false,\"auth_required\":true,\"first_load\":false,\"server_enabled\":true,\"server_password\":\"pw1\",\"server_port\":4466}"));
        Assert.Equal(new Obs.Connection(true, 4466, "pw1"), Obs.ReadConfig(dir));
    }

    [Fact]
    public void Obs30DefaultsAreOffAnd4455WithAPassword()
    {
        var dir = AppData(obs => File.WriteAllText(Path.Combine(obs, "plugin_config", "obs-websocket", "config.json"), "{}"));
        Assert.Equal(new Obs.Connection(false, 4455, ""), Obs.ReadConfig(dir));   // OBS's own defaults (src/Config.h)
    }

    [Fact]
    public void NoPasswordWhenObsAsksForNone()
    {
        var dir = AppData(obs => File.WriteAllText(Path.Combine(obs, "plugin_config", "obs-websocket", "config.json"),
            "{\"server_enabled\":true,\"auth_required\":false,\"server_password\":\"ignored\"}"));
        Assert.Null(Obs.ReadConfig(dir)!.Password);
    }

    [Fact]
    public void ReadsObs28GlobalIni()
    {
        var dir = AppData(obs => File.WriteAllText(Path.Combine(obs, "global.ini"),
            "[General]\nName=x\n\n[OBSWebSocket]\nFirstLoad=false\nServerEnabled=true\nServerPort=4455\nAuthRequired=true\nServerPassword=abc=def\n\n[Video]\nServerPort=1\n"));
        Assert.Equal(new Obs.Connection(true, 4455, "abc=def"), Obs.ReadConfig(dir));   // '=' inside a password survives
    }

    [Fact]
    public void Obs28WithoutAPassword()
    {
        var dir = AppData(obs => File.WriteAllText(Path.Combine(obs, "global.ini"), "[OBSWebSocket]\nServerEnabled=true\nAuthRequired=false\nServerPassword=x\n"));
        Assert.Equal(new Obs.Connection(true, 4455, null), Obs.ReadConfig(dir));
    }

    [Fact]
    public void NoObsSettingsIsNull() => Assert.Null(Obs.ReadConfig(Path.Combine(Path.GetTempPath(), "nothing-" + Guid.NewGuid())));

    [Fact]
    public void ChaptersStartAtZeroAndSkipQuickClicks()
    {
        var text = Obs.Chapters(new[] { (TimeSpan.FromSeconds(0.2), "Slide 1"), (TimeSpan.FromSeconds(65), "Slide 2"),
                                        (TimeSpan.FromSeconds(65.4), "Slide 3"), (TimeSpan.FromSeconds(130), "Slide 4") });
        Assert.Equal("0:00 Slide 1\n1:05 Slide 3\n2:10 Slide 4\n", text);
    }

    [Fact]
    public void ChaptersGetAStartLineAndHoursWhenNeeded()
    {
        Assert.Equal("0:00:00 Start\n0:05:00 Slide 2\n1:02:03 Slide 9\n",
            Obs.Chapters(new[] { (TimeSpan.FromMinutes(5), "Slide 2"), (new TimeSpan(1, 2, 3), "Slide 9") }));
        Assert.Equal("", Obs.Chapters(Array.Empty<(TimeSpan, string)>()));
    }

    [Theory]
    [InlineData(@"C:\a#b\Lecture.pptx#12", 12)]
    [InlineData(@"C:\a#b\Lecture.pptx#5#6", 6)]   // position 5 in the show is slide 6 (slide 5 hidden): the chapter is "Slide 6"
    [InlineData("", null)]
    [InlineData(@"C:\x.pptx#0", null)]
    public void SlideNumberFromTheWatchersKey(string key, int? n) => Assert.Equal(n, Obs.SlideNumber(key));
}

public class LaserAndOpacityTests
{
    [Fact]
    public void LaserLineStaysBrightThenFadesThenGoes()
    {
        Assert.Equal(1, Laser.Opacity(TimeSpan.Zero));
        Assert.Equal(1, Laser.Opacity(TimeSpan.FromMilliseconds(600)));
        Assert.Equal(0.5, Laser.Opacity(TimeSpan.FromMilliseconds(900)), 3);
        Assert.Equal(0, Laser.Opacity(TimeSpan.FromMilliseconds(1200)));
        Assert.Equal(0, Laser.Opacity(TimeSpan.FromSeconds(10)));
    }

    [Fact]
    public void LaserIsNeverThin() { Assert.Equal(8, Laser.Width(3)); Assert.Equal(16, Laser.Width(10)); }

    [Fact]
    public void LKeyPicksTheLaserOnlyWhileDrawing()
    {
        Assert.Equal(KeyAction.Laser, KeyPolicy.Decide(0x4C, drawing: true, ctrl: false, altOrWin: false).action);
        Assert.Equal(KeyAction.Pass, KeyPolicy.Decide(0x4C, drawing: false, ctrl: false, altOrWin: false).action);
    }

    [Theory]
    [InlineData(1.0, 1.0)] [InlineData(0.5, 0.5)] [InlineData(0.01, Settings.MinOpacity)] [InlineData(7, 1.0)]
    [InlineData(double.NaN, 1.0)] [InlineData(double.NegativeInfinity, 1.0)]
    public void OpacityStaysInRange(double saved, double used) =>
        Assert.Equal(used, new Settings { Opacity = saved }.Clean(1).Opacity);

    [Fact]
    public void OpacityAndLaserAreRemembered()
    {
        var path = Path.Combine(Path.GetTempPath(), $"ci-{Guid.NewGuid():N}.json");
        try
        {
            new Settings { Opacity = 0.4, Tool = Tool.Laser }.Save(path);
            var s = Settings.Load(path, 1);
            Assert.Equal((0.4, Tool.Laser), (s.Opacity, s.Tool));
            File.WriteAllText(path, "{\"Color\": 2}");   // saved by an older version
            Assert.Equal(1.0, Settings.Load(path, 1).Opacity);
        }
        finally { File.Delete(path); }
    }
}

public class PenTabletTests
{
    [Theory]
    [InlineData(TabletMode.Auto, 1, 0, true)]    // a Wacom Intuos or XP-Pen Deco alone: its pen is the mouse
    [InlineData(TabletMode.Auto, 0, 1, false)]   // a Cintiq, an XP-Pen Artist, a Surface: the pen stays a pen
    [InlineData(TabletMode.Auto, 1, 1, false)]   // both: the pen screen must keep working as before
    [InlineData(TabletMode.Auto, 0, 0, false)]   // none (or a tablet with Windows Ink off: it is the mouse already)
    [InlineData(TabletMode.On, 0, 1, true)]
    [InlineData(TabletMode.Off, 1, 0, false)]
    public void TabletPenIsTheMouseUnlessAPenScreenIsThere(TabletMode mode, int external, int integrated, bool mouse) =>
        Assert.Equal(mouse, PenTablet.UseAsMouse(mode, external, integrated));

    [Fact]
    public void ModeIsAutoUnlessChosenAndRemembered()
    {
        Assert.Equal(TabletMode.Auto, new Settings().PenTabletMode);
        Assert.Equal(TabletMode.Auto, new Settings { PenTabletMode = (TabletMode)9 }.Clean(1).PenTabletMode);
        var path = Path.Combine(Path.GetTempPath(), $"ci-{Guid.NewGuid():N}.json");
        try
        {
            new Settings { PenTabletMode = TabletMode.Off }.Save(path);
            Assert.Equal(TabletMode.Off, Settings.Load(path, 1).PenTabletMode);
            File.WriteAllText(path, "{\"Color\": 2, \"PenTablet\": true}");   // older versions (the first had a yes/no)
            var old = Settings.Load(path, 1);
            Assert.Equal((2, TabletMode.Auto), (old.Color, old.PenTabletMode));
        }
        finally { File.Delete(path); }
    }
}

/// <summary>The PC-tablet link (docs/pad-protocol.md): the same test bytes as the Android and iPad apps' tests.</summary>
public class PadProtocolTests
{
    static byte[] Hex(string h) => Convert.FromHexString(h.Replace(" ", ""));

    [Fact]
    public void SpecTestVectorsDecode()
    {
        var r = new PadReader();
        var all = Hex("01 00 00 00 2A").Concat(System.Text.Encoding.UTF8.GetBytes("{\"code\":\"123456\",\"device\":\"t\",\"version\":1}"))
            .Concat(Hex("10 00 00 00 09 3F 00 00 00 3E 80 00 00 00"))
            .Concat(Hex("11 00 00 00 12 00 02 3F 00 00 00 3F 00 00 00 3F 80 00 00 00 00 00 00"))
            .Concat(Hex("12 00 00 00 00")).Concat(Hex("20 00 00 00 04 75 6E 64 6F")).Concat(Hex("03 00 00 00 00")).ToArray();
        // arriving a few bytes at a time, as a network does
        var msgs = new List<(byte type, byte[] payload)>();
        for (int i = 0; i < all.Length; i += 3) msgs.AddRange(r.Add(all.AsSpan(i, Math.Min(3, all.Length - i))));
        Assert.Equal(new byte[] { Pad.Hello, Pad.StrokeBegin, Pad.StrokePoints, Pad.StrokeEnd, Pad.Command, Pad.FrameAck }, msgs.Select(m => m.type));
        Assert.Equal(("123456", "t"), Pad.ReadHello(msgs[0].payload));
        Assert.Equal((0.5f, 0.25f, false), Pad.ReadBegin(msgs[1].payload));
        Assert.Equal(new List<(float, float)> { (0.5f, 0.5f), (1f, 0f) }, Pad.ReadPoints(msgs[2].payload));
        Assert.Equal(new PadCommand(PadAction.Undo), Pad.ReadCommand(msgs[4].payload));
    }

    [Fact]
    public void MessagesAreTypeLengthPayload()
    {
        Assert.Equal(Hex("20 00 00 00 04 75 6E 64 6F"), Pad.Message(Pad.Command, "undo"));
        Assert.Equal(Hex("85 00 00 00 00"), Pad.Message(Pad.Pong, ReadOnlySpan<byte>.Empty));
    }

    [Fact]
    public void TooLongIsRefusedAndUnknownTypesPassThrough()
    {
        Assert.Throws<InvalidDataException>(() => new PadReader().Add(Hex("83 7F FF FF FF")));
        var m = new PadReader().Add(Hex("7E 00 00 00 02 AA BB 03 00 00 00 00"));
        Assert.Equal(new byte[] { 0x7E, Pad.FrameAck }, m.Select(x => x.type));
    }

    [Theory]
    [InlineData("tool:laser", PadAction.Tool, (int)Tool.Laser)] [InlineData("tool:OVAL", PadAction.Tool, (int)Tool.Oval)]
    [InlineData("color:2", PadAction.Color, 2)] [InlineData("width:0", PadAction.Width, 0)]
    [InlineData("next", PadAction.Next, 0)] [InlineData("fade:on", PadAction.Fade, 1)]
    public void CommandsAreUnderstood(string text, PadAction action, int value) =>
        Assert.Equal(new PadCommand(action, value), Pad.ReadCommand(System.Text.Encoding.UTF8.GetBytes(text)));

    [Theory]
    [InlineData("color:9")] [InlineData("tool:spraycan")] [InlineData("width:-1")] [InlineData("format c:")] [InlineData("opacity:NaN")]
    public void UnknownOrOutOfRangeCommandsAreIgnored(string text) =>
        Assert.Null(Pad.ReadCommand(System.Text.Encoding.UTF8.GetBytes(text)));

    [Fact]
    public void OpacityIsClampedAndCoordinatesStayOnTheScreen()
    {
        Assert.Equal(Settings.MinOpacity, Pad.ReadCommand(System.Text.Encoding.UTF8.GetBytes("opacity:0.01"))!.Value.Amount);
        Assert.Equal((1f, 0f, true), Pad.ReadBegin(Hex("40 00 00 00 FF C0 00 00 01")));   // 2.0 and NaN
    }

    [Fact]
    public void WelcomeAndStateAreJson()
    {
        var w = new PadReader().Add(Pad.WelcomeMessage("LAPTOP", 1920, 1080))[0];
        using var doc = System.Text.Json.JsonDocument.Parse(w.payload);
        Assert.Equal((Pad.Welcome, "LAPTOP", 1920, 1), (w.type, doc.RootElement.GetProperty("name").GetString(), doc.RootElement.GetProperty("screenW").GetInt32(), doc.RootElement.GetProperty("version").GetInt32()));
        var st = new PadReader().Add(Pad.StateMessage(new Settings { Tool = Tool.Laser, Color = 3 }, canUndo: true))[0];
        using var s = System.Text.Json.JsonDocument.Parse(st.payload);
        Assert.Equal(("laser", 3, true), (s.RootElement.GetProperty("tool").GetString(), s.RootElement.GetProperty("color").GetInt32(), s.RootElement.GetProperty("canUndo").GetBoolean()));
    }

    [Fact]
    public void CodesAreSixDigits() => Assert.All(Enumerable.Range(0, 50).Select(_ => Pad.NewCode()), c => Assert.Matches("^[0-9]{6}$", c));
}

/// <summary>What strangers on the same Wi-Fi can do before they know the code: nothing that harms the app.</summary>
public class PadSafetyTests
{
    static byte[] Hello(string json) => System.Text.Encoding.UTF8.GetBytes(json);

    [Theory]
    [InlineData("1")] [InlineData("[]")] [InlineData("\"x\"")] [InlineData("null")] [InlineData("{\"code\":5}")]
    [InlineData("{\"code\":\"\\uD800\"}")] [InlineData("{{{")] [InlineData("")]
    public void ABrokenHelloIsRefusedNeverThrown(string json)
    {
        var h = Pad.ReadHello(Hello(json));
        Assert.True(h == null || h.Value.code != "123456");
    }

    [Fact]
    public void AnOversizedHelloIsRefused() =>
        Assert.Null(Pad.ReadHello(Hello("{\"code\":\"123456\",\"device\":\"" + new string('x', 2000) + "\"}")));

    [Fact]
    public void TheDeviceNameIsShortAndPrintable() =>
        Assert.Equal("iPad", Pad.ReadHello(Hello("{\"code\":\"1\",\"device\":\"\\u0007iPad\\n\"}"))!.Value.device);

    [Fact]
    public void BeforeTheCodeAHugeLengthIsRefusedAtOnce()
    {
        var r = new PadReader { MaxLength = Pad.HelloMax };
        Assert.Throws<InvalidDataException>(() => r.Add(new byte[] { 0x01, 0x00, 0x00, 0x08, 0x00 }));   // 2048 bytes announced
    }

    [Fact]
    public void ManySmallMessagesInOneReadAllComeOut()
    {
        var all = Enumerable.Range(0, 5000).SelectMany(_ => Pad.Message(Pad.Ping, ReadOnlySpan<byte>.Empty)).ToArray();
        Assert.Equal(5000, new PadReader().Add(all).Count);
    }

    [Fact]
    public void FiveWrongCodesLockEveryoneOutForThirtySeconds()
    {
        var g = new PadGuard();
        var t = new DateTime(2026, 11, 12, 10, 0, 0, DateTimeKind.Utc);
        for (int i = 0; i < 4; i++) Assert.False(g.Wrong(t));
        Assert.False(g.Locked(t));
        g.Wrong(t);
        Assert.True(g.Locked(t.AddSeconds(29)));
        Assert.False(g.Locked(t.AddSeconds(31)));
    }

    [Fact]
    public void TwentyWrongCodesMakeANewCode()
    {
        var g = new PadGuard();
        var t = DateTime.UtcNow;
        int newCodes = 0;
        for (int i = 0; i < 40; i++) if (g.Wrong(t)) newCodes++;
        Assert.Equal(2, newCodes);
    }

    [Fact]
    public void TheRightCodeResetsTheRunButNotTheTotal()
    {
        var g = new PadGuard();
        var t = DateTime.UtcNow;
        for (int i = 0; i < 4; i++) g.Wrong(t);
        g.Right();
        for (int i = 0; i < 4; i++) g.Wrong(t);
        Assert.False(g.Locked(t));   // never five in a row
        for (int i = 0; i < 11; i++) g.Wrong(t);
        Assert.True(g.Wrong(t));     // the 20th wrong for this code
    }
}

/// <summary>Version 2 of the tablet link: the spec's test vectors and what an eavesdropper or a wrong code gets.</summary>
public class PadCryptoTests
{
    static readonly byte[] TabletD = Enumerable.Repeat((byte)0x11, 32).ToArray(), PcD = Enumerable.Repeat((byte)0x22, 32).ToArray();
    static readonly byte[] Salt = Convert.FromHexString("000102030405060708090A0B0C0D0E0F");

    static (byte[] toPc, byte[] toTablet) Both(string tabletCode, string pcCode, out (byte[], byte[]) pcSide)
    {
        using var t = PadCrypto.FromPrivate(TabletD);
        using var p = PadCrypto.FromPrivate(PcD);
        pcSide = PadCrypto.Keys(p, PadCrypto.ReadPoint(PadCrypto.PublicPoint(t))!, Salt, pcCode);
        return PadCrypto.Keys(t, PadCrypto.ReadPoint(PadCrypto.PublicPoint(p))!, Salt, tabletCode);
    }

    [Fact]
    public void BothSidesGetTheSameKeysWithTheSameCode()
    {
        var tablet = Both("123456", "123456", out var pc);
        Assert.Equal(pc.Item1, tablet.toPc);
        Assert.Equal(pc.Item2, tablet.toTablet);
        Assert.NotEqual(tablet.toPc, tablet.toTablet);
    }

    [Fact]
    public void AWrongCodeCantOpenTheProof()
    {
        var tablet = Both("123457", "123456", out var pc);
        using var seal = new PadSeal(tablet.toPc);
        using var open = new PadSeal(pc.Item1);
        Assert.Null(open.Open(seal.Seal(Pad.Message(Pad.Command, PadCrypto.ProofText))));
    }

    [Fact]
    public void SealedMessagesOpenOnceInOrderAndNotAltered()
    {
        var tablet = Both("123456", "123456", out var pc);
        using var seal = new PadSeal(tablet.toPc);
        using var open = new PadSeal(pc.Item1);
        var a = seal.Seal(Pad.Message(Pad.Command, "undo"));
        var b = seal.Seal(Pad.Message(Pad.Command, "next"));
        Assert.Equal(Pad.Message(Pad.Command, "undo"), open.Open(a));
        Assert.Null(open.Open(a));                                  // replayed
        var altered = (byte[])b.Clone(); altered[14] ^= 1;
        Assert.Null(open.Open(altered));                           // changed in flight
        Assert.Equal(Pad.Message(Pad.Command, "next"), open.Open(b));
    }

    [Fact]
    public void NotAPointIsRefused()
    {
        Assert.Null(PadCrypto.ReadPoint(new byte[65]));
        Assert.Null(PadCrypto.ReadPoint(new byte[] { 4, 1, 2 }));
    }

    /// <summary>Prints the vectors written into docs/pad-protocol.md (the Android and iPad tests assert them).</summary>
    [Fact]
    public void SpecVectors()
    {
        using var t = PadCrypto.FromPrivate(TabletD);
        using var p = PadCrypto.FromPrivate(PcD);
        var keys = Both("123456", "123456", out _);
        using var seal = new PadSeal(keys.toPc);
        var proof = seal.Seal(Pad.Message(Pad.Command, PadCrypto.ProofText));
        File.WriteAllText(Path.Combine(Path.GetTempPath(), "pad-v2-vectors.txt"),
            $"tablet public key   {Convert.ToHexString(PadCrypto.PublicPoint(t))}\n" +
            $"PC public key       {Convert.ToHexString(PadCrypto.PublicPoint(p))}\n" +
            $"tablet->PC key      {Convert.ToHexString(keys.toPc)}\n" +
            $"PC->tablet key      {Convert.ToHexString(keys.toTablet)}\n" +
            $"first sealed PROOF  {Convert.ToHexString(proof)}  (COMMAND \"hello\", counter 1)\n");
        Assert.Equal(65 + 0, PadCrypto.PublicPoint(t).Length + 0);
    }
}

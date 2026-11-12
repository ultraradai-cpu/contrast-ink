import XCTest
import Foundation
@testable import ContrastInkCore

final class ShapesTests: XCTestCase {
    func testArrowEndsAtTipWithTwoHeadSides() {
        let a = Shapes.arrow(from: Pt(0, 0), to: Pt(100, 0), width: 6)
        XCTAssertEqual(a.count, 5)
        XCTAssertEqual(a[0], Pt(0, 0)); XCTAssertEqual(a[1], Pt(100, 0)); XCTAssertEqual(a[3], Pt(100, 0))
        XCTAssertLessThan(a[2].x, 100); XCTAssertLessThan(a[4].x, 100)
        XCTAssertEqual(a[2].y, -a[4].y, accuracy: 1e-9)   // the head is symmetric
    }

    func testArrowHeadNeverPastHalfTheArrow() {
        let a = Shapes.arrow(from: Pt(0, 0), to: Pt(10, 0), width: 10)
        let back = 10 - a[2].x
        XCTAssertLessThanOrEqual(back, 5 + 1e-9)
    }

    func testTinyArrowIsJustTwoPoints() {
        XCTAssertEqual(Shapes.arrow(from: Pt(5, 5), to: Pt(5.5, 5), width: 3).count, 2)
    }

    func testOvalIsClosedAndInsideItsBox() {
        let o = Shapes.oval(Pt(100, 50), Pt(0, 0))
        XCTAssertEqual(o.first, o.last)
        for p in o {
            XCTAssertGreaterThanOrEqual(p.x, -1e-9); XCTAssertLessThanOrEqual(p.x, 100 + 1e-9)
            XCTAssertGreaterThanOrEqual(p.y, -1e-9); XCTAssertLessThanOrEqual(p.y, 50 + 1e-9)
        }
    }

    func testSquareKeepsStartCornerAndLargerSide() {
        XCTAssertEqual(Shapes.square(start: Pt(10, 10), end: Pt(40, 20)), Pt(40, 40))
        XCTAssertEqual(Shapes.square(start: Pt(10, 10), end: Pt(0, -30)), Pt(-30, -30))
        XCTAssertEqual(Shapes.square(start: Pt(0, 0), end: Pt(0, 0)), Pt(0, 0))
    }

    func testSharpCornersTriplesInnerPointsOnly() {
        let pts = [Pt(0, 0), Pt(1, 1), Pt(2, 0)]
        XCTAssertEqual(Shapes.sharpCorners(pts), [Pt(0, 0), Pt(1, 1), Pt(1, 1), Pt(1, 1), Pt(2, 0)])
        XCTAssertEqual(Shapes.sharpCorners([Pt(0, 0), Pt(1, 1)]).count, 2)
    }

    func testTapIsTooSmallForAShape() {
        XCTAssertTrue(Shapes.tooSmall(Pt(0, 0), Pt(3, 3)))
        XCTAssertFalse(Shapes.tooSmall(Pt(0, 0), Pt(10, 0)))
    }
}

final class FadeTests: XCTestCase {
    func testHoldsThenFadesThenGone() {
        XCTAssertEqual(Fade.opacity(age: 0), 1)
        XCTAssertEqual(Fade.opacity(age: 2), 1)
        XCTAssertEqual(Fade.opacity(age: 2.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Fade.opacity(age: 3), 0)
        XCTAssertEqual(Fade.opacity(age: 60), 0)
    }
}

final class ChaptersTests: XCTestCase {
    func testStartsAtZeroAndListsInOrder() {
        let t = Chapters.text([(0.4, "Slide 1"), (65, "Slide 2"), (130, "Slide 3")])
        XCTAssertEqual(t, "0:00 Slide 1\n1:05 Slide 2\n2:10 Slide 3\n")
    }

    func testAddsStartWhenFirstChapterIsLate() {
        XCTAssertEqual(Chapters.text([(12, "Slide 4")]), "0:00 Start\n0:12 Slide 4\n")
    }

    func testQuickClicksReplaceThePreviousChapter() {
        XCTAssertEqual(Chapters.text([(0, "Slide 1"), (10, "Slide 2"), (10.5, "Slide 3")]), "0:00 Slide 1\n0:10 Slide 3\n")
    }

    func testHoursOnEveryLineOnceVideoPassesAnHour() {
        XCTAssertEqual(Chapters.text([(0, "Slide 1"), (3725, "Slide 9")]), "0:00:00 Slide 1\n1:02:05 Slide 9\n")
    }

    func testEmptyAndOutOfOrder() {
        XCTAssertEqual(Chapters.text([]), "")
        XCTAssertEqual(Chapters.text([(20, "B"), (0, "A")]), "0:00 A\n0:20 B\n")
    }
}

final class TimelineTests: XCTestCase {
    /// A microphone buffer made just before ⏸ often arrives after ▶: written at its stamp, it would land before
    /// what's already in the video, and the video writer would stop for good (the whole recording lost).
    func testASampleMadeDuringThePauseIsLeftOutWhenItArrivesAfterResume() {
        var t = Timeline()
        t.begin(at: 100)
        XCTAssertEqual(t.videoTime(110), 10)
        t.pause(at: 110)
        t.resume(at: 120)
        XCTAssertNil(t.videoTime(115), "made during the pause, arrived late")
        XCTAssertNil(t.videoTime(109.99) .flatMap { $0 > 10 ? $0 : nil }, "nothing lands after the last written")
        XCTAssertEqual(t.videoTime(120.5)!, 10.5, accuracy: 1e-9)
    }

    func testEverySampleAfterResumeIsLaterThanEveryOneBefore() {
        var t = Timeline()
        t.begin(at: 0)
        var last = -1.0
        var forward = Forward()
        for stamp in stride(from: 0.0, through: 30, by: 0.02) {
            if stamp >= 10 && t.paused == false && stamp < 10.02 { t.pause(at: stamp) }
            if stamp >= 15 && t.paused { t.resume(at: stamp) }
            // a late buffer from the pause, delivered just after resume
            for s in [stamp, stamp - 3] {
                guard let v = t.videoTime(s), forward.admit(v) else { continue }
                XCTAssertGreaterThan(v, last); last = v
            }
        }
        XCTAssertEqual(last, 25, accuracy: 0.05)
    }

    func testPauseBeforeTheFirstPictureHoldsTheStart() {
        var t = Timeline()
        t.pause(at: 5)
        t.begin(at: 6)
        XCTAssertFalse(t.started, "paused before any picture: nothing starts")
        XCTAssertNil(t.videoTime(6))
        t.resume(at: 8)
        t.begin(at: 8.5)
        XCTAssertEqual(t.videoTime(9), 0.5)
        XCTAssertEqual(t.elapsed(at: 9), 0.5)
    }

    func testForwardDropsRepeatsAndGoingBack() {
        var f = Forward()
        XCTAssertTrue(f.admit(1)); XCTAssertFalse(f.admit(1)); XCTAssertFalse(f.admit(0.5)); XCTAssertTrue(f.admit(1.1))
    }

    func testPausedStretchesAreCutOut() {
        var t = Timeline()
        XCTAssertNil(t.videoTime(5))           // nothing before the first frame
        t.begin(at: 100)
        XCTAssertEqual(t.videoTime(110), 10)
        t.pause(at: 110)
        XCTAssertNil(t.videoTime(115))         // paused: frames left out
        XCTAssertEqual(t.elapsed(at: 115), 10)
        t.resume(at: 130)
        XCTAssertEqual(t.videoTime(131), 11)
        XCTAssertEqual(t.elapsed(at: 140), 20)
    }

    func testSecondBeginAndDoubleResumeAreIgnored() {
        var t = Timeline()
        t.begin(at: 10); t.begin(at: 50)
        XCTAssertEqual(t.start, 10)
        t.resume(at: 20); XCTAssertEqual(t.pausedTotal, 0)
        t.pause(at: 30); t.resume(at: 35); t.resume(at: 60)
        XCTAssertEqual(t.pausedTotal, 5)
    }
}

final class PageMarksTests: XCTestCase {
    func testEachSlideKeepsItsOwnMarks() {
        var m = PageMarks(empty: [Int]())
        m.commit([1]); m.commit([1, 2])
        m.show(page: 1)
        XCTAssertEqual(m.drawing, [])          // the next slide starts clean
        m.commit([9])
        m.show(page: 0)
        XCTAssertEqual(m.drawing, [1, 2])      // going back shows its marks again
        XCTAssertEqual(m.drawing(on: 1), [9])
    }

    func testUndoIsPerSlide() {
        var m = PageMarks(empty: [Int]())
        m.commit([1]); m.show(page: 1); m.commit([5])
        XCTAssertTrue(m.undo()); XCTAssertEqual(m.drawing, [])
        XCTAssertFalse(m.undo())
        m.show(page: 0)
        XCTAssertTrue(m.canUndo)
        XCTAssertTrue(m.undo()); XCTAssertEqual(m.drawing, [])
    }

    func testClearCanBeUndone() {
        var m = PageMarks(empty: [Int]())
        m.commit([1, 2]); m.clear()
        XCTAssertEqual(m.drawing, [])
        m.undo(); XCTAssertEqual(m.drawing, [1, 2])
    }

    func testQuietChangesAreNotUndoSteps() {
        var m = PageMarks(empty: [Int]())
        m.commit([1])
        m.replaceQuietly([])                   // a fading mark went away
        XCTAssertTrue(m.canUndo)
        m.commit([2])
        m.undo(); XCTAssertEqual(m.drawing, [])
    }

    func testUndoSkipsStepsThatOnlyBringBackFadedMarks() {
        var m = PageMarks(empty: [Int]())
        m.commit([7])                          // 7 is a fading mark
        m.commit([7, 8])
        m.replaceQuietly([8])                  // 7 faded away
        // undo: [7] would come back as [] after cleaning 7 out, which differs from [8]: that step is taken
        m.undo { $0.filter { $0 != 7 } }
        XCTAssertEqual(m.drawing, [])
        var n = PageMarks(empty: [Int]())
        n.commit([1]); n.commit([1, 7]); n.replaceQuietly([1])
        // undo: [1] (before 7) equals what is showing: skipped, the step before is taken
        n.undo { $0.filter { $0 != 7 } }
        XCTAssertEqual(n.drawing, [])
    }

    func testUnchangedCommitIsNotAStepAndHistoryIsCapped() {
        var m = PageMarks(empty: 0, historyLimit: 3)
        m.commit(0); XCTAssertFalse(m.canUndo)
        for i in 1...10 { m.commit(i) }
        var steps = 0
        while m.undo() { steps += 1 }
        XCTAssertEqual(steps, 3)
        XCTAssertEqual(m.drawing, 7)
    }

    func testResetForgetsEverySlide() {
        var m = PageMarks(empty: [Int]())
        m.commit([1]); m.show(page: 3); m.commit([2])
        m.reset()
        XCTAssertEqual(m.current, 0); XCTAssertEqual(m.drawing, []); XCTAssertEqual(m.drawing(on: 3), [])
    }
}

final class GeometryTests: XCTestCase {
    func testFitCentresTheSlide() {
        XCTAssertEqual(Fit.aspect(Size(4, 3), in: Size(1000, 600)), Rect(100, 0, 800, 600))
        XCTAssertEqual(Fit.aspect(Size(0, 3), in: Size(1000, 600)), Rect(0, 0, 0, 0))
    }

    func testCropFlipsToBottomLeftAndScalesToPixels() {
        // screen 1000×800 points recorded at 2000×1600 pixels; slide 900×600 starting 50 from the left, 150 down
        let r = Crop.pixelRect(stage: Rect(50, 150, 900, 600), screen: Size(1000, 800), image: Size(2000, 1600))
        XCTAssertEqual(r, Rect(100, 1600 - 300 - 1200, 1800, 1200))
    }

    func testCropIsEvenAndInsideTheFrame() {
        let r = Crop.pixelRect(stage: Rect(-10, 0, 1011, 801), screen: Size(1000, 800), image: Size(1000, 800))
        XCTAssertEqual(r.x, 0); XCTAssertEqual(r.y, 0)
        XCTAssertEqual(r.width, 1000); XCTAssertEqual(r.height, 800)
        let odd = Crop.pixelRect(stage: Rect(0, 0, 333, 251), screen: Size(1000, 800), image: Size(1000, 800))
        XCTAssertEqual(odd.width, 332); XCTAssertEqual(odd.height, 250)
    }

    func testOutputSizeScalesDownToEvenNumbers() {
        XCTAssertEqual(Crop.outputSize(Size(2360, 1770)), Size(1920, 1440))
        XCTAssertEqual(Crop.outputSize(Size(1200, 900)), Size(1200, 900))
        XCTAssertEqual(Crop.outputSize(Size(0, 900)), Size(0, 0))
    }
}

final class SettingsAndKeysTests: XCTestCase {
    func testDamagedOrOldSettingsAreSafe() {
        XCTAssertEqual(Settings.decode(nil), Settings())
        XCTAssertEqual(Settings.decode(Data("not json".utf8)), Settings())
        let s = Settings.decode(Data(#"{"color": 99, "width": -4, "tool": "laser", "fadingInk": true}"#.utf8))
        XCTAssertEqual(s.color, Settings.colors.count - 1)
        XCTAssertEqual(s.width, 0)
        XCTAssertEqual(s.tool, .pen)
        XCTAssertTrue(s.fadingInk)
    }

    func testSettingsRoundTrip() throws {
        var s = Settings(); s.tool = .oval; s.color = 3; s.fingerDraws = true
        XCTAssertEqual(Settings.decode(try JSONEncoder().encode(s)), s)
    }

    func testEveryKeyHasOneMeaning() {
        let keys = Keys.table.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testClickerKeysChangeSlidesAndLettersChooseTools() {
        XCTAssertEqual(Keys.action(for: "right"), .next)
        XCTAssertEqual(Keys.action(for: "pageDown"), .next)
        XCTAssertEqual(Keys.action(for: "pageUp"), .previous)
        XCTAssertEqual(Keys.action(for: "p"), .pen)
        XCTAssertEqual(Keys.action(for: "1"), .color(0))
        XCTAssertEqual(Keys.action(for: "6"), .color(5))
        XCTAssertNil(Keys.action(for: "7"))
        XCTAssertEqual(Settings.highlighterWidth(6), 30)
    }
}

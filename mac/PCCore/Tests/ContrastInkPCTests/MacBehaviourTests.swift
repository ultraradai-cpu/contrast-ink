// The Mac app's behaviour that needs no AppKit (the audit's findings): Hold Control, the chosen screen by its ID and
// the marks kept per screen, the cached marks' revision, quitting, the log, the toolbar's contrast.
import ContrastInkCore
import Foundation
import XCTest
@testable import ContrastInkPC

final class MacBehaviourTests: XCTestCase {
    // MARK: 1. Hold Control

    func testHoldControlIsOffByDefaultAndForOldCopies() {
        XCTAssertFalse(MacSettings().holdControlToDraw, "Control-click is the Mac's right-click: off by default")
        // a version-1 copy saved it on only because it was the default then
        let old = MacSettings.decode(Data("{\"holdControlToDraw\":true,\"undoWithZ\":false}".utf8), screens: 1)
        XCTAssertFalse(old.holdControlToDraw)
        XCTAssertFalse(old.undoWithZ, "the rest of an old copy is kept")
        // switched on by the presenter now: kept
        var s = MacSettings()
        s.holdControlToDraw = true
        XCTAssertTrue(MacSettings.decode(s.encoded(), screens: 1).holdControlToDraw)
    }

    func testControlStartsDrawingOnlyAfterBeingHeldAlone() {
        var h = ControlHold()
        XCTAssertNil(h.update(controlAlone: true, mouseDown: false, now: 0))
        XCTAssertNil(h.update(controlAlone: true, mouseDown: false, now: 0.2), "not yet: it may be a Control-click")
        XCTAssertEqual(h.update(controlAlone: true, mouseDown: false, now: 0.31), .start)
        XCTAssertNil(h.update(controlAlone: true, mouseDown: true, now: 0.5), "a click once drawing is drawing")
        XCTAssertEqual(h.update(controlAlone: false, mouseDown: false, now: 0.6), .stop)
    }

    func testControlClickAndControlDragPassThrough() {
        // Control-click: the button goes down before 300 ms
        var h = ControlHold()
        _ = h.update(controlAlone: true, mouseDown: false, now: 0)
        h.click()
        for t in stride(from: 0.04, to: 3, by: 0.04) {
            XCTAssertNil(h.update(controlAlone: true, mouseDown: t < 1, now: t), "Control still down after a click: no drawing at \(t)")
        }
        XCTAssertNil(h.update(controlAlone: false, mouseDown: false, now: 3))
        // held again afterwards: drawing starts as usual
        _ = h.update(controlAlone: true, mouseDown: false, now: 4)
        XCTAssertEqual(h.update(controlAlone: true, mouseDown: false, now: 4.31), .start)
        // Control pressed while a button is already down (a drag in Horos): no drawing
        var d = ControlHold()
        XCTAssertNil(d.update(controlAlone: true, mouseDown: true, now: 0))
        XCTAssertNil(d.update(controlAlone: true, mouseDown: false, now: 1))
        // Control with Shift or Command: not on its own
        var m = ControlHold()
        XCTAssertNil(m.update(controlAlone: false, mouseDown: false, now: 0))
        XCTAssertNil(m.update(controlAlone: false, mouseDown: false, now: 1))
        // drawing switched off another way (Esc) while Control is still down: not again until it is let go
        var e = ControlHold()
        _ = e.update(controlAlone: true, mouseDown: false, now: 0)
        XCTAssertEqual(e.update(controlAlone: true, mouseDown: false, now: 0.4), .start)
        e.stopped()
        XCTAssertNil(e.update(controlAlone: true, mouseDown: false, now: 2))
        XCTAssertNil(e.update(controlAlone: false, mouseDown: false, now: 2.1))
    }

    // MARK: 2. The chosen screen, by its ID

    func testTheChosenScreenComesBackAfterADropout() {
        let laptop = "LAPTOP-UUID", projector = "PROJECTOR-UUID"
        XCTAssertEqual(ScreenChoice.index(ids: [laptop, projector], chosenID: projector, savedIndex: 0), 1)
        // the projector drops out: the laptop for now
        XCTAssertEqual(ScreenChoice.index(ids: [laptop], chosenID: projector, savedIndex: 0), 0)
        // it returns (macOS may list it in another place): back to it
        XCTAssertEqual(ScreenChoice.index(ids: [projector, laptop], chosenID: projector, savedIndex: 0), 0)
        XCTAssertEqual(ScreenChoice.index(ids: [laptop, projector], chosenID: projector, savedIndex: 0), 1)
        // an older copy, chosen by index only
        XCTAssertEqual(ScreenChoice.index(ids: [laptop, projector], chosenID: nil, savedIndex: 1), 1)
        XCTAssertEqual(ScreenChoice.index(ids: [laptop], chosenID: nil, savedIndex: 1), 0)
        XCTAssertNil(ScreenChoice.index(ids: [], chosenID: projector, savedIndex: 0))
        XCTAssertEqual(ScreenChoice.next(ids: [laptop, projector], covered: 1), 0)
        XCTAssertNil(ScreenChoice.next(ids: [laptop], covered: 0))
        // the chosen screen's ID is saved, and repair (fewer screens) leaves it alone
        var s = MacSettings()
        s.screenID = projector
        s.screen = 1
        let back = MacSettings.decode(s.encoded(), screens: 1)
        XCTAssertEqual(back.screenID, projector)
        XCTAssertEqual(back.cleaned(screens: 1).screenID, projector)
    }

    func testMarksAreKeptPerScreenAndScaledWhenTheSizeChanges() {
        var marks = ScreenMarks()
        var board = marks.cover("P", width: 1920, height: 1080, board: InkBoard())
        board.add(InkMark(points: [Pt(960, 540), Pt(1920, 1080)], color: 0, width: 4))
        // the projector drops out: the laptop shows its own (none)
        let onLaptop = marks.cover("L", width: 1440, height: 900, board: board)
        XCTAssertTrue(onLaptop.isEmpty)
        // it returns: its marks are there, where they were
        let back = marks.cover("P", width: 1920, height: 1080, board: onLaptop)
        XCTAssertEqual(back.marks.first?.points, [Pt(960, 540), Pt(1920, 1080)])
        // the same screen at another resolution: the same fractions of it
        let smaller = marks.cover("P", width: 1280, height: 720, board: back)
        XCTAssertEqual(smaller.marks.first?.points, [Pt(640, 360), Pt(1280, 720)])
        XCTAssertEqual(smaller.marks.first?.width, 4, "lines keep their weight")
        // undo still brings back a mark erased before the change, at the new size
        var b = smaller
        XCTAssertTrue(b.erase(at: Pt(640, 360), radius: 4))
        b = marks.cover("P", width: 2560, height: 1440, board: b)
        XCTAssertTrue(b.undo(now: 0))
        XCTAssertEqual(b.marks.first?.points, [Pt(1280, 720), Pt(2560, 1440)])
    }

    // MARK: 6. The finished marks are drawn again only when they change

    func testBoardRevisionChangesOnlyWithTheMarks() {
        var b = InkBoard()
        var r = b.revision
        func changed(_ what: String, _ yes: Bool = true) {
            XCTAssertEqual(b.revision != r, yes, what)
            r = b.revision
        }
        b.add(InkMark(points: [Pt(0, 0), Pt(10, 0)], color: 0, width: 2)); changed("add")
        XCTAssertFalse(b.erase(at: Pt(500, 500), radius: 2)); changed("an eraser touching nothing", false)
        XCTAssertFalse(b.fade(now: 100)); changed("nothing faded", false)
        XCTAssertTrue(b.erase(at: Pt(5, 0), radius: 2)); changed("erase")
        XCTAssertTrue(b.undo(now: 0)); changed("undo")
        b.clear(); changed("clear")
        b.add(InkMark(points: [Pt(0, 0)], color: 0, width: 2, fadingSince: 0)); changed("add")
        XCTAssertTrue(b.fade(now: 60)); changed("faded away")
        _ = b.scaled(x: 1, y: 1); changed("the same size", false)
    }

    func testOnlyTheLiveStrokesNewPartIsDrawnAgain() {
        let pts = [Pt(10, 10), Pt(20, 15), Pt(30, 40), Pt(35, 42)]
        XCTAssertEqual(InkArea.fresh(pts, drawn: 3, wholeShape: false), [Pt(30, 40), Pt(35, 42)])
        XCTAssertEqual(InkArea.fresh(pts, drawn: 3, wholeShape: true), pts)
        XCTAssertEqual(InkArea.fresh(pts, drawn: 0, wholeShape: false), pts)
        let r = InkArea.bounds([Pt(30, 40), Pt(35, 42)], pad: 3)!
        XCTAssertEqual(r.x, 27); XCTAssertEqual(r.y, 37); XCTAssertEqual(r.width, 11); XCTAssertEqual(r.height, 8)
        XCTAssertNil(InkArea.bounds([], pad: 1))
    }

    // MARK: 7. The log, and what the toolbar says without Screen Recording

    func testScreenRecordingTextIsTrueOnRecentMacOS() {
        // macOS 14+ gives no picture at all without the permission, not the desktop picture
        XCTAssertFalse(MacTexts.screenRecordingMissing.contains("desktop"))
        XCTAssertFalse(MacTexts.screenRecordingForTablet.contains("desktop"))
        XCTAssertTrue(MacTexts.screenRecordingMissing.contains("no picture"))
    }

    func testFailuresAreSaidOncePerConnection() {
        var once = OnceEach()
        XCTAssertTrue(once.first("picture"))
        for _ in 0..<100 { XCTAssertFalse(once.first("picture")) }
        once.reset()
        XCTAssertTrue(once.first("picture"), "a new connection: said again, once")
    }

    func testTheLogIsRotated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ci-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Contrast Ink.log")
        let line = String(repeating: "x", count: 99) + "\n"
        for _ in 0..<35 { LogFile.append(line, to: url, maxBytes: 1000) }
        let size = { (u: URL) in ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.intValue ?? -1 }
        XCTAssertLessThanOrEqual(size(url), 1000, "the log stays under its limit")
        XCTAssertEqual(size(LogFile.oldURL(url)), 1000, "one old file")
        XCTAssertEqual(LogFile.oldURL(url).lastPathComponent, "Contrast Ink.old.log")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["Contrast Ink.log", "Contrast Ink.old.log"], "never more than one old file")
        XCTAssertEqual(LogFile.maxBytes, 1_000_000)
    }

    // MARK: 8. ✕ asks first when quitting would lose something

    func testQuitAsksWhenSomethingWouldBeLost() {
        XCTAssertNil(QuitCheck.question(marks: 0, recording: false, tablet: false), "nothing to lose: quits at once")
        XCTAssertEqual(QuitCheck.question(marks: 1, recording: false, tablet: false), "Quit Contrast Ink? The mark on the screen goes.")
        XCTAssertEqual(QuitCheck.question(marks: 3, recording: true, tablet: true),
                       "Quit Contrast Ink? The 3 marks on the screen go, OBS goes on recording without Contrast Ink's ⏹ and the tablet is disconnected.")
        XCTAssertNotNil(QuitCheck.question(marks: 0, recording: true, tablet: false))
        XCTAssertNotNil(QuitCheck.question(marks: 0, recording: false, tablet: true))
    }

    // MARK: 9. The toolbar's colours meet WCAG AA

    func testToolbarColoursMeetWcagAA() {
        let bar = MacPalette.bar, hover = MacPalette.hover
        XCTAssertEqual(Contrast.ratio("#FFFFFF", "#000000"), 21, accuracy: 0.01)
        // text on the bar and on a button under the pointer
        for (name, c) in [("ink", MacPalette.ink), ("grey", MacPalette.grey), ("warning", MacPalette.warning),
                          ("amber", MacPalette.amber), ("record red", MacPalette.recRed), ("laser ●", MacPalette.laserGlyph),
                          ("grip dots", MacPalette.blueText)] {
            XCTAssertGreaterThanOrEqual(Contrast.ratio(c, bar), 4.5, "\(name) on the bar")
            XCTAssertGreaterThanOrEqual(Contrast.ratio(c, hover), 4.5, "\(name) under the pointer")
        }
        // white text on a chosen (blue) button
        XCTAssertGreaterThanOrEqual(Contrast.ratio("#FFFFFF", MacPalette.blue), 4.5)
        // the chosen colour's ring: a state, not text (3:1)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(MacPalette.blue, bar), 3)
        // the colours that failed before
        XCTAssertLessThan(Contrast.ratio("#8A95A6", Contrast.blend("#E3E8F0", over: bar, alpha: 0.2)), 4.5)
        XCTAssertLessThan(Contrast.ratio("#2563EB", bar), 4.5)
    }
}

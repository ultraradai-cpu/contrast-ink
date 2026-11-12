import ContrastInkCore
import Foundation
import XCTest
@testable import ContrastInkPC

final class InkTests: XCTestCase {
    private func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, fading: Double? = nil) -> InkMark {
        InkMark(points: [Pt(x0, y0), Pt(x1, y1)], color: 0, width: 6, fadingSince: fading)
    }

    func testAddUndoClear() {
        var b = InkBoard()
        XCTAssertFalse(b.canUndo)
        b.add(line(0, 0, 10, 10))
        b.add(line(0, 50, 10, 50))
        XCTAssertEqual(b.marks.count, 2)
        XCTAssertEqual(Set(b.marks.map(\.id)).count, 2)
        b.clear()
        XCTAssertTrue(b.isEmpty)
        XCTAssertTrue(b.undo(now: 0))   // brings the clear back
        XCTAssertEqual(b.marks.count, 2)
        XCTAssertTrue(b.undo(now: 0))
        XCTAssertEqual(b.marks.count, 1)
        XCTAssertTrue(b.undo(now: 0))
        XCTAssertTrue(b.isEmpty)
        XCTAssertFalse(b.undo(now: 0))
    }

    func testEraserAndItsUndo() {
        var b = InkBoard()
        b.add(line(0, 0, 100, 0))
        b.add(line(0, 100, 100, 100))
        XCTAssertFalse(b.erase(at: Pt(50, 50), radius: 8))
        XCTAssertTrue(b.erase(at: Pt(50, 9), radius: 8))   // within 8 + half the width
        XCTAssertEqual(b.marks.count, 1)
        XCTAssertEqual(b.marks[0].points[0].y, 100)
        XCTAssertTrue(b.undo(now: 0))
        XCTAssertEqual(b.marks.map { $0.points[0].y }, [0, 100], "back in the order they were drawn")
    }

    func testFadingMarksGoAndUndoSkipsThem() {
        var b = InkBoard()
        b.add(line(0, 0, 10, 0))
        b.add(line(0, 10, 10, 10, fading: 0))
        XCTAssertTrue(b.anyFading)
        XCTAssertEqual(b.marks[1].alpha(at: 1), 1)
        XCTAssertEqual(b.marks[1].alpha(at: 2.5), 0.5, accuracy: 1e-9)
        XCTAssertFalse(b.fade(now: 2.9))
        XCTAssertTrue(b.fade(now: 3.1))
        XCTAssertEqual(b.marks.count, 1)
        // the faded mark's step is skipped: undo takes the one before it
        XCTAssertTrue(b.canUndo)
        XCTAssertTrue(b.undo(now: 4))
        XCTAssertTrue(b.isEmpty)
    }

    func testClearedFadingMarkComesBackFadingFromNow() {
        var b = InkBoard()
        b.add(line(0, 0, 10, 0, fading: 0))
        b.clear()
        XCTAssertTrue(b.undo(now: 10))
        XCTAssertEqual(b.marks[0].fadingSince, 10)
        XCTAssertEqual(b.marks[0].alpha(at: 11), 1)
    }

    func testHistoryIsBounded() {
        var b = InkBoard()
        for i in 0..<(InkBoard.historyLimit + 20) { b.add(line(Double(i), 0, Double(i), 10)) }
        var n = 0
        while b.undo(now: 0) { n += 1 }
        XCTAssertEqual(n, InkBoard.historyLimit)
    }

    func testStrokeShapesAndStyle() throws {
        var pen = InkStroke(tool: .pen, start: Pt(0, 0), pressure: 0.5)
        pen.add(Pt(0.1, 0), pressure: 0.6)   // too close: skipped
        pen.add(Pt(5, 5), pressure: 1)
        let m = try XCTUnwrap(pen.mark(color: 2, width: 6, opacity: 0.5, fadingSince: nil))
        XCTAssertEqual(m.points, [Pt(0, 0), Pt(5, 5)])
        XCTAssertEqual(m.pressures, [0.5, 1])
        XCTAssertEqual(m.width(at: 0), 6 * 0.9, accuracy: 1e-9)
        XCTAssertEqual(m.width(at: 1), 6 * 1.4, accuracy: 1e-9)
        XCTAssertEqual(m.alpha(at: 0), 0.5)

        var hl = InkStroke(tool: .highlighter, start: Pt(0, 0))
        hl.add(Pt(50, 0))
        let h = try XCTUnwrap(hl.mark(color: 1, width: 6, opacity: 0.5, fadingSince: nil))
        XCTAssertTrue(h.highlighter)
        XCTAssertEqual(h.width, Settings.highlighterWidth(6))
        XCTAssertEqual(h.alpha(at: 0), InkMark.highlighterAlpha)

        var arrow = InkStroke(tool: .arrow, start: Pt(0, 0))
        arrow.add(Pt(50, 0)); arrow.add(Pt(100, 0))
        XCTAssertEqual(arrow.points(width: 6), Shapes.arrow(from: Pt(0, 0), to: Pt(100, 0), width: 6))

        var oval = InkStroke(tool: .oval, start: Pt(0, 0))
        oval.add(Pt(100, 40))
        let circle = oval.points(width: 6, square: true)
        XCTAssertEqual(circle, Shapes.oval(Pt(0, 0), Pt(100, 100)))

        var tap = InkStroke(tool: .oval, start: Pt(10, 10))
        tap.add(Pt(12, 11))
        XCTAssertTrue(tap.tooSmall)
        XCTAssertNil(tap.mark(color: 0, width: 6, opacity: 1, fadingSince: nil))
        XCTAssertNil(InkStroke(tool: .laser, start: Pt(0, 0)).mark(color: 0, width: 6, opacity: 1, fadingSince: nil))
    }

    func testGeometryAndColours() throws {
        XCTAssertEqual(Ink.distance(Pt(5, 5), segment: Pt(0, 0), Pt(10, 0)), 5)
        XCTAssertEqual(Ink.distance(Pt(-3, 4), segment: Pt(0, 0), Pt(10, 0)), 5)
        XCTAssertEqual(Ink.distance(Pt(1, 1), segment: Pt(0, 0), Pt(0, 0)), 2.0.squareRoot(), accuracy: 1e-12)
        let red = try XCTUnwrap(Ink.rgb(Settings.colors[0]))
        XCTAssertEqual(red.r, 1); XCTAssertEqual(red.g, 0x3B / 255.0, accuracy: 1e-12)
        XCTAssertNil(Ink.rgb("#12"))
        for c in Settings.colors { XCTAssertNotNil(Ink.rgb(c)) }
        XCTAssertNotNil(Ink.rgb(Laser.color))
    }

    func testLaserTrail() {
        var l = LaserTrail()
        XCTAssertFalse(l.showing)
        l.move(Pt(1, 1), touching: false, at: 0)
        XCTAssertTrue(l.showing)
        XCTAssertTrue(l.segments(now: 0).isEmpty)
        l.down(Pt(0, 0), at: 0)
        l.move(Pt(10, 0), touching: true, at: 0.1)
        l.down(Pt(50, 50), at: 0.2)   // a new line: not joined to the last
        l.move(Pt(60, 50), touching: true, at: 0.3)
        XCTAssertEqual(l.segments(now: 0.3).count, 2)
        XCTAssertEqual(l.segments(now: 1.2).last!.alpha, 0.5, accuracy: 1e-9)
        l.hideDot()
        XCTAssertNil(l.dot)
        XCTAssertTrue(l.prune(now: 1.25))
        XCTAssertFalse(l.prune(now: 2))
        XCTAssertFalse(l.showing)
    }
}

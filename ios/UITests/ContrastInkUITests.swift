import UIKit
import XCTest

/// Runs the real app on a simulated iPad with a two-page sample deck, draws with a finger (the simulator has no
/// Pencil), counts the marks after every step, and keeps a screenshot of every step for a person to look at.
final class ContrastInkUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait   // landscape screenshots come out turned and cut off
        app = XCUIApplication()   // each test launches it with its own arguments
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// A drag on the slide. The 4:3 sample slides sit in the middle of a portrait iPad, from about 28% to 80% of
    /// the screen's height: every drag here starts and ends between 38% and 72%, well inside the slide.
    private func drag(_ from: CGVector, _ to: CGVector) {
        let a = app.coordinate(withNormalizedOffset: from), b = app.coordinate(withNormalizedOffset: to)
        a.press(forDuration: 0.1, thenDragTo: b, withVelocity: 600, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.6)
    }

    private var marks: Int { Int(app.staticTexts["markCount"].label) ?? -1 }

    private func expectMarks(_ n: Int, _ what: String) {
        XCTAssertEqual(marks, n, what)
    }

    func testDrawSlidesUndoAndShapes() {
        app.launchArguments = ["-uitest"]
        app.launch()
        let number = app.staticTexts["slideNumber"]
        XCTAssertTrue(number.waitForExistence(timeout: 10), "the presenter opens on the sample deck")
        XCTAssertEqual(number.label, "1 / 2")
        expectMarks(0, "a new deck starts clean")
        shot("01 slide 1")

        drag(CGVector(dx: 0.15, dy: 0.40), CGVector(dx: 0.8, dy: 0.70))
        expectMarks(1, "pen: one line")
        shot("02 red line on slide 1")

        app.buttons["next"].tap()
        XCTAssertEqual(number.label, "2 / 2")
        expectMarks(0, "the next slide starts clean")
        shot("03 slide 2 starts clean")

        app.buttons["Black (6)"].tap()
        drag(CGVector(dx: 0.2, dy: 0.70), CGVector(dx: 0.7, dy: 0.40))
        expectMarks(1, "black line on slide 2")
        shot("04 black line on slide 2")

        app.buttons["previous"].tap()
        XCTAssertEqual(number.label, "1 / 2")
        expectMarks(1, "back on slide 1: its line is back, slide 2's isn't")
        shot("05 back on slide 1, its red line is back")

        app.buttons["undo"].tap()
        Thread.sleep(forTimeInterval: 0.4)
        expectMarks(0, "undo takes the line")
        shot("06 undo took the red line")

        app.buttons["Red (1)"].tap()
        app.buttons["Arrow (A)"].tap()
        drag(CGVector(dx: 0.15, dy: 0.70), CGVector(dx: 0.45, dy: 0.45))
        expectMarks(1, "arrow: one mark")
        shot("07 arrow")

        app.buttons["Circle (O)"].tap()
        drag(CGVector(dx: 0.55, dy: 0.42), CGVector(dx: 0.88, dy: 0.66))
        expectMarks(2, "circle: one more mark")
        shot("08 circle")

        app.buttons["Highlighter (H)"].tap()
        drag(CGVector(dx: 0.1, dy: 0.56), CGVector(dx: 0.5, dy: 0.56))
        expectMarks(3, "highlighter: one more mark")
        shot("09 highlighter")

        app.buttons["Laser pointer (L)"].tap()
        drag(CGVector(dx: 0.15, dy: 0.62), CGVector(dx: 0.85, dy: 0.62))
        expectMarks(3, "laser: never a mark")
        shot("09b laser")
        app.buttons["Pen (P)"].tap()

        app.buttons["Clear all marks (C)"].tap()
        Thread.sleep(forTimeInterval: 0.4)
        expectMarks(0, "clear removes every mark")
        shot("10 cleared")
        app.buttons["undo"].tap()
        Thread.sleep(forTimeInterval: 0.4)
        expectMarks(3, "undo brings the cleared marks back")
        shot("11 undo brings the cleared marks back")
    }

    // MARK: pad mode

    /// The iPad as a PC's drawing pad, against a pretend PC in this test runner: the code goes in HELLO, the PC's
    /// picture is shown and acknowledged, a drag becomes a stroke in fractions of the picture, and Undo is a COMMAND.
    func testPadModeAgainstAFakePC() throws {
        let pc = FakePC()
        XCTAssertTrue(pc.start(), "the fake PC listens on the loopback")
        defer { pc.stop() }
        app.launchArguments = ["-padTest", "127.0.0.1:\(pc.port)", "123456"]
        app.launch()

        let hello = try XCTUnwrap(pc.waitFor(0x01, timeout: 20), "the app connects and says HELLO")
        XCTAssertEqual(hello, 0, "HELLO is the first message")
        let h = try XCTUnwrap(JSONSerialization.jsonObject(with: pc.messages[hello].payload) as? [String: Any])
        XCTAssertEqual(h["code"] as? String, "123456")
        XCTAssertEqual(h["version"] as? Int, 1)
        XCTAssertNotNil(h["device"] as? String)

        pc.send(0x81, json: #"{"name":"TEST-PC","screenW":1600,"screenH":900,"version":1}"#)
        pc.send(0x84, json: #"{"tool":"pen","color":0,"width":2,"opacity":1.0,"fading":false,"canUndo":true}"#)
        let before = pc.messages.count
        pc.send(0x83, Self.testScreen())
        XCTAssertNotNil(pc.waitFor(0x03, after: before), "FRAME_ACK once the picture is on screen")
        XCTAssertTrue(app.buttons["Pen"].waitForExistence(timeout: 5), "the pad's toolbar")
        Thread.sleep(forTimeInterval: 0.5)
        shot("P1 pad: the PC's screen")

        // a drag across the picture, from 20%, 30% to 70%, 60% of it
        let picture = app.descendants(matching: .any)["padPicture"]
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        let start = pc.messages.count
        let a = picture.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
        let b = picture.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))
        a.press(forDuration: 0.1, thenDragTo: b, withVelocity: 600, thenHoldForDuration: 0.1)
        shot("P2 the stroke as the iPad draws it")
        let endAt = try XCTUnwrap(pc.waitFor(0x12, after: start), "STROKE_END after the drag")
        let stroke = Array(pc.messages[start...endAt])
        let begin = try XCTUnwrap(stroke.first { $0.type == 0x10 }, "STROKE_BEGIN")
        XCTAssertEqual(begin.payload.count, 9)
        XCTAssertEqual(FakePC.f32(begin.payload, at: 0), 0.2, accuracy: 0.05, "begins where the drag began (x)")
        XCTAssertEqual(FakePC.f32(begin.payload, at: 4), 0.3, accuracy: 0.05, "begins where the drag began (y)")
        XCTAssertEqual(begin.payload.last, 0, "the tip, not the eraser end")
        let points = stroke.filter { $0.type == 0x11 }.flatMap { FakePC.points($0.payload) }
        XCTAssertGreaterThan(points.count, 2, "STROKE_POINTS along the way")
        XCTAssertTrue(points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }, "every point on the screen")
        if let last = points.last {
            XCTAssertEqual(last.x, 0.7, accuracy: 0.05, "ends where the drag ended (x)")
            XCTAssertEqual(last.y, 0.6, accuracy: 0.05, "ends where the drag ended (y)")
        }
        XCTAssertFalse(stroke.contains { $0.type == 0x13 }, "one finger: no STROKE_CANCEL")
        Thread.sleep(forTimeInterval: 1)
        shot("P3 the iPad lets its stroke go (the PC's picture has it)")

        let beforeUndo = pc.messages.count
        app.buttons["padUndo"].tap()
        XCTAssertNotNil(pc.waitFor(0x20, after: beforeUndo, where: { String(decoding: $0.payload, as: UTF8.self) == "undo" }),
                        "Undo sends COMMAND undo")
        let beforeCircle = pc.messages.count
        app.buttons["Circle"].tap()
        XCTAssertNotNil(pc.waitFor(0x20, after: beforeCircle, where: { String(decoding: $0.payload, as: UTF8.self) == "tool:oval" }),
                        "Circle sends COMMAND tool:oval")
        pc.send(0x84, json: #"{"tool":"oval","color":3,"width":2,"opacity":1.0,"fading":false,"canUndo":false}"#)
        Thread.sleep(forTimeInterval: 0.5)
        shot("P4 the PC says circle and cyan: the toolbar follows")
        XCTAssertNotNil(pc.waitFor(0x02, timeout: 5), "PING every 2 s")
    }

    /// A stand-in for a PC's screen: a dark slide with a title bar and a grid, 1600 x 900 like a FRAME.
    static func testScreen() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 900), format: format).image { ctx in
            UIColor(red: 0.08, green: 0.1, blue: 0.14, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
            UIColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 120))
            UIColor.white.withAlphaComponent(0.25).setFill()
            for i in 1..<8 { ctx.fill(CGRect(x: i * 200, y: 120, width: 2, height: 780)) }
            ("The PC's screen" as NSString).draw(at: CGPoint(x: 60, y: 30),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 56), .foregroundColor: UIColor.white])
        }
        return img.jpegData(compressionQuality: 0.8) ?? Data()
    }
}

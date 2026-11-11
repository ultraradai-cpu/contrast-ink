import XCTest

/// Runs the real app on a simulated iPad with a two-page sample deck, draws with a finger (the simulator has no
/// Pencil), counts the marks after every step, and keeps a screenshot of every step for a person to look at.
final class ContrastInkUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait   // landscape screenshots come out turned and cut off
        app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// A drag on the slide. The sample slides are 4:3 at the top of a portrait iPad, below the toolbar:
    /// every drag here stays between 10% and 45% of the screen's height, well inside the slide.
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
        let number = app.staticTexts["slideNumber"]
        XCTAssertTrue(number.waitForExistence(timeout: 10), "the presenter opens on the sample deck")
        XCTAssertEqual(number.label, "1 / 2")
        expectMarks(0, "a new deck starts clean")
        shot("01 slide 1")

        drag(CGVector(dx: 0.15, dy: 0.15), CGVector(dx: 0.8, dy: 0.42))
        expectMarks(1, "pen: one line")
        shot("02 red line on slide 1")

        app.buttons["next"].tap()
        XCTAssertEqual(number.label, "2 / 2")
        expectMarks(0, "the next slide starts clean")
        shot("03 slide 2 starts clean")

        app.buttons["Black (6)"].tap()
        drag(CGVector(dx: 0.2, dy: 0.42), CGVector(dx: 0.7, dy: 0.15))
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
        drag(CGVector(dx: 0.15, dy: 0.42), CGVector(dx: 0.45, dy: 0.2))
        expectMarks(1, "arrow: one mark")
        shot("07 arrow")

        app.buttons["Circle (O)"].tap()
        drag(CGVector(dx: 0.55, dy: 0.12), CGVector(dx: 0.88, dy: 0.38))
        expectMarks(2, "circle: one more mark")
        shot("08 circle")

        app.buttons["Highlighter (H)"].tap()
        drag(CGVector(dx: 0.1, dy: 0.3), CGVector(dx: 0.5, dy: 0.3))
        expectMarks(3, "highlighter: one more mark")
        shot("09 highlighter")

        app.buttons["Clear all marks (C)"].tap()
        Thread.sleep(forTimeInterval: 0.4)
        expectMarks(0, "clear removes every mark")
        shot("10 cleared")
        app.buttons["undo"].tap()
        Thread.sleep(forTimeInterval: 0.4)
        expectMarks(3, "undo brings the cleared marks back")
        shot("11 undo brings the cleared marks back")
    }
}

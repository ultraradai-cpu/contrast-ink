import XCTest

/// Runs the real app on a simulated iPad with a two-page sample deck, draws with a finger (the simulator has no
/// Pencil), and keeps a screenshot of every step for a person to look at (CI uploads them).
final class ContrastInkUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func drag(_ from: CGVector, _ to: CGVector) {
        let a = app.coordinate(withNormalizedOffset: from), b = app.coordinate(withNormalizedOffset: to)
        a.press(forDuration: 0.05, thenDragTo: b)
        Thread.sleep(forTimeInterval: 0.5)
    }

    func testDrawSlidesUndoAndShapes() {
        let number = app.staticTexts["slideNumber"]
        XCTAssertTrue(number.waitForExistence(timeout: 10), "the presenter opens on the sample deck")
        XCTAssertEqual(number.label, "1 / 2")
        shot("01 slide 1")

        drag(CGVector(dx: 0.25, dy: 0.45), CGVector(dx: 0.7, dy: 0.6))
        shot("02 red line on slide 1")

        app.buttons["next"].tap()
        XCTAssertEqual(number.label, "2 / 2")
        shot("03 slide 2 starts clean")

        app.buttons["Black (6)"].tap()
        drag(CGVector(dx: 0.3, dy: 0.7), CGVector(dx: 0.6, dy: 0.4))
        shot("04 black line on slide 2")

        app.buttons["previous"].tap()
        XCTAssertEqual(number.label, "1 / 2")
        shot("05 back on slide 1, its red line is back")

        app.buttons["undo"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        shot("06 undo took the red line")

        app.buttons["Red (1)"].tap()
        app.buttons["Arrow (A)"].tap()
        drag(CGVector(dx: 0.2, dy: 0.8), CGVector(dx: 0.5, dy: 0.5))
        shot("07 arrow")

        app.buttons["Circle (O)"].tap()
        drag(CGVector(dx: 0.6, dy: 0.35), CGVector(dx: 0.85, dy: 0.65))
        shot("08 circle")

        app.buttons["Highlighter (H)"].tap()
        drag(CGVector(dx: 0.1, dy: 0.3), CGVector(dx: 0.5, dy: 0.3))
        shot("09 highlighter")

        app.buttons["Clear all marks (C)"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        shot("10 cleared")
        app.buttons["undo"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        shot("11 undo brings the cleared marks back")
    }
}

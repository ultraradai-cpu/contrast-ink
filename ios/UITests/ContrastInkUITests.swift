import CryptoKit
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
        app.launchArguments = ["-uitest", "-resetMarks"]
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

    // MARK: keys, saved marks, closing, recording, importing

    private func launchSample(reset: Bool = true) {
        app.launchArguments = reset ? ["-uitest", "-resetMarks"] : ["-uitest"]
        app.launch()
        XCTAssertTrue(app.staticTexts["slideNumber"].waitForExistence(timeout: 10), "the presenter opens on the sample deck")
    }

    private func key(_ k: String) {
        app.typeKey(k, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// A hardware keyboard or a presenter clicker: the slide keys, and the letters for every tool (L the laser).
    func testKeys() {
        launchSample()
        let number = app.staticTexts["slideNumber"]
        XCTAssertEqual(number.label, "1 / 2")
        key(XCUIKeyboardKey.rightArrow.rawValue); XCTAssertEqual(number.label, "2 / 2", "→ next")
        key(XCUIKeyboardKey.leftArrow.rawValue); XCTAssertEqual(number.label, "1 / 2", "← previous")
        key(" "); XCTAssertEqual(number.label, "2 / 2", "Space next")
        key(XCUIKeyboardKey.upArrow.rawValue); XCTAssertEqual(number.label, "1 / 2", "↑ previous")
        key(XCUIKeyboardKey.downArrow.rawValue); XCTAssertEqual(number.label, "2 / 2", "↓ next")
        key(XCUIKeyboardKey.pageUp.rawValue); XCTAssertEqual(number.label, "1 / 2", "Page Up previous")
        key(XCUIKeyboardKey.return.rawValue); XCTAssertEqual(number.label, "2 / 2", "Return next (a clicker)")
        key(XCUIKeyboardKey.pageUp.rawValue)
        shot("K0 keys changed the slides")

        for (k, name) in [("h", "Highlighter (H)"), ("a", "Arrow (A)"), ("o", "Circle (O)"), ("e", "Eraser (E)"),
                          ("l", "Laser pointer (L)"), ("p", "Pen (P)")] {
            key(k)
            XCTAssertTrue(app.buttons[name].isSelected, "\(k.uppercased()) chooses \(name)")
        }
        key("3"); XCTAssertTrue(app.buttons["Green (3)"].isSelected, "3: green")
        key("["); XCTAssertTrue(app.buttons["Medium line"].isSelected, "[ thinner")
        key("]"); XCTAssertTrue(app.buttons["Thick line"].isSelected, "] thicker")
        key("f"); XCTAssertTrue(app.buttons["Fading ink (F)"].isSelected, "F fading on")
        key("f"); XCTAssertFalse(app.buttons["Fading ink (F)"].isSelected, "F fading off")
        key("1")
        drag(CGVector(dx: 0.2, dy: 0.45), CGVector(dx: 0.7, dy: 0.65))
        expectMarks(1, "a line")
        key("z"); expectMarks(0, "Z undoes")
        drag(CGVector(dx: 0.2, dy: 0.45), CGVector(dx: 0.7, dy: 0.65))
        key("c"); expectMarks(0, "C clears")
        shot("K1 keys chose the tools")
    }

    /// Marks are kept per deck: saved on a slide change and when the app leaves the screen, back when the deck opens
    /// again, and "Clear saved marks" removes them.
    func testMarksAreKeptForNextTime() {
        launchSample()
        drag(CGVector(dx: 0.15, dy: 0.40), CGVector(dx: 0.8, dy: 0.70))
        expectMarks(1, "slide 1: a line")
        app.buttons["next"].tap()                                  // saved on the slide change
        drag(CGVector(dx: 0.2, dy: 0.70), CGVector(dx: 0.7, dy: 0.40))
        expectMarks(1, "slide 2: a line")
        XCUIDevice.shared.press(.home)                             // saved when the app leaves the screen
        Thread.sleep(forTimeInterval: 2)
        app.terminate()

        launchSample(reset: false)
        expectMarks(1, "slide 1's line is back")
        XCTAssertTrue(app.buttons["clearSavedMarks"].exists, "says the marks are back, with a way to clear them")
        shot("M1 the marks from last time are back")
        app.buttons["next"].tap()
        expectMarks(1, "slide 2's line, saved when the app left the screen, is back")
        app.buttons["clearSavedMarks"].tap()
        Thread.sleep(forTimeInterval: 0.4)
        expectMarks(0, "cleared")
        app.buttons["previous"].tap()
        expectMarks(0, "every slide cleared")
        shot("M2 saved marks cleared")
        app.terminate()

        launchSample(reset: false)
        expectMarks(0, "nothing comes back after clearing")
        XCTAssertFalse(app.buttons["clearSavedMarks"].exists)
    }

    /// ✕ with marks asks first; with nothing to lose it closes at once.
    func testCloseAsksWhenThereAreMarks() {
        launchSample()
        app.buttons["Close slides"].tap()
        XCTAssertTrue(app.buttons["Open slides (PDF)"].waitForExistence(timeout: 5), "no marks: closed at once")

        app.terminate()
        launchSample()
        drag(CGVector(dx: 0.15, dy: 0.40), CGVector(dx: 0.8, dy: 0.70))
        expectMarks(1, "a line")
        app.buttons["Close slides"].tap()
        let close = app.buttons["Close the slides"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "marks: it asks first")
        XCTAssertTrue(app.staticTexts["slideNumber"].exists, "still presenting while it asks")
        shot("C1 close asks first")
        close.tap()
        XCTAssertTrue(app.buttons["Open slides (PDF)"].waitForExistence(timeout: 5), "closed when confirmed")
    }

    /// The video writer, as a recording uses it (the simulator may not let ReplayKit record): a file copied while it
    /// is still being written (a crash, the battery) plays, and the finished one plays without the paused stretch.
    func testTheVideoWriterKeepsWhatWasRecorded() {
        app.launchArguments = ["-recorderTest"]
        app.launch()
        let result = app.staticTexts["recorderTestResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let end = Date().addingTimeInterval(90)
        while result.label == "running", Date() < end { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(result.label.hasPrefix("ok"), result.label)
        shot("R0 the video writer")
    }

    /// A short real recording, when the simulator lets ReplayKit record: start, pause, resume, stop, and where it is.
    func testRecordPauseAndStop() throws {
        launchSample()
        app.buttons["Record"].tap()
        // iOS asks to allow screen recording (and the microphone) the first time
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let pause = app.buttons["Pause recording"]
        let end = Date().addingTimeInterval(20)
        while !pause.exists, Date() < end {
            for label in ["Record Screen", "Allow", "OK", "Start Recording"] where springboard.buttons[label].exists {
                springboard.buttons[label].tap()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard pause.exists else {
            let notice = app.buttons["recorderNotice"]
            throw XCTSkip("ReplayKit didn't record in this simulator (\(notice.exists ? notice.label : "no message"))")
        }
        shot("R1 recording")
        drag(CGVector(dx: 0.15, dy: 0.40), CGVector(dx: 0.8, dy: 0.70))
        pause.tap()
        XCTAssertTrue(app.buttons["Resume recording"].waitForExistence(timeout: 5), "paused")
        app.buttons["Resume recording"].tap()
        Thread.sleep(forTimeInterval: 2)
        app.buttons["Stop recording"].tap()
        let notice = app.buttons["recorderNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 30), "says where the video is")
        XCTAssertTrue(notice.label.contains("Recordings"), notice.label)
        XCTAssertTrue(notice.label.contains(".mov"), notice.label)
        XCTAssertFalse(notice.label.contains("Photos"), "Photos is off by default: \(notice.label)")
        shot("R2 recording saved")
    }

    /// Photos is off unless switched on; the keys are listed with L and Return.
    func testSettingsListPhotosAndKeys() {
        launchSample()
        app.buttons["Settings"].tap()
        let photos = app.switches["alsoSaveToPhotos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 5), "Also save recordings to Photos")
        XCTAssertEqual(photos.value as? String, "0", "off by default (iCloud Photos would upload patient images)")
        func listed(_ text: String) -> Bool {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(listed("L laser pointer"), "L is listed")
        XCTAssertTrue(listed("Return"), "Return is listed")
        shot("S1 settings")
    }

    /// Opening PDFs and pictures (through the same import as the Files picker): a broken PDF is refused before it
    /// is copied, a locked one asks for its password, a second one of the same name gets its own name, and pictures
    /// that can't be read are counted.
    func testImportingPDFsAndPictures() {
        app.launchArguments = ["-importTest", "-resetLibrary", "-resetMarks"]
        app.launch()
        let problem = app.staticTexts["homeProblem"]
        XCTAssertTrue(app.buttons["testImportBroken"].waitForExistence(timeout: 10))

        app.buttons["testImportBroken"].tap()
        XCTAssertTrue(problem.waitForExistence(timeout: 10))
        XCTAssertTrue(problem.label.contains("couldn't be opened as a PDF"), problem.label)
        XCTAssertFalse(app.buttons["Broken"].exists, "not added to the library")
        shot("I1 a broken PDF is refused")

        app.buttons["testImportLocked"].tap()
        let field = app.alerts.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "asks for the password")
        field.tap(); field.typeText("wrong")
        app.alerts.buttons["Open"].tap()
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        XCTAssertEqual(problem.label, "Wrong password for Locked.")
        app.buttons["Locked"].tap()                                 // kept in the library: open it again
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("secret")
        shot("I2 a locked PDF asks for its password")
        app.alerts.buttons["Open"].tap()
        XCTAssertTrue(app.staticTexts["slideNumber"].waitForExistence(timeout: 10), "opens with the right password")
        XCTAssertEqual(app.staticTexts["slideNumber"].label, "1 / 1")
        app.buttons["Close slides"].tap()

        for _ in 0..<2 {
            XCTAssertTrue(app.buttons["testImportTwice"].waitForExistence(timeout: 10))
            app.buttons["testImportTwice"].tap()
            XCTAssertTrue(app.staticTexts["slideNumber"].waitForExistence(timeout: 10))
            app.buttons["Close slides"].tap()
        }
        XCTAssertTrue(app.buttons["Twice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Twice (2)"].exists, "the second gets its own name, the first is kept")
        shot("I3 the same name twice")

        app.buttons["testImportImages"].tap()
        let number = app.staticTexts["slideNumber"]
        XCTAssertTrue(number.waitForExistence(timeout: 10))
        XCTAssertEqual(number.label, "1 / 2", "the two pictures that could be read")
        let notice = app.buttons["lectureNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "says how many couldn't be read")
        XCTAssertEqual(notice.label, "1 of 3 pictures couldn't be read and were left out.")
        shot("I4 pictures, one unreadable")
    }

    /// A sideloaded copy warns 48 hours before it stops opening.
    func testExpiryWarning() {
        app.launchArguments = ["-expiresIn", "7200"]
        app.launch()
        let warning = app.descendants(matching: .any)["expiryWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 10), "warned on the home screen")
        XCTAssertTrue(warning.label.contains("in 2 hours"), warning.label)
        shot("E1 the copy expires soon")
        app.terminate()
        app.launchArguments = ["-expiresIn", "\(5 * 24 * 3600)"]
        app.launch()
        XCTAssertTrue(app.buttons["Open slides (PDF)"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["expiryWarning"].exists, "not days ahead")
    }

    // MARK: pad mode

    /// A PC name no earlier run of the app has paired with (the app remembers each PC's key by its name).
    private static func freshName(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString.prefix(8))" }

    private func launchPad(_ pc: FakePC, code: String = "123456") {
        app.launchArguments = ["-padTest", "127.0.0.1:\(pc.port)", code]
        app.launch()
    }

    /// HELLO on that connection, version 2, with a key and no code.
    private func checkHello(_ pc: FakePC, connection: Int) throws {
        let i = try XCTUnwrap(pc.waitFor(0x01, timeout: 20, where: { $0.connection == connection }), "HELLO on connection \(connection)")
        XCTAssertEqual(pc.messages.first { $0.connection == connection }?.type, 0x01, "HELLO is the first message")
        let h = try XCTUnwrap(JSONSerialization.jsonObject(with: pc.messages[i].payload) as? [String: Any])
        XCTAssertNil(h["code"], "the code never crosses the network")
        XCTAssertEqual(h["version"] as? Int, 2)
        XCTAssertEqual((h["key"] as? String).flatMap { Data(base64Encoded: $0) }?.count, 65, "a P-256 public key, 04|X|Y")
        XCTAssertNotNil(h["device"] as? String)
    }

    /// The first time with a PC: its check is shown and nothing but HELLO has gone until the presenter answers.
    /// `onThePad`: asked while already on the pad (a new PC on the cable while on Wi-Fi).
    private func expectCheck(_ pc: FakePC, connection: Int, _ check: String, onThePad: Bool = false) {
        let first = app.staticTexts["padFirstTime"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), "the first time with this PC: its check, to compare")
        XCTAssertTrue(first.label.contains(check), "the PC check for this key (\(check)): \(first.label)")
        XCTAssertEqual(check.count, 19, "16 hex digits in four groups")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(pc.messages.filter { $0.connection == connection }.map(\.type), [0x01],
                       "no PROOF before the presenter says the check matches")
        if !onThePad { XCTAssertFalse(app.buttons["Pen"].exists, "not on the pad yet") }
    }

    private var picture: XCUIElement { app.descendants(matching: .any)["padPicture"] }
    private var pictureShown: Bool { (picture.value as? String) == "shown" }

    /// The iPad as a PC's drawing pad, against a pretend PC that speaks version 2: the handshake, a broken and a
    /// huge picture refused (not acknowledged, not shown), the real one shown then acknowledged, a drag becomes a
    /// stroke in fractions of the picture, the toolbar's commands, everything sealed, and a Wi-Fi drop survived.
    func testPadModeAgainstAFakePC() throws {
        let pc = FakePC(name: Self.freshName("TEST-PC"))
        XCTAssertTrue(pc.start(), "the fake PC listens on the loopback")
        defer { pc.stop() }
        launchPad(pc)
        try checkHello(pc, connection: 1)
        expectCheck(pc, connection: 1, "6FC6-6A90-4861-71CA")   // the spec's PC check for this key: 16 digits
        shot("P0 first time with this PC: compare the PC check")
        app.buttons["padCheckMatches"].tap()
        XCTAssertNotNil(pc.waitFor(0x04, where: { $0.connection == 1 }), "PROOF once the check matches")
        XCTAssertTrue(app.buttons["Pen"].waitForExistence(timeout: 10), "the pad's toolbar, after WELCOME")
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["padFirstTime"].exists, "the check is gone once answered")

        // a FRAME that isn't a picture: not shown, and not acknowledged as shown
        var before = pc.messages.count
        pc.send(0x83, Data("this is not a JPEG".utf8))
        XCTAssertNil(pc.waitFor(0x03, after: before, timeout: 2), "a broken picture is not acknowledged")
        XCTAssertFalse(pictureShown, "a broken picture is not shown")
        // one over 4096 px: refused from its header, before it is decoded
        pc.send(0x83, Self.picture(width: 5000, height: 8))
        XCTAssertNil(pc.waitFor(0x03, after: before, timeout: 2), "a huge picture is not acknowledged")
        XCTAssertFalse(pictureShown, "a huge picture is not shown")

        // the real one: shown, then acknowledged; and from then on one after each FRAME_ACK
        before = pc.messages.count
        pc.pace(Self.testScreen())
        XCTAssertNotNil(pc.waitFor(0x03, after: before), "FRAME_ACK once the picture is on screen")
        XCTAssertTrue(pictureShown, "the picture is shown")
        let acks = pc.messages.count
        XCTAssertNotNil(pc.waitFor(0x03, after: acks), "the next FRAME after the ACK, and its ACK")
        Thread.sleep(forTimeInterval: 0.5)
        shot("P1 pad: the PC's screen")

        // a drag across the picture, from 20%, 30% to 70%, 60% of it
        let start = pc.messages.count
        let a = picture.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
        let b = picture.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))
        a.press(forDuration: 0.1, thenDragTo: b, withVelocity: 600, thenHoldForDuration: 0.1)
        shot("P2 the stroke as the iPad draws it")
        let endAt = try XCTUnwrap(pc.waitFor(0x12, after: start), "STROKE_END after the drag")
        let stroke = Array(pc.messages[start...endAt]).filter { $0.type != 0x03 && $0.type != 0x02 }
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

        func command(_ button: XCUIElement, sends word: String) {
            let n = pc.messages.count
            button.tap()
            XCTAssertNotNil(pc.waitFor(0x20, after: n, where: { String(decoding: $0.payload, as: UTF8.self) == word }),
                            "sends COMMAND \(word)")
        }
        command(app.buttons["padUndo"], sends: "undo")
        command(app.buttons["Circle"], sends: "tool:oval")
        command(app.buttons["Thick line"], sends: "width:2")
        command(app.buttons["Fading ink"], sends: "fade:on")
        pc.send(0x84, json: #"{"tool":"oval","color":3,"width":2,"opacity":1.0,"fading":true,"canUndo":true}"#)
        Thread.sleep(forTimeInterval: 0.5)
        shot("P4 the PC says circle, cyan, thick, fading: the toolbar follows")
        command(app.buttons["Fading ink"], sends: "fade:off")
        XCTAssertNotNil(pc.waitFor(0x02, timeout: 5), "PING every 2 s")

        // the Wi-Fi drops: the iPad stays on the pad with the last picture and comes back by itself
        pc.drop()
        XCTAssertTrue(picture.exists, "the pad stays on screen")
        try checkHello(pc, connection: 2)
        XCTAssertTrue(pictureShown, "the last picture is kept while reconnecting")
        XCTAssertNotNil(pc.waitFor(0x03, where: { $0.connection == 2 }), "pictures again on the new connection")
        XCTAssertFalse(app.staticTexts["padFirstTime"].exists, "the same PC: no first-time check again")
        shot("P5 back after the Wi-Fi drop")
        command(app.buttons["padUndo"], sends: "undo")

        // everything after the PROOF went sealed, on both connections
        for c in 1...2 {
            let mine = pc.messages.filter { $0.connection == c }
            let p = try XCTUnwrap(mine.firstIndex { $0.type == 0x04 }, "PROOF on connection \(c)")
            XCTAssertEqual(mine[..<p].map(\.type), [0x01], "only HELLO before PROOF")
            XCTAssertTrue(mine[(p + 1)...].allSatisfy(\.sealed), "nothing in the clear after PROOF (connection \(c))")
        }
    }

    /// A wrong code: the PC's own words, as it sent them, and nothing more is sent.
    func testPadWrongCode() throws {
        let pc = FakePC(name: Self.freshName("CODE-PC"))
        XCTAssertTrue(pc.start())
        defer { pc.stop() }
        launchPad(pc, code: "654321")
        try checkHello(pc, connection: 1)
        expectCheck(pc, connection: 1, pc.check)
        app.buttons["padCheckMatches"].tap()
        let text = app.staticTexts["padMessage"]
        XCTAssertTrue(text.waitForExistence(timeout: 10), "the PC's REJECT text")
        XCTAssertEqual(text.label, FakePC.rejectWrongCode, "word for word")
        shot("W1 wrong code")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(pc.messages.map(\.type), [0x01, 0x04], "HELLO and PROOF, then nothing (no quiet retries)")
        XCTAssertEqual(pc.connectionCount, 1)
    }

    /// The same name with another key: the iPad warns, sends nothing after HELLO, and connects only when told to.
    func testPadDifferentPCUnderARememberedName() throws {
        let pc = FakePC(name: Self.freshName("PIN-PC"))
        XCTAssertTrue(pc.start())
        defer { pc.stop() }
        launchPad(pc)
        try checkHello(pc, connection: 1)
        expectCheck(pc, connection: 1, pc.check)
        app.buttons["padCheckMatches"].tap()
        XCTAssertTrue(app.buttons["Pen"].waitForExistence(timeout: 20), "paired once: its key is remembered")
        Thread.sleep(forTimeInterval: 1)
        app.terminate()

        let other = P256.KeyAgreement.PrivateKey()
        pc.setKey(other)
        launchPad(pc)
        try checkHello(pc, connection: 2)
        let warning = app.staticTexts["padMessage"]
        XCTAssertTrue(warning.waitForExistence(timeout: 10), "a warning")
        XCTAssertTrue(warning.label.contains("isn't the PC you paired with"), warning.label)
        XCTAssertTrue(warning.label.contains(pc.check), "the new PC check: \(warning.label)")
        shot("K1 not the PC you paired with")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(pc.messages.filter { $0.connection == 2 }.map(\.type), [0x01], "nothing after HELLO, not even PROOF")
        XCTAssertFalse(app.buttons["Pen"].exists, "not on the pad")

        app.buttons["padConnectAnyway"].tap()
        try checkHello(pc, connection: 3)
        expectCheck(pc, connection: 3, pc.check)   // its new check, to compare, before the PROOF
        shot("K2 connect anyway: compare the new check")
        app.buttons["padCheckMatches"].tap()
        XCTAssertNotNil(pc.waitFor(0x04, where: { $0.connection == 3 }), "PROOF once the new check matches")
        XCTAssertTrue(app.buttons["Pen"].waitForExistence(timeout: 10), "connected when the presenter says so")
    }

    /// The first time, a check that doesn't match: nothing after HELLO, the connection closed, nothing remembered.
    func testPadCheckDoesntMatch() throws {
        let pc = FakePC(name: Self.freshName("FAKE-PC"))
        XCTAssertTrue(pc.start())
        defer { pc.stop() }
        launchPad(pc)
        try checkHello(pc, connection: 1)
        expectCheck(pc, connection: 1, pc.check)
        app.buttons["padCheckDiffers"].tap()
        let text = app.staticTexts["padMessage"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "says why it stopped")
        XCTAssertEqual(text.label, "Don't connect: this may not be your PC.")
        shot("D1 the check doesn't match")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(pc.messages.map(\.type), [0x01], "nothing after HELLO, not even PROOF")
        XCTAssertEqual(pc.connectionCount, 1, "no quiet retries")
        XCTAssertFalse(app.buttons["Pen"].exists, "not on the pad")

        // its key wasn't remembered: the next time asks again
        app.terminate()
        launchPad(pc)
        try checkHello(pc, connection: 2)
        expectCheck(pc, connection: 2, pc.check)
    }

    // MARK: pad mode by the USB cable

    private var byCable: XCUIElement { app.staticTexts["padByCable"] }

    private func expectCommand(_ pc: FakePC, _ button: XCUIElement, sends word: String, connection: Int) {
        let n = pc.messages.count
        button.tap()
        XCTAssertNotNil(pc.waitFor(0x20, after: n, where: {
            $0.sealed && $0.connection == connection && String(decoding: $0.payload, as: UTF8.self) == word
        }), "sends COMMAND \(word), sealed, on connection \(connection)")
    }

    private func waitGone(_ e: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if !e.exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// The Wi-Fi PC first (its code typed, its check confirmed), then the cable PC: the app switches to the cable
    /// and closes the Wi-Fi connection.
    private func wifiThenCable(_ wifi: FakePC, _ cable: FakePC) throws {
        XCTAssertTrue(wifi.start(), "the Wi-Fi PC listens")
        launchPad(wifi)
        try checkHello(wifi, connection: 1)
        expectCheck(wifi, connection: 1, wifi.check)
        app.buttons["padCheckMatches"].tap()
        XCTAssertTrue(app.buttons["Pen"].waitForExistence(timeout: 10), "on the pad over Wi-Fi")
        XCTAssertFalse(byCable.exists, "over Wi-Fi, not the cable")
        shot("U3 over Wi-Fi first")

        XCTAssertTrue(cable.dial(), "the cable PC reaches the app's 127.0.0.1:47830")
        try checkHello(cable, connection: 1)
        expectCheck(cable, connection: 1, cable.check, onThePad: true)   // a new PC on the cable: compared first
        shot("U3b a new PC on the cable: compare its check")
        app.buttons["padCheckMatches"].tap()
        XCTAssertNotNil(cable.waitFor(0x04, where: { $0.connection == 1 }), "PROOF over the cable, with the empty code")
        XCTAssertTrue(byCable.waitForExistence(timeout: 10), "says it's by the USB cable")
        XCTAssertTrue(wifi.waitClosed(connection: 1), "the Wi-Fi connection is closed")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(wifi.connectionCount, 1, "Wi-Fi isn't tried while the cable is in")
        XCTAssertTrue(app.buttons["Pen"].exists, "still on the pad")
        expectCommand(cable, app.buttons["padUndo"], sends: "undo", connection: 1)
        shot("U4 the cable took over from Wi-Fi")
    }

    /// Pad mode open with nothing typed; the PC connects through the cable: no code, but the first time its PC check
    /// is shown and nothing but HELLO goes until "It matches" (the cable is not proof on its own: docs/pad-protocol.md,
    /// "USB (phase 2)"). Then the pad opens and says it's by the cable. A second cable connection is closed;
    /// unplugging with no code typed goes back to the connect screen; plugging in again goes on at once (remembered).
    func testPadByCableWithNoCode() throws {
        app.launchArguments = ["-padCable"]
        app.launch()
        XCTAssertTrue(app.textFields["padCode"].waitForExistence(timeout: 10), "the connect screen, nothing typed")
        let typed = app.textFields["padCode"].value as? String ?? ""
        XCTAssertTrue(typed.isEmpty || typed == "6 digits", "no code typed: \(typed)")
        shot("U0 the connect screen, nothing typed")

        let cable = FakePC(name: Self.freshName("CABLE-PC"), code: "")
        defer { cable.stop() }
        XCTAssertTrue(cable.dial(), "the cable PC reaches the app's 127.0.0.1:47830")
        try checkHello(cable, connection: 1)
        expectCheck(cable, connection: 1, cable.check)
        XCTAssertTrue(app.staticTexts["padFirstTime"].label.contains("USB cable"), "says it's the PC on the cable")
        shot("U0b the first time over the cable: compare the PC check")
        app.buttons["padCheckMatches"].tap()
        XCTAssertNotNil(cable.waitFor(0x04, where: { $0.connection == 1 }), "PROOF once it matches, made with the empty code")
        XCTAssertTrue(app.buttons["Pen"].waitForExistence(timeout: 10), "the pad opens with no typing")
        XCTAssertTrue(waitGone(app.staticTexts["padFirstTime"]), "the check is gone once answered")
        XCTAssertTrue(byCable.waitForExistence(timeout: 5))
        XCTAssertEqual(byCable.label, "By the USB cable")
        cable.pace(Self.testScreen())
        XCTAssertNotNil(cable.waitFor(0x03), "the picture over the cable, acknowledged")
        Thread.sleep(forTimeInterval: 0.5)
        shot("U1 the pad by the USB cable")
        expectCommand(cable, app.buttons["padUndo"], sends: "undo", connection: 1)

        // one cable connection at a time
        let extra = FakePC(name: Self.freshName("EXTRA-PC"), code: "")
        defer { extra.stop() }
        XCTAssertTrue(extra.dial())
        XCTAssertTrue(extra.waitClosed(connection: 1), "a second cable connection is closed")
        XCTAssertTrue(extra.messages.isEmpty, "and gets no HELLO")
        XCTAssertTrue(byCable.exists, "the first carries on")

        // unplugged, and no code was typed in this visit: the connect screen
        cable.drop()
        XCTAssertTrue(app.textFields["padCode"].waitForExistence(timeout: 10), "back to the connect screen")
        XCTAssertFalse(app.buttons["Pen"].exists)
        shot("U2 unplugged with no code: the connect screen")

        // plugged in again: the same PC, remembered, goes on at once
        XCTAssertTrue(cable.dial(), "the cable PC again")
        try checkHello(cable, connection: 2)
        XCTAssertNotNil(cable.waitFor(0x04, where: { $0.connection == 2 }), "PROOF at once: the PC is remembered")
        XCTAssertTrue(app.buttons["Pen"].waitForExistence(timeout: 10), "the pad again")
        XCTAssertFalse(app.staticTexts["padFirstTime"].exists, "no question the second time")
    }

    /// The first time over the cable, "It doesn't": nothing after HELLO, and the PC's next tries aren't let in.
    func testPadByCableCheckDoesntMatch() throws {
        app.launchArguments = ["-padCable"]
        app.launch()
        XCTAssertTrue(app.textFields["padCode"].waitForExistence(timeout: 10))
        let cable = FakePC(name: Self.freshName("CABLE-PC"), code: "")
        defer { cable.stop() }
        XCTAssertTrue(cable.dial())
        try checkHello(cable, connection: 1)
        expectCheck(cable, connection: 1, cable.check)
        app.buttons["padCheckDiffers"].tap()
        XCTAssertTrue(cable.waitClosed(connection: 1), "closed")
        let text = app.staticTexts["padMessage"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "says why it stopped")
        XCTAssertTrue(text.label.contains("Don't connect"), text.label)
        XCTAssertEqual(cable.messages.filter { $0.connection == 1 }.map(\.type), [0x01], "nothing after HELLO, not even PROOF")
        // the PC dials again a few seconds later: closed, not asked again
        XCTAssertTrue(cable.dial())
        XCTAssertTrue(cable.waitClosed(connection: 2), "the refused PC isn't let in")
        XCTAssertFalse(app.staticTexts["padFirstTime"].exists)
        XCTAssertFalse(app.buttons["Pen"].exists)
        shot("U6 the cable PC's check didn't match")
    }

    /// Over Wi-Fi first, then the cable: the app switches to it and closes the Wi-Fi connection.
    func testPadCableTakesOverFromWifi() throws {
        let wifi = FakePC(name: Self.freshName("WIFI-PC"))
        let cable = FakePC(name: Self.freshName("CABLE-PC"), code: "")
        defer { wifi.stop(); cable.stop() }
        try wifiThenCable(wifi, cable)
    }

    /// The cable PC goes (unplugged): the app goes back to the Wi-Fi PC by itself, with the code typed earlier.
    func testPadBackToWifiWhenUnplugged() throws {
        let wifi = FakePC(name: Self.freshName("WIFI-PC"))
        let cable = FakePC(name: Self.freshName("CABLE-PC"), code: "")
        defer { wifi.stop(); cable.stop() }
        try wifiThenCable(wifi, cable)

        cable.drop()
        try checkHello(wifi, connection: 2)
        XCTAssertNotNil(wifi.waitFor(0x04, where: { $0.connection == 2 }), "PROOF at once: the same PC as before")
        XCTAssertTrue(waitGone(byCable), "not by the cable any more")
        XCTAssertTrue(app.buttons["Pen"].waitForExistence(timeout: 10), "still on the pad")
        XCTAssertFalse(app.staticTexts["padFirstTime"].exists, "the same Wi-Fi PC: no question again")
        Thread.sleep(forTimeInterval: 1)
        expectCommand(wifi, app.buttons["padUndo"], sends: "undo", connection: 2)
        shot("U5 unplugged: back on Wi-Fi by itself")
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

    /// A plain JPEG of any size (a huge one for the size check).
    static func picture(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return img.jpegData(compressionQuality: 0.5) ?? Data()
    }
}

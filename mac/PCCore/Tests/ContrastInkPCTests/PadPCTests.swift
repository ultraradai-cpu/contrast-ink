import ContrastInkCore
import Foundation
import XCTest
@testable import ContrastInkPC

final class PadPCTests: XCTestCase {
    private func bytes(_ d: Data) -> [UInt8] { [UInt8](d) }

    func testMessageFraming() {
        XCTAssertEqual(bytes(PadPC.message(0x03)), [0x03, 0, 0, 0, 0])
        XCTAssertEqual(bytes(PadPC.pong()), [0x85, 0, 0, 0, 0])
        XCTAssertEqual(bytes(PadPC.frame(Data([1, 2, 3]))), [0x83, 0, 0, 0, 3, 1, 2, 3])
        let r = PadPC.reject(PadPC.wrongCode)
        XCTAssertEqual(r.first, 0x82)
        XCTAssertEqual(String(decoding: r.dropFirst(5), as: UTF8.self), "Wrong code: type the code Contrast Ink shows on the PC (⚙ Settings).")
    }

    func testWelcomeChallengeAndStateAreJSONTheTabletsRead() throws {
        let w = PadPC.welcome(name: "Lab \"Mac\"", screenW: 2880, screenH: 1800)
        XCTAssertEqual(w.first, 0x81)
        let pw = PadWelcome.parse(w.dropFirst(5))
        XCTAssertEqual(pw, PadWelcome(name: "Lab \"Mac\"", screenW: 2880, screenH: 1800, version: 2))

        let key = Data([4] + [UInt8](repeating: 7, count: 64)), salt = Data(0..<16)
        let c = PadPC.challenge(key: key, salt: salt, name: "MacBook")
        XCTAssertEqual(c.first, 0x86)
        XCTAssertEqual(PadChallenge.parse(c.dropFirst(5)), PadChallenge(key: key, salt: salt, name: "MacBook"))

        let s = PadPC.state(tool: .highlighter, color: 3, width: 2, opacity: 0.456, fading: true, canUndo: true)
        XCTAssertEqual(s.first, 0x84)
        XCTAssertEqual(String(decoding: s.dropFirst(5), as: UTF8.self),
                       "{\"tool\":\"highlighter\",\"color\":3,\"width\":2,\"opacity\":0.46,\"fading\":true,\"canUndo\":true}")
        XCTAssertEqual(PadState.parse(s.dropFirst(5)), PadState(tool: .highlighter, color: 3, width: 2, opacity: 0.46, fading: true, canUndo: true))
    }

    func testHelloVersion2() throws {
        let key = Data([4] + [UInt8](repeating: 1, count: 64))
        let h = PadProtocol.hello(device: "iPad", key: key)
        let r = try XCTUnwrap(PadPC.hello(h.dropFirst(5)))
        XCTAssertEqual(r.device, "iPad")
        XCTAssertEqual(r.key, key)
        // version 1 (the code in the clear), a short key, too long, not JSON: refused
        XCTAssertNil(PadPC.hello(Data("{\"code\":\"123456\",\"device\":\"t\",\"version\":1}".utf8)))
        XCTAssertNil(PadPC.hello(Data("{\"device\":\"t\",\"version\":2,\"key\":\"BAE=\"}".utf8)))
        XCTAssertNil(PadPC.hello(Data(repeating: 0x20, count: 1025)))
        XCTAssertNil(PadPC.hello(Data("nonsense".utf8)))
        XCTAssertNil(PadPC.hello(Data("{\"version\":true,\"key\":\"\(key.base64EncodedString())\"}".utf8)))
        // no name, or one with control characters: tidied
        let anon = try XCTUnwrap(PadPC.hello(Data("{\"version\":2,\"key\":\"\(key.base64EncodedString())\"}".utf8)))
        XCTAssertEqual(anon.device, "a tablet")
        let odd = try XCTUnwrap(PadPC.hello(Data("{\"version\":2,\"device\":\" Pad\\u0007 X \",\"key\":\"\(key.base64EncodedString())\"}".utf8)))
        XCTAssertEqual(odd.device, "Pad X")
    }

    func testStrokesFromTheSpecVectors() throws {
        // STROKE_BEGIN x=0.5, y=0.25, end=0
        let b = try XCTUnwrap(PadPC.begin(Data([0x3F, 0, 0, 0, 0x3E, 0x80, 0, 0, 0])))
        XCTAssertEqual(b.x, 0.5); XCTAssertEqual(b.y, 0.25); XCTAssertFalse(b.eraserEnd)
        XCTAssertEqual(PadPC.begin(Data([0x3F, 0, 0, 0, 0x3E, 0x80, 0, 0, 1]))?.eraserEnd, true)
        XCTAssertNil(PadPC.begin(Data([1, 2])))
        // STROKE_POINTS (0.5, 0.5), (1, 0)
        let pts = PadPC.points(Data([0x00, 0x02, 0x3F, 0, 0, 0, 0x3F, 0, 0, 0, 0x3F, 0x80, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(pts, [Pt(0.5, 0.5), Pt(1, 0)])
        // what the iPad's own encoder writes reads back the same; out of range and NaN are kept on the screen
        let m = PadProtocol.strokePoints([(x: 0.1, y: 0.9), (x: 0.75, y: 0.5)])
        XCTAssertEqual(PadPC.points(m.dropFirst(5)).map { ($0.x * 100).rounded() }, [10, 75])
        XCTAssertEqual(PadPC.points(Data([0, 1, 0x40, 0, 0, 0, 0x7F, 0xC0, 0, 0])), [Pt(1, 0)])
        // a count larger than the points sent: only the points there
        XCTAssertEqual(PadPC.points(Data([0, 9, 0x3F, 0, 0, 0, 0x3F, 0, 0, 0])).count, 1)
        XCTAssertEqual(PadPC.hover(Data([0x3F, 0, 0, 0, 0x3E, 0x80, 0, 0])), Pt(0.5, 0.25))
    }

    func testCommands() {
        func c(_ s: String) -> PadCommand? { PadPC.command(Data(s.utf8)) }
        XCTAssertEqual(c("undo"), .undo)
        XCTAssertEqual(c("clear"), .clear)
        XCTAssertEqual(c("next"), .next)
        XCTAssertEqual(c("previous"), .previous)
        XCTAssertEqual(c("fade:on"), .fade(true))
        XCTAssertEqual(c("fade:off"), .fade(false))
        for t in Tool.allCases { XCTAssertEqual(c(PadProtocol.Command.tool(t)), .tool(t)) }
        XCTAssertEqual(c("tool:Laser"), .tool(.laser))
        XCTAssertEqual(c("color:5"), .color(5))
        XCTAssertNil(c("color:6"))
        XCTAssertEqual(c("width:0"), .width(0))
        XCTAssertNil(c("width:3"))
        XCTAssertEqual(c("opacity:0.5"), .opacity(0.5))
        XCTAssertEqual(c("opacity:0"), .opacity(0.1))
        XCTAssertEqual(c(PadProtocol.Command.opacity(0.35)), .opacity(0.35))
        XCTAssertNil(c("opacity:nan"))
        XCTAssertNil(c("tool:brush"))
        XCTAssertNil(c("dance"))
    }

    func testFramesSplitAndJoin() throws {
        var f = PadFrames()
        let a = PadPC.message(0x20, Data("undo".utf8)), b = PadPC.message(0x12)
        let all = a + b
        XCTAssertTrue(try f.feed(all.prefix(3)).isEmpty)
        let got = try f.feed(all.dropFirst(3))
        XCTAssertEqual(got.map(\.type), [0x20, 0x12])
        XCTAssertEqual(got[0].payload, Data("undo".utf8))
        var small = PadFrames(maxLength: PadPC.helloMax)
        XCTAssertThrowsError(try small.feed(Data([0x01, 0, 0, 0x04, 0x01])))
        XCTAssertEqual(PadFrames.all(a + b)?.count, 2)
        XCTAssertNil(PadFrames.all(a.dropLast()))
    }

    func testGuard() {
        var g = PadGuard()
        let t0 = Date(timeIntervalSince1970: 1000)
        for _ in 0..<4 { XCTAssertFalse(g.wrong(t0)) }
        XCTAssertFalse(g.locked(t0))
        XCTAssertFalse(g.wrong(t0))   // the fifth in a row
        XCTAssertTrue(g.locked(t0))
        XCTAssertTrue(g.locked(t0.addingTimeInterval(29)))
        XCTAssertFalse(g.locked(t0.addingTimeInterval(30)))
        g.right()
        var newCode = false
        for i in 0..<15 { if g.wrong(t0.addingTimeInterval(100 + Double(i) * 40)) { newCode = true } }
        XCTAssertTrue(newCode, "twenty wrong in all make a new code")
        // a right code in between doesn't reset the count towards a new code, only the run
        var h = PadGuard()
        for _ in 0..<4 { _ = h.wrong(t0) }
        h.right()
        XCTAssertFalse(h.wrong(t0))
        XCTAssertFalse(h.locked(t0))
    }

    func testCodesAndAddresses() {
        for _ in 0..<50 {
            let c = PadPC.newCode()
            XCTAssertTrue(PadProtocol.isCode(c), c)
        }
        XCTAssertEqual(PadPC.usableAddresses([("lo0", "127.0.0.1"), ("en0", "192.168.1.20"), ("en0", "fe80::1"),
                                              ("en5", "169.254.3.3"), ("en1", "192.168.1.20"), ("bridge100", "10.0.0.1")]),
                       ["192.168.1.20", "10.0.0.1"])
    }
}

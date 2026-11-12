import XCTest
import Foundation
@testable import ContrastInkCore

/// The pad link's bytes: the spec's test vectors (docs/pad-protocol.md) exactly, as the Windows and Android sides
/// check the same ones.
final class PadProtocolTests: XCTestCase {
    private func hex(_ s: String) -> Data { Data(s.split(separator: " ").map { UInt8($0, radix: 16)! }) }

    func testHelloVector() {
        let json = #"{"code":"123456","device":"t","version":1}"#
        XCTAssertEqual(json.utf8.count, 42)
        XCTAssertEqual(PadProtocol.hello(code: "123456", device: "t"), hex("01 00 00 00 2A") + Data(json.utf8))
    }

    func testStrokeBeginVector() {
        XCTAssertEqual(PadProtocol.strokeBegin(x: 0.5, y: 0.25, end: .tip), hex("10 00 00 00 09 3F 00 00 00 3E 80 00 00 00"))
        XCTAssertEqual(PadProtocol.strokeBegin(x: 0.5, y: 0.25, end: .eraser).last, 1)
    }

    func testStrokePointsVector() {
        XCTAssertEqual(PadProtocol.strokePoints([(0.5, 0.5), (1, 0)]),
                       hex("11 00 00 00 12 00 02 3F 00 00 00 3F 00 00 00 3F 80 00 00 00 00 00 00"))
    }

    func testEmptyMessageVectors() {
        XCTAssertEqual(PadProtocol.strokeEnd(), hex("12 00 00 00 00"))
        XCTAssertEqual(PadProtocol.frameAck(), hex("03 00 00 00 00"))
        XCTAssertEqual(PadProtocol.ping(), hex("02 00 00 00 00"))
        XCTAssertEqual(PadProtocol.strokeCancel(), hex("13 00 00 00 00"))
        XCTAssertEqual(PadProtocol.hoverEnd(), hex("15 00 00 00 00"))
    }

    func testCommandVector() {
        XCTAssertEqual(PadProtocol.command("undo"), hex("20 00 00 00 04 75 6E 64 6F"))
    }

    func testHover() {
        XCTAssertEqual(PadProtocol.hover(x: 1, y: 0.5), hex("14 00 00 00 08 3F 80 00 00 3F 00 00 00"))
    }

    func testCoordinatesKeptOnTheScreen() {
        // past an edge (or not a number) is the edge: the PC never gets a point off its screen
        XCTAssertEqual(PadProtocol.strokeBegin(x: -3, y: 7), PadProtocol.strokeBegin(x: 0, y: 1))
        XCTAssertEqual(PadProtocol.hover(x: .nan, y: .infinity), PadProtocol.hover(x: 0, y: 0))
    }

    func testNoPointsIsNoMessage() {
        XCTAssertEqual(PadProtocol.strokePoints([]), Data())
    }

    func testHelloEscapesItsStrings() {
        let d = PadProtocol.hello(code: "123456", device: "Bob's \"iPad\"")
        let json = d.dropFirst(5)
        let obj = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any]
        XCTAssertEqual(obj?["device"] as? String, "Bob's \"iPad\"")
        XCTAssertEqual(Int(d[4]), json.count)
    }

    func testCommandWords() {
        XCTAssertEqual(PadProtocol.Command.tool(.oval), "tool:oval")
        XCTAssertEqual(PadProtocol.Command.tool(.laser), "tool:laser")
        XCTAssertEqual(PadProtocol.Command.color(5), "color:5")
        XCTAssertEqual(PadProtocol.Command.color(9), "color:5")
        XCTAssertEqual(PadProtocol.Command.width(-1), "width:0")
        XCTAssertEqual(PadProtocol.Command.opacity(0.5), "opacity:0.50")
        XCTAssertEqual(PadProtocol.Command.opacity(0), "opacity:0.10")
    }

    func testAddresses() {
        XCTAssertEqual(PadProtocol.address("192.168.1.20")?.host, "192.168.1.20")
        XCTAssertEqual(PadProtocol.address("192.168.1.20")?.port, 47820)
        XCTAssertEqual(PadProtocol.address(" 192.168.1.20:5000 ")?.port, 5000)
        XCTAssertEqual(PadProtocol.address("laptop.local")?.host, "laptop.local")
        XCTAssertEqual(PadProtocol.address("[fe80::1]:6000")?.host, "fe80::1")
        XCTAssertEqual(PadProtocol.address("[fe80::1]:6000")?.port, 6000)
        XCTAssertEqual(PadProtocol.address("fe80::1")?.port, 47820)
        XCTAssertNil(PadProtocol.address(""))
        XCTAssertNil(PadProtocol.address("1.2.3.4:"))
        XCTAssertNil(PadProtocol.address("1.2.3.4:70000"))
        XCTAssertNil(PadProtocol.address("1.2.3.4:abc"))
        XCTAssertNil(PadProtocol.address(":80"))
    }

    func testCode() {
        XCTAssertTrue(PadProtocol.isCode("123456"))
        XCTAssertFalse(PadProtocol.isCode("12345"))
        XCTAssertFalse(PadProtocol.isCode("12345a"))
        XCTAssertFalse(PadProtocol.isCode("١٢٣٤٥٦"))   // other scripts' digits aren't what the PC shows
    }

    func testFractionOfThePicture() {
        let pic = Rect(100, 50, 200, 100)
        XCTAssertEqual(PadProtocol.fraction(Pt(200, 100), in: pic), Pt(0.5, 0.5))
        XCTAssertEqual(PadProtocol.fraction(Pt(0, 400), in: pic), Pt(0, 1))
        XCTAssertEqual(PadProtocol.fraction(Pt(5, 5), in: Rect(0, 0, 0, 0)), Pt(0, 0))
    }
}

final class PadDecoderTests: XCTestCase {
    private func msg(_ type: UInt8, _ payload: [UInt8]) -> Data {
        let n = UInt32(payload.count)
        return Data([type, UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + payload)
    }

    func testWholeMessages() throws {
        var d = PadDecoder()
        let welcome = #"{"name":"LAPTOP","screenW":1920,"screenH":1080,"version":1}"#
        let got = try d.feed(msg(0x81, Array(welcome.utf8)) + msg(0x85, []) + msg(0x83, [0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(got, [.welcome(PadWelcome(name: "LAPTOP", screenW: 1920, screenH: 1080, version: 1)),
                             .pong, .frame(Data([0xFF, 0xD8, 0xFF]))])
        XCTAssertEqual(d.pending, 0)
    }

    func testSplitAcrossChunksOneByteAtATime() throws {
        let frame = Data((0..<3000).map { UInt8($0 & 0xFF) })
        let all = msg(0x82, Array("Wrong code".utf8)) + msg(0x83, Array(frame)) + msg(0x85, [])
        var d = PadDecoder()
        var got: [PadMessage] = []
        for b in all { got += try d.feed(Data([b])) }
        XCTAssertEqual(got, [.reject("Wrong code"), .frame(frame), .pong])
    }

    func testSplitInsideTheHeader() throws {
        let all = msg(0x85, []) + msg(0x83, [1, 2, 3, 4])
        var d = PadDecoder()
        XCTAssertEqual(try d.feed(all.prefix(7)), [.pong])
        XCTAssertEqual(d.pending, 2)
        XCTAssertEqual(try d.feed(all.dropFirst(7).prefix(4)), [])
        XCTAssertEqual(try d.feed(all.dropFirst(11)), [.frame(Data([1, 2, 3, 4]))])
    }

    func testUnknownTypesAreSkipped() throws {
        var d = PadDecoder()
        let all = msg(0x99, [9, 9, 9, 9, 9]) + msg(0x10, [1]) + msg(0x85, []) + msg(0xC0, [])
        XCTAssertEqual(try d.feed(all), [.pong])
        XCTAssertEqual(d.pending, 0)
    }

    func testOversizeIsAnError() {
        var d = PadDecoder()
        // 16 MB + 1: refused from the header alone, before any of it arrives
        let bad = Data([0x83, 0x01, 0x00, 0x00, 0x01])
        XCTAssertThrowsError(try d.feed(bad)) { XCTAssertEqual($0 as? PadError, .tooLong(0x0100_0001)) }
        XCTAssertThrowsError(try d.feed(msg(0x85, [])), "a broken stream stays broken")
    }

    func testExactly16MBIsAllowedToArrive() throws {
        var d = PadDecoder()
        XCTAssertEqual(try d.feed(Data([0x83, 0x01, 0x00, 0x00, 0x00])), [])
    }

    func testWelcomeIsLenient() {
        XCTAssertEqual(PadWelcome.parse(Data(#"{"name":"DESK","screenW":2560.0,"screenH":1440,"extra":[1]}"#.utf8)),
                       PadWelcome(name: "DESK", screenW: 2560, screenH: 1440, version: 1))
        XCTAssertEqual(PadWelcome.parse(Data("not json".utf8)), PadWelcome())
        XCTAssertEqual(PadWelcome.parse(Data(#"{"screenW":-5,"screenH":true}"#.utf8)).screenW, 1920)
    }

    func testState() throws {
        var d = PadDecoder()
        let json = #"{"tool":"oval","color":3,"width":2,"opacity":0.5,"fading":true,"canUndo":true}"#
        guard case .state(let payload)? = try d.feed(msg(0x84, Array(json.utf8))).first else { return XCTFail("no state") }
        XCTAssertEqual(PadState.parse(payload),
                       PadState(tool: .oval, color: 3, width: 2, opacity: 0.5, fading: true, canUndo: true))
    }

    func testStateKeepsWhatItDoesNotSay() {
        let old = PadState(tool: .laser, color: 4, width: 0, opacity: 0.3, fading: true, canUndo: true)
        let s = PadState.parse(Data(#"{"tool":"sparkles","color":99,"opacity":1}"#.utf8), over: old)
        XCTAssertEqual(s.tool, .laser)        // an unknown tool name: keep the old one
        XCTAssertEqual(s.color, 5)            // out of range: the nearest colour
        XCTAssertEqual(s.width, 0)
        XCTAssertEqual(s.opacity, 1)
        XCTAssertTrue(s.fading)
        XCTAssertEqual(PadState.parse(Data("[]".utf8), over: old), old)
    }
}

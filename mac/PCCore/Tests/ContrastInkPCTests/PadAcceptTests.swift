// The Mac's end of the version-2 handshake against the spec's test vectors (docs/pad-protocol.md, "Version 2 test
// vectors"), and against the iPad's own client code (Core's PadLink). CryptoKit is Apple's: Mac only.
#if canImport(CryptoKit)
import ContrastInkCore
import CryptoKit
import Foundation
import XCTest
@testable import ContrastInkPC

final class PadAcceptTests: XCTestCase {
    static func hex(_ s: String) -> Data {
        let c = Array(s.filter { !$0.isWhitespace })
        return Data(stride(from: 0, to: c.count, by: 2).map { UInt8(String(c[$0...$0 + 1]), radix: 16)! })
    }

    static var tabletKey: P256.KeyAgreement.PrivateKey { try! .init(rawRepresentation: Data(repeating: 0x11, count: 32)) }
    static var pcKey: P256.KeyAgreement.PrivateKey { try! .init(rawRepresentation: Data(repeating: 0x22, count: 32)) }
    static let salt = Data(0..<16)
    static let pcPublic = "04D65A93977CAA3D1B081852FF57A79E465F1660577304BAEAD505DD3A48589CF350185E895372DF6221EA3A137557E473FDDB6755F05BD507C3C533FCE9C91285"
    static let firstProof = "0000000000000000000000012DCC2D016D67988C73F5CD844EA2BE5AFB2499203A49A95C4546"

    private func accept() -> PadAccept { PadAccept(pcKey: Self.pcKey, name: "LAPTOP", salt: Self.salt) }

    private func helloPayload() -> Data { PadLink(privateKey: Self.tabletKey).hello(device: "iPad").dropFirst(5) }

    func testChallengeCarriesTheMacsKeyAndSalt() throws {
        var a = accept()
        guard case .challenge(let m) = a.hello(type: 0x01, payload: helloPayload()) else { return XCTFail("refused") }
        XCTAssertEqual(m.first, 0x86)
        let c = try XCTUnwrap(PadChallenge.parse(m.dropFirst(5)))
        XCTAssertEqual(c.key, Self.hex(Self.pcPublic))
        XCTAssertEqual(c.salt, Self.salt)
        XCTAssertEqual(c.name, "LAPTOP")
        XCTAssertEqual(a.device, "iPad")
        XCTAssertEqual(PadIdentityCheck.check(Self.pcKey), "6FC6-6A90")
    }

    func testTheSpecsProofOpensWithTheRightCodeOnly() {
        let proof = Self.hex(Self.firstProof)
        var a = accept()
        _ = a.hello(type: 0x01, payload: helloPayload())
        XCTAssertFalse(a.proof(type: 0x04, payload: proof, code: "654321"))
        XCTAssertFalse(a.isOpen)
        XCTAssertFalse(a.proof(type: 0x04, payload: proof, code: ""), "an empty code is another code")
        XCTAssertTrue(a.proof(type: 0x04, payload: proof, code: "123456"))
        XCTAssertTrue(a.isOpen)
        XCTAssertFalse(a.proof(type: 0x04, payload: proof, code: "123456"), "only once")
        var b = accept()
        _ = b.hello(type: 0x01, payload: helloPayload())
        XCTAssertFalse(b.proof(type: 0x20, payload: proof, code: "123456"), "not a PROOF")
    }

    func testOldOrBrokenHellosAreAskedToUpdate() {
        var a = accept()
        XCTAssertEqual(a.hello(type: 0x01, payload: Data("{\"code\":\"123456\",\"device\":\"t\",\"version\":1}".utf8)), .reject(PadPC.updateTablet))
        var b = accept()
        let notOnCurve = Data([4] + [UInt8](repeating: 0, count: 64)).base64EncodedString()
        XCTAssertEqual(b.hello(type: 0x01, payload: Data("{\"device\":\"t\",\"version\":2,\"key\":\"\(notOnCurve)\"}".utf8)), .reject(PadPC.updateTablet))
        var c = accept()
        XCTAssertEqual(c.hello(type: 0x02, payload: Data()), .reject(PadPC.updateTablet))
    }

    /// The whole conversation with the iPad's own client (PadLink): right code, sealed both ways, replays refused.
    func testSessionWithTheTabletsClient() throws {
        for code in ["123456", ""] {   // Wi-Fi, and the USB door's empty code
            var link = PadLink()
            var a = PadAccept(pcKey: Self.pcKey, name: "Mac")
            guard case .challenge(let m) = a.hello(type: 0x01, payload: link.hello(device: "Pixel").dropFirst(5)) else { return XCTFail() }
            let ch = try XCTUnwrap(PadChallenge.parse(m.dropFirst(5)))
            let proof = try XCTUnwrap(link.proof(ch, code: code))
            XCTAssertTrue(a.proof(type: proof[0], payload: proof.dropFirst(5), code: code))

            let welcome = try XCTUnwrap(a.seal(PadPC.welcome(name: "Mac", screenW: 100, screenH: 50)))
            XCTAssertEqual(welcome.first, 0x7F)
            XCTAssertEqual(try link.open(welcome.dropFirst(5)), .welcome(PadWelcome(name: "Mac", screenW: 100, screenH: 50, version: 2)))

            let undo = try XCTUnwrap(link.seal(PadProtocol.command("undo")))
            let inner = try XCTUnwrap(a.open(undo.dropFirst(5)))
            XCTAssertEqual(inner.count, 1)
            XCTAssertEqual(inner[0].type, 0x20)
            XCTAssertEqual(PadPC.command(inner[0].payload), .undo)
            XCTAssertNil(a.open(undo.dropFirst(5)), "a replay is refused")
            var altered = try XCTUnwrap(link.seal(PadProtocol.ping()))
            altered[altered.count - 1] ^= 1
            XCTAssertNil(a.open(altered.dropFirst(5)), "an altered message is refused")
        }
    }

    func testNothingIsSealedBeforeTheProof() {
        var a = accept()
        XCTAssertNil(a.seal(PadPC.pong()))
        XCTAssertNil(a.open(Data(repeating: 0, count: 40)))
    }
}
#endif

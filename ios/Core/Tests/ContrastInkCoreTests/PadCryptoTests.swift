// Version 2's keys and sealing against the spec's test vectors (docs/pad-protocol.md, "Version 2 test vectors"),
// byte for byte, as the Windows and Android sides check the same ones. CryptoKit is Apple's: these run on the Mac
// (GitHub's macOS run), and are left out on Linux.
#if canImport(CryptoKit)
import CryptoKit
import Foundation
import XCTest
@testable import ContrastInkCore

final class PadCryptoTests: XCTestCase {
    private func hex(_ s: String) -> Data {
        let c = Array(s.filter { !$0.isWhitespace })
        return Data(stride(from: 0, to: c.count, by: 2).map { UInt8(String(c[$0...$0 + 1]), radix: 16)! })
    }

    private func hexOf(_ k: SymmetricKey) -> String { k.withUnsafeBytes { Data($0) }.map { String(format: "%02X", $0) }.joined() }

    private var tabletKey: P256.KeyAgreement.PrivateKey { try! .init(rawRepresentation: Data(repeating: 0x11, count: 32)) }
    private var pcKey: P256.KeyAgreement.PrivateKey { try! .init(rawRepresentation: Data(repeating: 0x22, count: 32)) }
    private let salt = Data(0..<16)
    private let tabletPublic = """
        040217E617F0B6443928278F96999E69A23A4F2C152BDF6D6CDF66E5B80282D4ED194A7DEBCB97712D2DDA3CA85AA8765A56F45FC758599652F2897C65306E5794
        """
    private let pcPublic = """
        04D65A93977CAA3D1B081852FF57A79E465F1660577304BAEAD505DD3A48589CF350185E895372DF6221EA3A137557E473FDDB6755F05BD507C3C533FCE9C91285
        """
    private let firstProof = "0000000000000000000000012DCC2D016D67988C73F5CD844EA2BE5AFB2499203A49A95C4546"

    private var challenge: PadChallenge { PadChallenge(key: hex(pcPublic), salt: salt, name: "LAPTOP") }

    func testPublicKeys() {
        XCTAssertEqual(tabletKey.publicKey.x963Representation, hex(tabletPublic))
        XCTAssertEqual(pcKey.publicKey.x963Representation, hex(pcPublic))
        XCTAssertEqual(PadLink(privateKey: tabletKey).publicKey, hex(tabletPublic))
    }

    func testDerivedKeysOnBothSides() throws {
        let t = try XCTUnwrap(PadCrypto.keys(own: tabletKey, other: hex(pcPublic), salt: salt, code: "123456"))
        XCTAssertEqual(hexOf(t.toPC), "DF563C024C91B19647C1653F3A8E43A1F43779F68708CF133853BCD3BC3A5A98")
        XCTAssertEqual(hexOf(t.toTablet), "A848F926D9916CEE78F6203D58A043C11A99389BE63198DE580581A4CBAAB8D2")
        let p = try XCTUnwrap(PadCrypto.keys(own: pcKey, other: hex(tabletPublic), salt: salt, code: "123456"))
        XCTAssertEqual(hexOf(p.toPC), hexOf(t.toPC))
        XCTAssertEqual(hexOf(p.toTablet), hexOf(t.toTablet))
    }

    func testFirstProof() throws {
        var link = PadLink(privateKey: tabletKey)
        let proof = try XCTUnwrap(link.proof(challenge, code: "123456"))
        let payload = hex(firstProof)
        XCTAssertEqual(proof, Data([0x04, 0, 0, 0, UInt8(payload.count)]) + payload)
        XCTAssertEqual(payload.count, 12 + 10 + 16, "nonce, COMMAND \"hello\" with its header, tag")
    }

    func testPCCheck() {
        XCTAssertEqual(PadCrypto.check(hex(pcPublic)), "6FC6-6A90-4861-71CA", "16 hex digits, the spec's vector")
    }

    /// The PC's side of the test: its keys from its own private key and the tablet's public one.
    private func pcSeals(code: String = "123456") throws -> (open: PadSeal, seal: PadSeal) {
        let k = try XCTUnwrap(PadCrypto.keys(own: pcKey, other: hex(tabletPublic), salt: salt, code: code))
        return (PadSeal(key: k.toPC), PadSeal(key: k.toTablet))
    }

    func testThePCOpensTheProofOnlyWithTheRightCode() throws {
        var right = PadLink(privateKey: tabletKey), wrong = PadLink(privateKey: tabletKey)
        let good = try XCTUnwrap(right.proof(challenge, code: "123456")).dropFirst(5)
        let bad = try XCTUnwrap(wrong.proof(challenge, code: "123457")).dropFirst(5)
        var pc = try pcSeals()
        XCTAssertNil(pc.open.open(Data(bad)), "a wrong code's PROOF can't be opened")
        XCTAssertEqual(pc.open.open(Data(good)), PadProtocol.command("hello"))
    }

    func testSealedBothWays() throws {
        var link = PadLink(privateKey: tabletKey)
        let proof = try XCTUnwrap(link.proof(challenge, code: "123456"))
        var pc = try pcSeals()
        XCTAssertEqual(pc.open.open(Data(proof.dropFirst(5))), PadProtocol.command("hello"), "PROOF: counter 1")
        // the PC's WELCOME and a FRAME, sealed
        let welcome = PadProtocol.message(.welcome, Array(#"{"name":"LAPTOP","screenW":1600,"screenH":900}"#.utf8))
        XCTAssertEqual(try link.open(pc.seal.seal(welcome)), .welcome(PadWelcome(name: "LAPTOP", screenW: 1600, screenH: 900)))
        XCTAssertEqual(try link.open(pc.seal.seal(PadProtocol.message(.frame, [1, 2, 3]))), .frame(Data([1, 2, 3])))
        // an unknown type inside is skipped, not refused
        XCTAssertNil(try link.open(pc.seal.seal(Data([0x99, 0, 0, 0, 1, 7]))))
        // the tablet's PING: counter 2 after PROOF's 1
        let ping = try XCTUnwrap(link.seal(PadProtocol.ping()))
        XCTAssertEqual(ping.prefix(1), Data([0x7F]))
        XCTAssertEqual(ping[16], 2, "the nonce's counter")
        let opened = pc.open.open(Data(ping.dropFirst(5)))
        XCTAssertEqual(opened, PadProtocol.ping())
    }

    func testReplayIsRefused() throws {
        var link = PadLink(privateKey: tabletKey)
        _ = link.proof(challenge, code: "123456")
        var pc = try pcSeals()
        let first = pc.seal.seal(PadProtocol.message(.pong))
        let second = pc.seal.seal(PadProtocol.message(.pong))
        XCTAssertEqual(try link.open(first), .pong)
        XCTAssertThrowsError(try link.open(first), "the same message again") { XCTAssertEqual($0 as? PadError, .refused) }
        XCTAssertEqual(try link.open(second), .pong)
        XCTAssertThrowsError(try link.open(first), "an older one") { XCTAssertEqual($0 as? PadError, .refused) }
    }

    func testTamperingIsRefused() throws {
        var pc = try pcSeals()
        let sealed = pc.seal.seal(PadProtocol.message(.frame, Array(repeating: 9, count: 40)))
        for i in [0, 3, 11, 12, 30, sealed.count - 1] {   // the nonce (its zero part and counter), the ciphertext, the tag
            var link = PadLink(privateKey: tabletKey)
            _ = link.proof(challenge, code: "123456")
            var bent = sealed
            bent[i] ^= 0x01
            XCTAssertThrowsError(try link.open(bent), "byte \(i) changed") { XCTAssertEqual($0 as? PadError, .refused) }
            XCTAssertEqual(try link.open(sealed), .frame(Data(repeating: 9, count: 40)), "the untouched one still opens")
        }
        var link = PadLink(privateKey: tabletKey)
        _ = link.proof(challenge, code: "123456")
        XCTAssertThrowsError(try link.open(sealed.prefix(27)), "too short to hold a nonce and tag")
        XCTAssertThrowsError(try link.open(Data(sealed.dropLast())), "cut short")
    }

    func testAWrongCodeCantOpenThePCsMessages() throws {
        var link = PadLink(privateKey: tabletKey)
        _ = link.proof(challenge, code: "000000")
        var pc = try pcSeals()
        XCTAssertThrowsError(try link.open(pc.seal.seal(PadProtocol.message(.pong))))
    }

    func testTheInsideMustBeOneWholeMessage() throws {
        var link = PadLink(privateKey: tabletKey)
        _ = link.proof(challenge, code: "123456")
        var pc = try pcSeals()
        XCTAssertThrowsError(try link.open(pc.seal.seal(Data([0x85, 0, 0, 0, 2]))), "a length longer than what's inside")
        XCTAssertThrowsError(try link.open(pc.seal.seal(PadProtocol.message(.pong) + PadProtocol.message(.pong))), "two messages")
        XCTAssertThrowsError(try link.open(pc.seal.seal(PadProtocol.message(.sealed, [1]))), "sealed inside sealed")
    }

    func testNothingIsSealedBeforeTheProof() {
        var link = PadLink(privateKey: tabletKey)
        XCTAssertNil(link.seal(PadProtocol.ping()))
        XCTAssertThrowsError(try link.open(Data(count: 40)))
    }

    func testAKeyNotOnTheCurveIsRefused() {
        var link = PadLink(privateKey: tabletKey)
        var notAPoint = hex(pcPublic)
        notAPoint[64] ^= 0x01
        XCTAssertNil(link.proof(PadChallenge(key: notAPoint, salt: salt, name: "X"), code: "123456"))
    }

    func testFreshKeysEachConnection() {
        XCTAssertNotEqual(PadLink().publicKey, PadLink().publicKey)
        XCTAssertEqual(PadLink().publicKey.count, 65)
    }
}
#endif

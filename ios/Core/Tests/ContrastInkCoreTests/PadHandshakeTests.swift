import XCTest
import Foundation
@testable import ContrastInkCore

/// Step 4 of the version 2 handshake (docs/pad-protocol.md): when the PROOF goes, when the presenter is asked first,
/// when nothing more is sent. No crypto here, so these run on Linux too.
final class PadHandshakeTests: XCTestCase {
    private let a = Data([4] + [UInt8](repeating: 1, count: 64))
    private let b = Data([4] + [UInt8](repeating: 2, count: 64))
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testDecide() {
        XCTAssertEqual(PadHandshake.decide(received: a, remembered: nil), .askToConfirm, "first time: ask")
        XCTAssertEqual(PadHandshake.decide(received: a, remembered: a), .proceed, "the same key: at once")
        XCTAssertEqual(PadHandshake.decide(received: b, remembered: a), .warnDifferent, "another key: warn")
        XCTAssertEqual(PadHandshake.decide(received: b, remembered: a, accepted: b), .askToConfirm,
                       "Connect anyway: the check is shown and confirmed too")
        XCTAssertEqual(PadHandshake.decide(received: b, remembered: a, accepted: a), .warnDifferent,
                       "trusting one key doesn't let another in")
        XCTAssertEqual(PadHandshake.decide(received: a, remembered: nil, session: a), .proceed, "a reconnect to the same PC")
        XCTAssertEqual(PadHandshake.decide(received: b, remembered: nil, session: a), .warnDifferent,
                       "a reconnect that finds another machine")
        XCTAssertEqual(PadHandshake.decide(received: b, remembered: b, session: a), .warnDifferent)
    }

    func testFirstTimeWaitsForTheMatch() {
        var h = PadHandshake()
        XCTAssertEqual(h.challenge(received: a, remembered: nil, now: t0), .askToConfirm)
        XCTAssertTrue(h.isConfirming)
        XCTAssertFalse(h.expectsSealed, "no PROOF yet, so nothing sealed can be opened")
        XCTAssertFalse(h.welcomed(), "a WELCOME before the PROOF is not believed")
        XCTAssertFalse(h.tick(now: t0.addingTimeInterval(10)))
        XCTAssertTrue(h.confirm(now: t0.addingTimeInterval(20)), "It matches: send the PROOF")
        XCTAssertEqual(h.step, .proof)
        XCTAssertTrue(h.welcomed())
        XCTAssertEqual(h.step, .open)
    }

    func testItDoesntSendsNothing() {
        var h = PadHandshake()
        _ = h.challenge(received: a, remembered: nil, now: t0)
        h.deny()
        XCTAssertEqual(h.step, .ended(PadHandshake.deniedText))
        XCTAssertFalse(h.confirm(now: t0), "no PROOF after It doesn't")
        XCTAssertEqual(PadHandshake.deniedText, "Don't connect: this may not be your PC.")
    }

    func testTooLong() {
        var h = PadHandshake()
        _ = h.challenge(received: a, remembered: nil, now: t0)
        XCTAssertTrue(h.tick(now: t0.addingTimeInterval(26)))
        XCTAssertEqual(h.step, .ended(PadHandshake.tooLongText))
        XCTAssertFalse(h.tick(now: t0.addingTimeInterval(27)), "only once")

        var late = PadHandshake()
        _ = late.challenge(received: a, remembered: nil, now: t0)
        XCTAssertFalse(late.confirm(now: t0.addingTimeInterval(26)), "a tap after the limit sends nothing")
        XCTAssertEqual(late.step, .ended(PadHandshake.tooLongText))
        XCTAssertLessThan(PadHandshake.confirmLimit, 30, "before the PC gives up waiting")
    }

    func testSameKeyGoesOnAtOnce() {
        var h = PadHandshake()
        XCTAssertEqual(h.challenge(received: a, remembered: a), .proceed)
        XCTAssertEqual(h.step, .proof)
        XCTAssertTrue(h.expectsSealed)
    }

    func testDifferentKeyStops() {
        var h = PadHandshake()
        XCTAssertEqual(h.challenge(received: b, remembered: a), .warnDifferent)
        XCTAssertEqual(h.step, .warned)
        XCTAssertFalse(h.confirm(), "nothing to confirm: no PROOF")
        XCTAssertFalse(h.welcomed())
    }

    func testOneChallengeOnly() {
        var h = PadHandshake()
        _ = h.challenge(received: a, remembered: a)
        XCTAssertNil(h.challenge(received: a, remembered: a), "a second CHALLENGE is not expected")
    }
}

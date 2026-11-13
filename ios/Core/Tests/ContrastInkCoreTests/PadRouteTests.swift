import XCTest
import Foundation
@testable import ContrastInkCore

/// "USB (phase 2)" of docs/pad-protocol.md: when the cable takes over from Wi-Fi, and where the pad goes after it.
final class PadRouteTests: XCTestCase {
    func testWifiThenCableThenBackToWifi() {
        var r = PadRoute()
        XCTAssertEqual(r.link, .none, "the connect screen")
        r.wifiChosen()
        XCTAssertTrue(r.wifiStarting())
        XCTAssertEqual(r.link, .wifi, "Wi-Fi only")
        XCTAssertTrue(r.cableArrived(), "a cable connection is let in")
        XCTAssertEqual(r.link, .wifi, "Wi-Fi stays until the cable's session opens")
        r.cableOpened()
        XCTAssertEqual(r.link, .usb, "the cable took over")
        XCTAssertFalse(r.mayStartWifi, "Wi-Fi isn't tried while the cable is up")
        XCTAssertFalse(r.wifiStarting(), "not even a quiet retry")
        XCTAssertEqual(r.link, .usb)
        XCTAssertEqual(r.cableDropped(), .wifi, "unplugged, with the code held: back to Wi-Fi")
        XCTAssertEqual(r.link, .wifi)
        XCTAssertTrue(r.mayStartWifi)
        XCTAssertTrue(r.wifiStarting())
    }

    func testCableWithoutACodeGoesBackToTheConnectScreen() {
        var r = PadRoute()
        XCTAssertTrue(r.cableArrived(), "the cable works with no code typed")
        r.cableOpened()
        XCTAssertEqual(r.link, .usb)
        XCTAssertEqual(r.cableDropped(), .connectScreen, "no code held")
        XCTAssertEqual(r.link, .none)
        XCTAssertTrue(r.mayStartWifi)
        XCTAssertTrue(r.cableArrived(), "plugging in again opens it again")
    }

    func testWifiNeverStartsWhileTheCableIsUp() {
        var r = PadRoute()
        XCTAssertTrue(r.cableArrived())
        r.cableOpened()
        r.wifiChosen()   // a code typed meanwhile is held for later
        XCTAssertFalse(r.wifiStarting())
        XCTAssertEqual(r.link, .usb)
        XCTAssertEqual(r.cableDropped(), .wifi)
    }

    func testOneCableAtATime() {
        var r = PadRoute()
        XCTAssertTrue(r.cableArrived())
        XCTAssertFalse(r.cableArrived(), "a second while the first is let in: closed")
        r.cableFailed()
        XCTAssertTrue(r.cableArrived(), "after the first failed, the next is let in")
        r.cableOpened()
        XCTAssertFalse(r.cableArrived(), "a second while one is open: closed")
        r.cableFailed()   // the closed extra's ending changes nothing
        XCTAssertEqual(r.link, .usb)
        XCTAssertFalse(r.cableArrived(), "still one open")
        _ = r.cableDropped()
        XCTAssertTrue(r.cableArrived())
    }

    func testAFailedCableLeavesWifiAlone() {
        var r = PadRoute()
        r.wifiChosen()
        r.wifiStarting()
        XCTAssertTrue(r.cableArrived())
        r.cableFailed()   // e.g. not the PC paired with
        XCTAssertEqual(r.link, .wifi)
        XCTAssertTrue(r.mayStartWifi)
    }

    func testForget() {
        var r = PadRoute()
        r.wifiChosen()
        XCTAssertTrue(r.cableArrived())
        r.cableOpened()
        r.forget()
        XCTAssertEqual(r, PadRoute())
        XCTAssertEqual(r.cableDropped(), .connectScreen, "after a disconnect no code is held")
    }

    /// Over the cable the first-time check is shown too (docs/pad-protocol.md, "USB (phase 2)": any app on the iPad
    /// can reach its loopback door), a remembered key goes on at once, and a different one warns.
    func testTheCablesHandshakeAsksTheFirstTime() {
        let a = Data([4] + [UInt8](repeating: 1, count: 64))
        let b = Data([4] + [UInt8](repeating: 2, count: 64))
        var h = PadHandshake()
        XCTAssertEqual(h.challenge(received: a, remembered: nil), .askToConfirm, "first time over the cable: ask")
        XCTAssertTrue(h.isConfirming, "no PROOF until the presenter says it matches")
        XCTAssertFalse(h.welcomed())
        XCTAssertTrue(h.confirm())
        XCTAssertTrue(h.welcomed())
        var same = PadHandshake()
        XCTAssertEqual(same.challenge(received: a, remembered: a), .proceed, "remembered: at once")
        var w = PadHandshake()
        XCTAssertEqual(w.challenge(received: b, remembered: a), .warnDifferent)
        XCTAssertEqual(w.step, .warned)
        XCTAssertEqual(PadHandshake.decide(received: b, remembered: a, accepted: b), .askToConfirm,
                       "Connect anyway over the cable: compared by eye too")
    }
}

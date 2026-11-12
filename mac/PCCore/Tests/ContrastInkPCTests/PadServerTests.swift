// The real server on loopback ports, paired with as a tablet would (Core's PadLink: the iPad's own client code):
// a right code, a wrong code, an empty code on the Wi-Fi port (refused) and on the USB door (accepted), pictures paced
// by FRAME_ACK, replacement by a second right-code tablet. Mac only (Network.framework and CryptoKit).
#if canImport(Network) && canImport(CryptoKit)
import ContrastInkCore
import CryptoKit
import Foundation
import Network
import XCTest
@testable import ContrastInkPC

/// A tablet, as far as the wire goes: blocking helpers over an NWConnection.
final class TestTablet {
    let c: NWConnection
    let q = DispatchQueue(label: "test tablet")
    private var buffer = Data()
    private var closed = false
    private let lock = NSCondition()
    var link = PadLink()

    init(port: UInt16) {
        c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        c.stateUpdateHandler = { [weak self] s in
            if case .failed = s { self?.end() }
            if case .cancelled = s { self?.end() }
        }
        c.start(queue: q)
        read()
    }

    private func read() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] d, _, complete, err in
            guard let self else { return }
            self.lock.lock()
            if let d { self.buffer.append(d) }
            self.lock.broadcast()
            self.lock.unlock()
            if complete || err != nil { self.end() } else { self.read() }
        }
    }

    private func end() { lock.lock(); closed = true; lock.broadcast(); lock.unlock() }

    func send(_ d: Data) { c.send(content: d, completion: .contentProcessed { _ in }) }

    /// The next whole message (type, payload), or nil when the connection closed first or nothing came in time.
    func next(timeout: TimeInterval = 5) -> (UInt8, Data)? {
        let until = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while true {
            if buffer.count >= 5 {
                let b = [UInt8](buffer.prefix(5))
                let n = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
                if buffer.count >= 5 + n {
                    let m = (b[0], Data(buffer[buffer.startIndex + 5 ..< buffer.startIndex + 5 + n]))
                    buffer = Data(buffer.dropFirst(5 + n))
                    return m
                }
            }
            if closed { return nil }
            if !lock.wait(until: until) { return nil }
        }
    }

    /// The next message opened (sealed ones), skipping nothing.
    func nextOpened(timeout: TimeInterval = 5) throws -> PadMessage? {
        guard let (t, p) = next(timeout: timeout) else { return nil }
        if t == PadProtocol.Kind.sealed.rawValue { return try link.open(p) }
        return PadMessage.read(type: t, payload: p)
    }

    /// True once the server has closed the connection.
    func waitClosed(timeout: TimeInterval = 5) -> Bool {
        let until = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while !closed { if !lock.wait(until: until) { return closed } }
        return true
    }

    /// HELLO → CHALLENGE → PROOF with this code. The first answer after the PROOF.
    func pair(code: String) throws -> PadMessage? {
        send(link.hello(device: "Test tablet"))
        guard let (t, p) = next(), t == PadProtocol.Kind.challenge.rawValue, let ch = PadChallenge.parse(p) else { return nil }
        guard let proof = link.proof(ch, code: code) else { return nil }
        send(proof)
        return try nextOpened()
    }

    func sealed(_ m: Data) { send(link.seal(m)!) }

    func close() { c.cancel() }
}

final class PadServerTests: XCTestCase {
    private var server: PadServer!
    private var wifi: UInt16 = 0
    private var usb: UInt16 = 0
    private let events = DispatchQueue(label: "test events")
    private var received: [(UInt8, Data)] = []
    private var connections: [String?] = []

    override func setUpWithError() throws {
        var config = PadServer.Config(name: "Test Mac")
        config.port = 0
        config.usbPort = 0
        config.advertise = false
        server = PadServer(key: P256.KeyAgreement.PrivateKey(), config: config, code: "123456", deliver: events)
        server.screenSize = { (2880, 1800) }
        server.onMessage = { [unowned self] t, p in self.received.append((t, p)) }
        server.onConnection = { [unowned self] name, _ in self.connections.append(name) }
        server.start()
        let until = Date().addingTimeInterval(10)
        while Date() < until {
            let p = server.ports
            if p.wifi != 0, let u = p.usb { wifi = p.wifi; usb = u; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertNotEqual(wifi, 0, "the Wi-Fi port is listening")
        XCTAssertNotEqual(usb, 0, "the USB door is listening")
    }

    override func tearDown() { server?.stop(); server = nil }

    private func settle() { Thread.sleep(forTimeInterval: 0.2); events.sync {} }

    func testRightCodeOverWiFi() throws {
        let t = TestTablet(port: wifi)
        defer { t.close() }
        XCTAssertEqual(try t.pair(code: "123456"), .welcome(PadWelcome(name: "Test Mac", screenW: 2880, screenH: 1800, version: 2)))
        settle()
        XCTAssertEqual(server.connected?.name, "Test tablet")
        XCTAssertEqual(server.connected?.usb, false)
        XCTAssertEqual(events.sync { connections }, ["Test tablet"])
        // a ping is answered, sealed
        t.sealed(PadProtocol.ping())
        XCTAssertEqual(try t.nextOpened(), .pong)
        // strokes and commands reach the app in order
        t.sealed(PadProtocol.strokeBegin(x: 0.5, y: 0.25))
        t.sealed(PadProtocol.strokePoints([(x: 0.5, y: 0.5), (x: 1, y: 0)]))
        t.sealed(PadProtocol.strokeEnd())
        t.sealed(PadProtocol.command("tool:arrow"))
        t.sealed(PadProtocol.ping())
        XCTAssertEqual(try t.nextOpened(), .pong)
        settle()
        let got = events.sync { received }
        XCTAssertEqual(got.map(\.0), [0x10, 0x11, 0x12, 0x20])
        XCTAssertEqual(PadPC.points(got[1].1), [Pt(0.5, 0.5), Pt(1, 0)])
        XCTAssertEqual(PadPC.command(got[3].1), .tool(.arrow))
        // the app's STATE goes out sealed
        server.send(PadPC.state(tool: .arrow, color: 1, width: 2, opacity: 1, fading: false, canUndo: true))
        guard case .state(let s)? = try t.nextOpened() else { return XCTFail("no STATE") }
        XCTAssertEqual(PadState.parse(s).tool, .arrow)
    }

    func testWrongCodeIsRefused() throws {
        let t = TestTablet(port: wifi)
        XCTAssertEqual(try t.pair(code: "654321"), .reject(PadPC.wrongCode))
        XCTAssertTrue(t.waitClosed())
        XCTAssertNil(server.connected)
    }

    func testEmptyCodeIsRefusedOnWiFi() throws {
        let t = TestTablet(port: wifi)
        XCTAssertEqual(try t.pair(code: ""), .reject(PadPC.wrongCode))
        XCTAssertTrue(t.waitClosed())
    }

    func testEmptyCodeIsTheUsbDoorsCode() throws {
        let t = TestTablet(port: usb)
        defer { t.close() }
        guard case .welcome(let w)? = try t.pair(code: "") else { return XCTFail("not let in by the USB door") }
        XCTAssertEqual(w.version, 2)
        settle()
        XCTAssertEqual(server.connected?.usb, true)
        // the Wi-Fi code is not the USB door's
        let other = TestTablet(port: usb)
        XCTAssertEqual(try other.pair(code: "123456"), .reject(PadPC.wrongCode))
    }

    func testOldTabletIsAskedToUpdate() {
        let t = TestTablet(port: wifi)
        t.send(PadPC.message(0x01, Data("{\"code\":\"123456\",\"device\":\"t\",\"version\":1}".utf8)))
        guard let (type, p) = t.next() else { return XCTFail("no answer") }
        XCTAssertEqual(type, 0x82)
        XCTAssertEqual(String(decoding: p, as: UTF8.self), PadPC.updateTablet)
        XCTAssertTrue(t.waitClosed())
    }

    func testFiveWrongCodesLockEveryoneOut() throws {
        for _ in 0..<5 {
            let t = TestTablet(port: wifi)
            XCTAssertEqual(try t.pair(code: "000000"), .reject(PadPC.wrongCode))
            _ = t.waitClosed()
        }
        let t = TestTablet(port: wifi)
        t.send(t.link.hello(device: "x"))
        guard let (type, p) = t.next() else { return XCTFail("no answer") }
        XCTAssertEqual(type, 0x82)
        XCTAssertEqual(String(decoding: p, as: UTF8.self), PadPC.tooManyWrong)
        // the cable is not locked out
        let u = TestTablet(port: usb)
        defer { u.close() }
        guard case .welcome? = try u.pair(code: "") else { return XCTFail("the USB door was locked too") }
    }

    func testFramesArePacedByAcknowledgement() throws {
        var made = 0
        let lock = NSLock()
        server.frameSource = { done in
            lock.lock(); made += 1; lock.unlock()
            done(Data([0xFF, 0xD8, 0xFF, 0xD9]))
        }
        let t = TestTablet(port: wifi)
        defer { t.close() }
        guard case .welcome? = try t.pair(code: "123456") else { return XCTFail() }
        XCTAssertEqual(try t.nextOpened(), .frame(Data([0xFF, 0xD8, 0xFF, 0xD9])))
        Thread.sleep(forTimeInterval: 0.6)
        lock.lock(); let before = made; lock.unlock()
        XCTAssertEqual(before, 1, "no second picture before FRAME_ACK")
        t.sealed(PadProtocol.frameAck())
        XCTAssertEqual(try t.nextOpened(), .frame(Data([0xFF, 0xD8, 0xFF, 0xD9])))
    }

    func testASecondRightCodeTabletReplacesTheFirst() throws {
        let a = TestTablet(port: wifi)
        guard case .welcome? = try a.pair(code: "123456") else { return XCTFail() }
        let b = TestTablet(port: wifi)
        defer { b.close() }
        guard case .welcome? = try b.pair(code: "123456") else { return XCTFail() }
        XCTAssertTrue(a.waitClosed(), "the first tablet's connection ends")
        b.sealed(PadProtocol.ping())
        XCTAssertEqual(try b.nextOpened(), .pong)
    }

    func testSilentStrangerIsDropped() {
        let t = TestTablet(port: wifi)
        XCTAssertTrue(t.waitClosed(timeout: PadPC.helloWithin + 3), "no HELLO within 3 s: closed")
    }
}
#endif

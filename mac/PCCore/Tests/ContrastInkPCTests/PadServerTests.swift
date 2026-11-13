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

    init(port: UInt16, host: NWEndpoint.Host = "127.0.0.1") {
        c = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
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

    /// HELLO, and the CHALLENGE back; then nothing (a stranger holding a place). False when no CHALLENGE came.
    func stall() -> Bool {
        send(link.hello(device: "Stranger"))
        guard let (t, _) = next() else { return false }
        return t == PadProtocol.Kind.challenge.rawValue
    }

    func close() { c.cancel() }
}

/// A connection with no socket (the server's PadPipe), driven by the test: what the server writes is kept, and its
/// writes can be made to never finish (a tablet that stopped reading).
final class FakePipe: PadPipe {
    private let lock = NSCondition()
    private var queue: DispatchQueue?
    private var received: ((Data?) -> Void)?
    private var out: [Data] = []
    private var stalled = false
    private var cancelled = false
    var link = PadLink()

    func start(queue: DispatchQueue, received: @escaping (Data?) -> Void) {
        lock.lock(); self.queue = queue; self.received = received; lock.broadcast(); lock.unlock()
    }

    func send(_ data: Data, done: @escaping (Bool) -> Void) {
        lock.lock(); out.append(data); let s = stalled; lock.broadcast(); lock.unlock()
        if !s { done(true) }   // stalled: never done, as a socket the tablet doesn't read
    }

    func cancel() { lock.lock(); cancelled = true; lock.broadcast(); lock.unlock() }

    func stall() { lock.lock(); stalled = true; lock.unlock() }

    /// Bytes from the tablet (once the server has started reading).
    func feed(_ d: Data) {
        lock.lock()
        let until = Date().addingTimeInterval(5)
        while received == nil, lock.wait(until: until) {}
        let q = queue, r = received
        lock.unlock()
        q?.async { r?(d) }
    }

    /// The next message the server wrote (each write is one whole message).
    func next(timeout: TimeInterval = 5) -> (UInt8, Data)? {
        let until = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while out.isEmpty { if !lock.wait(until: until) { break } }
        guard !out.isEmpty else { return nil }
        let m = out.removeFirst()
        return (m[m.startIndex], Data(m.dropFirst(5)))
    }

    func waitCancelled(timeout: TimeInterval) -> Bool {
        let until = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while !cancelled { if !lock.wait(until: until) { return cancelled } }
        return true
    }

    /// HELLO → CHALLENGE → PROOF; the first answer after the PROOF, opened.
    func pair(code: String) throws -> PadMessage? {
        feed(link.hello(device: "Fake tablet"))
        guard let (t, p) = next(), t == PadProtocol.Kind.challenge.rawValue, let ch = PadChallenge.parse(p),
              let proof = link.proof(ch, code: code) else { return nil }
        feed(proof)
        guard let (t2, p2) = next() else { return nil }
        if t2 == PadProtocol.Kind.sealed.rawValue { return try link.open(p2) }
        return PadMessage.read(type: t2, payload: p2)
    }
}

final class PadServerTests: XCTestCase {
    private var server: PadServer!
    private var wifi: UInt16 = 0
    private var usb: UInt16 = 0
    private let events = DispatchQueue(label: "test events")
    private var received: [(UInt8, Data)] = []
    private var connections: [String?] = []

    override func setUpWithError() throws { restart() }

    /// A new server (the last one stopped) with these settings, the USB door open (unless `door` is false) and every
    /// tablet on it allowed (tests of the gate set their own).
    private func restart(door: Bool = true, _ change: (inout PadServer.Config) -> Void = { _ in }) {
        server?.stop()
        var config = PadServer.Config(name: "Test Mac")
        config.port = 0
        config.usbPort = 0
        config.advertise = false
        change(&config)
        wifi = 0; usb = 0
        events.sync { received = []; connections = [] }
        server = PadServer(key: P256.KeyAgreement.PrivateKey(), config: config, code: "123456", deliver: events)
        server.screenSize = { (2880, 1800) }
        server.onMessage = { [unowned self] t, p in self.received.append((t, p)) }
        server.onConnection = { [unowned self] name, _ in self.connections.append(name) }
        server.allowUsbDoor = { _, answer in answer(true) }
        server.start()
        if door { server.setUsbDoor(open: true) }
        let until = Date().addingTimeInterval(10)
        while Date() < until {
            let p = server.ports
            if p.wifi != 0, !door || p.usb != nil { wifi = p.wifi; usb = p.usb ?? 0; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertNotEqual(wifi, 0, "the Wi-Fi port is listening")
        if door { XCTAssertNotEqual(usb, 0, "the USB door is listening") }
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

    func testFiveWrongCodesLockThatAddressOut() throws {
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

    /// Wrong codes from one address don't lock out a tablet at another (IPv6 loopback stands in for it), and the
    /// server shows the 16-digit PC check.
    func testWrongCodesFromOneAddressLeaveOthersIn() throws {
        XCTAssertEqual(server.pcCheck.count, 19)
        XCTAssertEqual(server.pcCheck.split(separator: "-").count, 4)
        for _ in 0..<PadGuard.inARow {
            let t = TestTablet(port: wifi)
            XCTAssertEqual(try t.pair(code: "000000"), .reject(PadPC.wrongCode))
            _ = t.waitClosed()
        }
        let again = TestTablet(port: wifi)
        again.send(again.link.hello(device: "x"))
        guard let (type, p) = again.next() else { return XCTFail("no answer") }
        XCTAssertEqual(type, 0x82)
        XCTAssertEqual(String(decoding: p, as: UTF8.self), PadPC.tooManyWrong, "127.0.0.1 is locked out")
        let other = TestTablet(port: wifi, host: "::1")
        defer { other.close() }
        guard case .welcome? = try other.pair(code: "123456") else { return XCTFail("another address was locked out too") }
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

    // MARK: strangers holding places

    func testStalledWiFiStrangersDontStopACableSession() throws {
        // four strangers on the Wi-Fi, two from each of two addresses, each with a CHALLENGE and never a PROOF
        let strangers = [TestTablet(port: wifi), TestTablet(port: wifi), TestTablet(port: wifi, host: "::1"), TestTablet(port: wifi, host: "::1")]
        defer { strangers.forEach { $0.close() } }
        for s in strangers { XCTAssertTrue(s.stall(), "a stranger gets its CHALLENGE") }
        // the Wi-Fi is full: a fifth is closed at once
        let fifth = TestTablet(port: wifi, host: "::1")
        XCTAssertTrue(fifth.waitClosed(timeout: 2), "a fifth stranger on the Wi-Fi is closed")
        // the cable still works: the USB door and an iPad through usbmuxd
        let cable = TestTablet(port: usb)
        defer { cable.close() }
        guard case .welcome? = try cable.pair(code: "") else { return XCTFail("the USB door was full of Wi-Fi strangers") }
        let ipad = FakePipe()
        server.attach(ipad, door: .usbmux)
        guard case .welcome? = try ipad.pair(code: "") else { return XCTFail("usbmuxd's connection was refused") }
    }

    func testAThirdStalledStrangerFromOneAddressIsClosed() {
        let a = TestTablet(port: wifi), b = TestTablet(port: wifi)
        defer { a.close(); b.close() }
        XCTAssertTrue(a.stall())
        XCTAssertTrue(b.stall())
        let c = TestTablet(port: wifi)
        XCTAssertTrue(c.waitClosed(timeout: 2), "a third from the same address is closed")
        // another address still gets in line
        let d = TestTablet(port: wifi, host: "::1")
        defer { d.close() }
        XCTAssertTrue(d.stall(), "a stranger from another address is still answered")
    }

    func testNoProofWithinTheDeadlineCloses() {
        restart { $0.proofWithin = 1 }
        let t = TestTablet(port: wifi)
        XCTAssertTrue(t.stall())
        XCTAssertFalse(t.waitClosed(timeout: 0.5), "still waiting for the PROOF")
        XCTAssertTrue(t.waitClosed(timeout: 3), "no PROOF by the deadline: closed")
        // the place is free again
        let u = TestTablet(port: wifi)
        defer { u.close() }
        guard case .welcome? = try? u.pair(code: "123456") else { return XCTFail() }
    }

    func testATabletThatStopsReadingForThreeSecondsIsDropped() throws {
        let f = FakePipe()
        server.attach(f, door: .wifi("192.0.2.1"))
        guard case .welcome? = try f.pair(code: "123456") else { return XCTFail() }
        settle()
        XCTAssertNotNil(server.connected)
        f.stall()
        server.send(PadPC.pong())
        XCTAssertFalse(f.waitCancelled(timeout: 2), "kept while under 3 s")
        XCTAssertTrue(f.waitCancelled(timeout: 3), "a write stalled over 3 s: dropped")
        settle()
        XCTAssertNil(server.connected)
        XCTAssertEqual(events.sync { connections }, ["Fake tablet", nil])
    }

    func testTwentyWrongCodesMakeANewCode() throws {
        restart { $0.lockout = 0 }   // five in a row would otherwise lock out for 30 s
        var changed: [String] = []
        server.onCodeChanged = { changed.append($0) }   // on `events`
        for i in 0..<PadGuard.beforeNewCode {
            let t = TestTablet(port: wifi)
            XCTAssertEqual(try t.pair(code: "000000"), .reject(PadPC.wrongCode), "wrong code \(i + 1)")
            XCTAssertTrue(t.waitClosed())
        }
        settle()
        let now = server.code
        XCTAssertEqual(events.sync { changed }, [now])
        XCTAssertNotEqual(now, "123456")
        let old = TestTablet(port: wifi)
        XCTAssertEqual(try old.pair(code: "123456"), .reject(PadPC.wrongCode), "the old code no longer works")
        _ = old.waitClosed()
        let t = TestTablet(port: wifi)
        defer { t.close() }
        guard case .welcome? = try t.pair(code: now) else { return XCTFail("the new code works") }
    }

    // MARK: the USB door

    func testTheUsbDoorIsOpenOnlyWhenAsked() {
        restart(door: false)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNil(server.ports.usb, "closed until the app opens it (adb set up a tablet)")
        server.setUsbDoor(open: true)
        var port: UInt16?
        let until = Date().addingTimeInterval(5)
        while port == nil, Date() < until { port = server.ports.usb; Thread.sleep(forTimeInterval: 0.02) }
        guard let doorPort = port else { return XCTFail("the door opens") }
        let t = TestTablet(port: doorPort)
        XCTAssertTrue(t.stall(), "answered while open")
        t.close()
        server.setUsbDoor(open: false)
        let gone = Date().addingTimeInterval(5)
        while server.ports.usb != nil, Date() < gone { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertNil(server.ports.usb, "closed again (no tablet reversed)")
        let late = TestTablet(port: doorPort)
        XCTAssertFalse(late.stall(), "nothing answers on a closed door")
    }

    func testTheUsbDoorAsksThePresenter() throws {
        var asked: [String] = []
        var answers: [(Bool) -> Void] = []
        server.allowUsbDoor = { device, answer in asked.append(device); answers.append(answer) }   // on `events`
        // waiting for the presenter: nothing comes
        let t = TestTablet(port: usb)
        defer { t.close() }
        t.send(t.link.hello(device: "Pixel Tablet"))
        guard let (ct, cp) = t.next(), ct == PadProtocol.Kind.challenge.rawValue, let ch = PadChallenge.parse(cp),
              let proof = t.link.proof(ch, code: "") else { return XCTFail("no CHALLENGE") }
        t.send(proof)
        XCTAssertNil(t.next(timeout: 0.5), "no WELCOME before the presenter allows it")
        XCTAssertEqual(events.sync { asked }, ["Pixel Tablet"])
        events.sync { answers[0](true) }
        guard case .welcome? = try t.nextOpened() else { return XCTFail("allowed: let in") }
        // Deny: refused and closed
        let d = TestTablet(port: usb)
        events.sync { answers = [] }
        d.send(d.link.hello(device: "Other"))
        guard let (dt, dp) = d.next(), dt == PadProtocol.Kind.challenge.rawValue, let dch = PadChallenge.parse(dp),
              let dproof = d.link.proof(dch, code: "") else { return XCTFail("no CHALLENGE") }
        d.send(dproof)
        let until = Date().addingTimeInterval(5)
        while events.sync(execute: { answers.isEmpty }), Date() < until { Thread.sleep(forTimeInterval: 0.02) }
        events.sync { answers.first?(false) }
        XCTAssertEqual(try d.nextOpened(), .reject(PadPC.denied))
        XCTAssertTrue(d.waitClosed())
        // Wi-Fi and usbmuxd's iPads are never asked
        let ipad = FakePipe()
        server.attach(ipad, door: .usbmux)
        guard case .welcome? = try ipad.pair(code: "") else { return XCTFail() }
        XCTAssertEqual(events.sync { asked }, ["Pixel Tablet", "Other"])
    }

    func testNoAnswerFromThePresenterClosesAtTheDeadline() {
        restart { $0.proofWithin = 1 }
        server.allowUsbDoor = { _, _ in }   // never answered
        let t = TestTablet(port: usb)
        t.send(t.link.hello(device: "x"))
        guard let (ct, cp) = t.next(), let ch = PadChallenge.parse(cp), ct == PadProtocol.Kind.challenge.rawValue,
              let proof = t.link.proof(ch, code: "") else { return XCTFail() }
        t.send(proof)
        XCTAssertTrue(t.waitClosed(timeout: 3))
        XCTAssertNil(server.connected)
    }

    func testNoGateMeansNo() throws {
        server.allowUsbDoor = nil
        let t = TestTablet(port: usb)
        XCTAssertEqual(try t.pair(code: ""), .reject(PadPC.denied))
    }
}
#endif

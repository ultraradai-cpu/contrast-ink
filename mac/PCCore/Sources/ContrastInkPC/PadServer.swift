// The tablet link's server on the Mac (docs/pad-protocol.md): the Mac is the PC. It listens on TCP 47820 (or the next
// free port) advertised with Bonjour as _contrastink._tcp, and, only while an Android tablet has been set up with
// `adb reverse`, on its USB door 127.0.0.1:47830 (code ""); iPads on the cable come through usbmuxd (attachUsb). It
// lets in one tablet that proves it knows the code, sends it pictures of the screen (one at a time, paced by
// FRAME_ACK) and hands what it draws to the app. The same rules and limits as the Windows app's PadServer.cs. Everything
// runs on one serial queue; the app's handlers are called on `deliver` (the main queue).
#if canImport(Network) && canImport(CryptoKit)
import ContrastInkCore
import CryptoKit
import Foundation
import Network

/// One connection's bytes, whatever carries them (a network connection, or a usbmuxd socket to an iPad).
protocol PadPipe: AnyObject {
    /// Starts reading: `received` gets each block of bytes, then nil once (closed or failed). Called on `queue`.
    func start(queue: DispatchQueue, received: @escaping (Data?) -> Void)
    /// Writes; `done` (on any queue) says whether it went.
    func send(_ data: Data, done: @escaping (Bool) -> Void)
    func cancel()
}

final class NWPipe: PadPipe {
    let connection: NWConnection
    private var queue: DispatchQueue?
    private var received: ((Data?) -> Void)?
    private var ended = false
    init(_ c: NWConnection) { connection = c }

    func start(queue: DispatchQueue, received: @escaping (Data?) -> Void) {
        self.queue = queue
        self.received = received
        connection.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed, .cancelled: self?.end()
            default: break
            }
        }
        connection.start(queue: queue)
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty, !self.ended { self.received?(data) }
            if complete || error != nil { self.end(); return }
            self.read()
        }
    }

    private func end() {
        guard !ended else { return }
        ended = true
        received?(nil)
        received = nil
    }

    func send(_ data: Data, done: @escaping (Bool) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in done(error == nil) })
    }

    func cancel() { connection.cancel() }
}

/// A connected socket (an iPad through usbmuxd): read on its own thread, written with a 3-second send timeout (a
/// stalled tablet fails the write and is dropped). The fd number has one owner, the `io` queue: every write, the
/// shutdown on cancel and the one close happen there, and the close only once both the reader has ended and cancel
/// has happened, so nothing ever touches the number after it is closed (when it may already be another socket's).
final class FDPipe: PadPipe {
    private let fd: Int32
    private let io = DispatchQueue(label: "pad usb io")
    // on io only
    private var readerEnded = false, cancelled = false, closed = false

    init(fd: Int32) {
        self.fd = fd
        var tv = timeval(tv_sec: Int(PadPC.writeStall), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        // nothing else holds the pipe any more (the reader and every io block are done): no one can race this
        if !closed { Darwin.close(fd) }
    }

    func start(queue: DispatchQueue, received: @escaping (Data?) -> Void) {
        let fd = self.fd
        let t = Thread { [self] in
            // the fd stays open while this reads: it is closed only after readerEnded is set below
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                let d = Data(buf[0..<n])
                queue.async { received(d) }
            }
            queue.async { received(nil) }
            self.io.async { self.readerEnded = true; self.closeWhenDone() }
        }
        t.name = "pad usb read"
        t.start()
    }

    func send(_ data: Data, done: @escaping (Bool) -> Void) {
        io.async { [self] in
            guard !cancelled, !closed else { done(false); return }
            var ok = true
            data.withUnsafeBytes { raw in
                var at = 0
                while at < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + at, raw.count - at)
                    if n <= 0 { ok = false; return }
                    at += n
                }
            }
            done(ok)
        }
    }

    func cancel() {
        io.async { [self] in
            guard !cancelled else { return }
            cancelled = true
            if !closed { shutdown(fd, SHUT_RDWR) }   // wakes the reader; the fd is still ours here
            closeWhenDone()
        }
    }

    private func closeWhenDone() {
        guard readerEnded, cancelled, !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}

public final class PadServer {
    public struct Config {
        /// The Mac's name (CHALLENGE, WELCOME, and the Bonjour name).
        public var name: String
        /// The first Wi-Fi port tried; up to 9 more after it. 0: any free port (tests).
        public var port: UInt16 = PadProtocol.defaultPort
        /// The USB door's port on 127.0.0.1 (opened with setUsbDoor); 0: any free port (tests).
        public var usbPort: UInt16 = PadPC.usbPort
        /// Advertise with Bonjour (off in tests).
        public var advertise = true
        /// How long a stranger has for its PROOF after the CHALLENGE (and, on the USB door, for the presenter to
        /// allow it). Shorter only in tests.
        public var proofWithin: TimeInterval = PadPC.proofWithin
        /// A tablet that can't take messages this long is dropped.
        public var writeStall: TimeInterval = PadPC.writeStall
        /// How long five wrong codes in a row lock everyone out. Shorter only in tests.
        public var lockout: TimeInterval = PadGuard.lockout
        public init(name: String) { self.name = name }
    }

    /// Where a connection came from.
    enum Door: Equatable {
        /// The Wi-Fi port, from this address.
        case wifi(String)
        /// The loopback USB door (Android's `adb reverse`, or any program on this Mac).
        case usbDoor
        /// A connection this Mac opened itself through usbmuxd to an iPad on the cable.
        case usbmux

        var isWifi: Bool { if case .wifi = self { return true }; return false }
    }

    // the app's handlers, called on `deliver`
    /// A tablet connected (its name, whether by the cable) or went (nil).
    public var onConnection: ((String?, Bool) -> Void)?
    /// A new code, after too many wrong ones.
    public var onCodeChanged: ((String) -> Void)?
    /// A message from the tablet (strokes, hover, commands), in order.
    public var onMessage: ((UInt8, Data) -> Void)?
    /// The listeners changed (Wi-Fi port, USB door's port or nil when it is closed).
    public var onReady: ((UInt16, UInt16?) -> Void)?
    /// A listener couldn't be opened: what to tell the presenter, and the raw error for the log.
    public var onError: ((PadProblem, String) -> Void)?
    /// A tablet on the USB door (any program on this Mac can reach it) knows the empty code: may it draw? Asked with
    /// the tablet's name; answer once, on any queue. The tablet waits meanwhile, up to the PROOF deadline. Nil: no.
    /// The app asks the presenter the first time in each run and lets later ones in by itself.
    public var allowUsbDoor: ((String, @escaping (Bool) -> Void) -> Void)?
    /// The screen's size in pixels, for WELCOME. Called on the server's queue.
    public var screenSize: () -> (Int, Int) = { (1920, 1080) }
    /// Makes a picture of the screen (a JPEG) and calls back with it, or nil. Called on the server's queue, never
    /// twice at once; it may call back on any queue.
    public var frameSource: ((@escaping (Data?) -> Void) -> Void)?

    public let pcCheck: String
    private let pcKey: P256.KeyAgreement.PrivateKey
    private let config: Config
    private let deliver: DispatchQueue
    private let q = DispatchQueue(label: "pad server")
    private var guardian: PadGuard
    private var _code: String
    private var wifi: NWListener?, usb: NWListener?
    private var wifiPort: UInt16 = 0, usbDoor: UInt16?
    private var usbDoorWanted = false, usbDoorReported = false
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var current: Peer?
    private var timer: DispatchSourceTimer?
    private var running = false
    private var capturing = false
    private var lastFrame = Date.distantPast
    private var inbox = 0

    final class Peer {
        let pipe: PadPipe
        let door: Door
        var usb: Bool { !door.isWifi }
        var accept: PadAccept
        var frames = PadFrames(maxLength: PadPC.helloMax)
        /// 0: waiting for HELLO, 1: CHALLENGE sent, waiting for PROOF, 2: in, 3: refused (the REJECT on its way),
        /// 4: right PROOF on the USB door, waiting for the presenter to allow it
        var step = 0
        var deadline: Date
        var heard = Date()
        var counted = true    // among the strangers not yet in
        var closed = false
        var ackPending = false
        var sentAt = Date.distantPast
        var outbox: [Date] = []   // when each unfinished write began
        var name = ""
        var ended: (() -> Void)?
        init(pipe: PadPipe, door: Door, accept: PadAccept) {
            self.pipe = pipe; self.door = door; self.accept = accept
            deadline = Date().addingTimeInterval(PadPC.helloWithin)
        }
    }

    public init(key: P256.KeyAgreement.PrivateKey, config: Config, code: String? = nil, deliver: DispatchQueue = .main) {
        pcKey = key
        self.config = config
        self.deliver = deliver
        guardian = PadGuard(lockout: config.lockout)
        pcCheck = PadCrypto.check(key.publicKey.x963Representation)
        _code = code ?? PadPC.newCode()
    }

    /// The code a tablet must type. Changes after too many wrong ones (onCodeChanged).
    public var code: String { q.sync { _code } }
    /// The Wi-Fi port (0 until it is listening) and the USB door's port (nil when it isn't open).
    public var ports: (wifi: UInt16, usb: UInt16?) { q.sync { (wifiPort, usbDoor) } }
    /// The connected tablet: its name and whether it came by the cable.
    public var connected: (name: String, usb: Bool)? { q.sync { current.map { ($0.name, $0.usb) } } }

    public func start() {
        q.async { [self] in
            guard !running else { return }
            running = true
            listen(port: config.port, tries: config.port == 0 ? 1 : 10)
            if usbDoorWanted { openUsbDoor() }
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + 0.05, repeating: 0.05)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        q.sync { [self] in
            running = false
            timer?.cancel(); timer = nil
            wifi?.cancel(); wifi = nil
            closeUsbDoor()
            for p in Array(peers.values) { close(p) }
        }
    }

    /// Opens or closes the USB door (127.0.0.1, Android tablets through `adb reverse`). Any program on this Mac can
    /// reach a loopback port, so the app opens it only while adb has set up at least one tablet.
    public func setUsbDoor(open: Bool) {
        q.async { [self] in
            usbDoorWanted = open
            guard running else { return }
            if open { if usb == nil { openUsbDoor() } } else { closeUsbDoor() }
        }
    }

    /// Ends the tablet's connection.
    public func drop() { q.async { [self] in if let c = current { close(c) } } }

    /// To the connected tablet, if any, sealed. From any thread; never blocks.
    public func send(_ message: Data) { q.async { [self] in if let c = current { send(c, message) } } }

    /// An iPad's connection this Mac opened through usbmuxd (a socket that is now a pipe to the iPad's port 47830).
    /// No limit beyond the app's one per iPad. `ended` is called (on any queue) once that connection is over.
    public func attachUsb(fd: Int32, ended: @escaping () -> Void = {}) {
        q.async { [self] in
            guard running else { Darwin.close(fd); ended(); return }
            accept(FDPipe(fd: fd), door: .usbmux, ended: ended)
        }
    }

    /// Any pipe, as if it had come in by `door` (tests).
    func attach(_ pipe: PadPipe, door: Door, ended: @escaping () -> Void = {}) {
        q.async { [self] in
            guard running else { pipe.cancel(); ended(); return }
            accept(pipe, door: door, ended: ended)
        }
    }

    // MARK: listening

    private func listen(port: UInt16, tries: Int) {
        guard running else { return }
        let l: NWListener
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
        } catch {
            report(.wifiPort, "tablet link: can't listen on port \(port): \(error)")
            return
        }
        if config.advertise {
            // TXT v=2: the protocol version, as the Windows app advertises it
            l.service = NWListener.Service(name: config.name, type: PadProtocol.serviceType, domain: nil,
                                           txtRecord: Data([3]) + Data("v=\(PadProtocol.version)".utf8))
        }
        l.newConnectionHandler = { [weak self] c in self?.incoming(c, usb: false) }
        l.stateUpdateHandler = { [weak self, weak l] s in
            guard let self, let l, self.wifi === l else { return }
            switch s {
            case .ready:
                self.wifiPort = l.port?.rawValue ?? port
                self.ready()
            case .failed(let e):
                l.cancel()
                self.wifi = nil
                if tries > 1, port != 0 { self.listen(port: port + 1, tries: tries - 1) }
                else { self.report(.wifiPort, "tablet link: no free network port (\(e))") }
            default: break
            }
        }
        wifi = l
        l.start(queue: q)
    }

    private func openUsbDoor() {
        let port = config.usbPort
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // loopback only: reachable from this Mac (Android's adb reverse arrives here), never from the network
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.incoming(c, usb: true) }
            l.stateUpdateHandler = { [weak self, weak l] s in
                guard let self, let l, self.usb === l else { return }
                switch s {
                case .ready:
                    self.usbDoor = l.port?.rawValue ?? port
                    self.usbDoorReported = false
                    self.ready()
                case .failed(let e):
                    l.cancel()
                    self.usb = nil
                    self.usbDoor = nil
                    self.ready()
                    // tried again on the app's next setUsbDoor (every few seconds): said once
                    if !self.usbDoorReported {
                        self.usbDoorReported = true
                        self.report(.usbDoor, "tablet link: USB door 127.0.0.1:\(port) unavailable (\(e))")
                    }
                default: break
                }
            }
            usb = l
            l.start(queue: q)
        } catch {
            if !usbDoorReported { usbDoorReported = true; report(.usbDoor, "tablet link: USB door: \(error)") }
        }
    }

    private func closeUsbDoor() {
        guard let l = usb else { return }
        usb = nil
        l.cancel()
        if usbDoor != nil { usbDoor = nil; ready() }
    }

    private func ready() {
        let w = wifiPort, u = usbDoor
        deliver.async { [weak self] in self?.onReady?(w, u) }
    }

    private func report(_ problem: PadProblem, _ raw: String) { deliver.async { [weak self] in self?.onError?(problem, raw) } }

    /// Strangers not yet past the code (or not yet allowed in) whose door matches.
    private func strangers(_ match: (Door) -> Bool) -> Int { peers.values.reduce(0) { $0 + ($1.counted && match($1.door) ? 1 : 0) } }

    private func incoming(_ c: NWConnection, usb: Bool) {
        guard running else { c.cancel(); return }
        let door: Door
        if usb {
            // the USB door only ever hears this Mac itself, and only a few strangers at once
            guard case .hostPort(let host, _) = c.endpoint, Self.isLoopback(host),
                  strangers({ $0 == .usbDoor }) < PadPC.maxPendingUsbDoor else { c.cancel(); return }
            door = .usbDoor
        } else {
            // a few strangers on the Wi-Fi in all, and fewer from any one address: they can't fill every place
            let from = Self.address(c.endpoint)
            guard strangers({ $0.isWifi }) < PadPC.maxPending,
                  strangers({ $0 == .wifi(from) }) < PadPC.maxPendingPerAddress else { c.cancel(); return }
            door = .wifi(from)
        }
        accept(NWPipe(c), door: door)
    }

    static func isLoopback(_ h: NWEndpoint.Host) -> Bool {
        switch h {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a == IPv6Address("::ffff:127.0.0.1")
        case .name(let n, _): return n == "localhost" || n == "127.0.0.1" || n == "::1"
        @unknown default: return false
        }
    }

    /// The remote address a connection came from (an IPv4 address mapped into IPv6 as the IPv4 one; no zone).
    static func address(_ e: NWEndpoint) -> String {
        guard case .hostPort(let h, _) = e else { return "\(e)" }
        switch h {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a):
            if a.isIPv4Mapped, let v4 = a.asIPv4 { return "\(v4)" }
            return String("\(a)".split(separator: "%").first ?? "")
        case .name(let n, _): return n
        @unknown default: return "\(h)"
        }
    }

    private func accept(_ pipe: PadPipe, door: Door, ended: (() -> Void)? = nil) {
        let p = Peer(pipe: pipe, door: door, accept: PadAccept(pcKey: pcKey, name: config.name))
        p.ended = ended
        peers[ObjectIdentifier(p)] = p
        pipe.start(queue: q) { [weak self, weak p] data in
            guard let self, let p else { return }
            self.received(p, data)
        }
    }

    // MARK: one tablet

    private func received(_ p: Peer, _ data: Data?) {
        guard !p.closed, p.step != 3 else { return }   // refused: the REJECT is on its way, nothing more is read
        guard let data else { close(p); return }
        p.heard = Date()
        let messages: [(type: UInt8, payload: Data)]
        do { messages = try p.frames.feed(data) } catch { close(p); return }
        for (type, payload) in messages {
            if p.closed || p.step == 3 { return }
            switch p.step {
            case 0: hello(p, type, payload)
            case 1: proof(p, type, payload)
            case 4: break   // waiting for the presenter: a tablet sends nothing before WELCOME
            default: session(p, type, payload)
            }
        }
    }

    private func hello(_ p: Peer, _ type: UInt8, _ payload: Data) {
        switch p.accept.hello(type: type, payload: payload) {
        case .reject(let why): refuse(p, why)
        case .challenge(let m):
            if !p.usb && guardian.locked(Date()) { refuse(p, PadPC.tooManyWrong); return }
            write(p, m)
            p.step = 1
            p.deadline = Date().addingTimeInterval(config.proofWithin)
        }
    }

    /// The PROOF: opened, the tablet knows the code (it never crossed the network) and the session starts, replacing
    /// a connected tablet. Not opened: a wrong code, counted against guessing (not over the cable: no code there).
    /// On the USB door the presenter must allow it first (any program on this Mac could be knocking).
    private func proof(_ p: Peer, _ type: UInt8, _ payload: Data) {
        let right = p.accept.proof(type: type, payload: payload, code: p.usb ? "" : _code)
        let now = Date()
        if !p.usb && guardian.locked(now) { refuse(p, PadPC.tooManyWrong); return }
        guard right else {
            if !p.usb && guardian.wrong(now) {
                _code = PadPC.newCode()
                let c = _code
                deliver.async { [weak self] in self?.onCodeChanged?(c) }
            }
            refuse(p, PadPC.wrongCode)
            return
        }
        if !p.usb { guardian.right() }
        if p.door == .usbDoor {
            p.step = 4   // until the presenter answers, or the PROOF deadline passes
            let device = p.accept.device
            deliver.async { [weak self, weak p] in
                guard let self else { return }
                let answered: (Bool) -> Void = { [weak self, weak p] yes in
                    guard let self else { return }
                    self.q.async { if let p { self.allowed(p, yes) } }
                }
                if let ask = self.allowUsbDoor, p != nil { ask(device, answered) } else { answered(false) }
            }
            return
        }
        letIn(p)
    }

    private func allowed(_ p: Peer, _ yes: Bool) {
        guard !p.closed, p.step == 4 else { return }   // gone, or past its deadline
        if yes { letIn(p) } else { refuse(p, PadPC.denied) }
    }

    private func letIn(_ p: Peer) {
        p.step = 2
        p.frames.maxLength = PadProtocol.maxPayload
        p.name = p.accept.device
        p.heard = Date()
        p.counted = false
        let old = current
        current = p
        if let old { close(old) }   // the same tablet back after a drop, or another one the presenter chose
        let size = screenSize()
        send(p, PadPC.welcome(name: config.name, screenW: size.0, screenH: size.1))
        let name = p.name, usb = p.usb
        deliver.async { [weak self] in self?.onConnection?(name, usb) }
    }

    private func session(_ p: Peer, _ type: UInt8, _ payload: Data) {
        guard current === p else { close(p); return }   // replaced or dropped
        // in: only sealed messages, each opened in order (a replay, a change or other keys: closed)
        guard type == PadProtocol.Kind.sealed.rawValue, let inner = p.accept.open(payload) else { close(p); return }
        for (t, m) in inner {
            switch t {
            case PadProtocol.Kind.ping.rawValue: send(p, PadPC.pong())
            case PadProtocol.Kind.frameAck.rawValue: p.ackPending = false
            default:
                inbox += 1
                if inbox > PadPC.maxQueued { close(p); return }
                deliver.async { [weak self] in
                    self?.onMessage?(t, m)
                    self?.q.async { self?.inbox -= 1 }
                }
            }
        }
    }

    private func refuse(_ p: Peer, _ why: String) {
        let m = PadPC.reject(why)
        p.outbox.append(Date())
        p.pipe.send(m) { [weak self, weak p] _ in
            guard let self, let p else { return }
            self.q.async { self.close(p) }
        }
        p.step = 3   // nothing more is read
    }

    /// A message in the clear (only the CHALLENGE).
    private func write(_ p: Peer, _ m: Data) {
        p.outbox.append(Date())
        p.pipe.send(m) { [weak self, weak p] ok in
            guard let self, let p else { return }
            self.q.async { self.written(p, ok) }
        }
    }

    /// A message to a tablet that is in: sealed. A full outbox means it isn't keeping up: it is dropped.
    private func send(_ p: Peer, _ m: Data) {
        guard !p.closed, p.step == 2, let wire = p.accept.seal(m) else { return }
        if p.outbox.count >= PadPC.maxOutbox { close(p); return }
        write(p, wire)
    }

    private func written(_ p: Peer, _ ok: Bool) {
        if !p.outbox.isEmpty { p.outbox.removeFirst() }
        if !ok { close(p) }
    }

    private func close(_ p: Peer) {
        guard !p.closed else { return }
        p.closed = true
        p.counted = false
        p.pipe.cancel()
        p.ended?()
        p.ended = nil
        peers[ObjectIdentifier(p)] = nil
        if current === p {
            current = nil
            deliver.async { [weak self] in self?.onConnection?(nil, false) }
        }
    }

    // MARK: time

    private func tick() {
        let now = Date()
        for p in Array(peers.values) {
            if p.step != 2 && now > p.deadline { close(p); continue }   // a byte now and then keeps no stranger in
            if p.step == 2 && now.timeIntervalSince(p.heard) > PadPC.silence { close(p); continue }
            if let first = p.outbox.first, now.timeIntervalSince(first) > config.writeStall { close(p); continue }
        }
        // pictures of the screen, one at a time: the next only after the tablet says it showed the last
        guard let c = current, !capturing, let source = frameSource else { return }
        if c.ackPending && now.timeIntervalSince(c.sentAt) > 3 { c.ackPending = false }   // a lost acknowledgement
        guard !c.ackPending, now.timeIntervalSince(lastFrame) >= PadPC.frameInterval else { return }
        capturing = true
        source { [weak self] jpeg in
            guard let self else { return }
            self.q.async {
                self.capturing = false
                self.lastFrame = Date()
                guard let jpeg else { self.lastFrame = Date().addingTimeInterval(0.4); return }   // try again later
                guard let c = self.current, c === self.current, !c.closed else { return }
                c.ackPending = true
                c.sentAt = Date()
                self.send(c, PadPC.frame(jpeg))
            }
        }
    }
}


/// Asks usbmuxd (Apple's USB service, /var/run/usbmuxd) which iPhones and iPads are plugged in, and opens a
/// connection to a port on one of them through the cable. Blocking: call it off the main thread.
public enum UsbMuxClient {
    /// The devices plugged in by cable; empty when usbmuxd can't be reached.
    public static func devices() -> [Int] {
        guard let fd = open() else { return [] }
        defer { Darwin.close(fd) }
        guard let body = ask(fd, UsbMux.listDevices()) else { return [] }
        return UsbMux.devices(body)
    }

    /// A socket that is now a pipe to `port` on the device; nil when nothing listens there.
    public static func connect(device: Int, port: UInt16) -> Int32? {
        guard let fd = open() else { return nil }
        if let body = ask(fd, UsbMux.connect(device: device, port: port)), UsbMux.result(body) == 0 {
            var tv = timeval(tv_sec: 0, tv_usec: 0)   // no read timeout from now on: the session's silence rule applies
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            return fd
        }
        Darwin.close(fd)
        return nil
    }

    static func open() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(UsbMux.socketPath.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: b) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { Darwin.close(fd); return nil }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func ask(_ fd: Int32, _ packet: Data) -> Data? {
        let sent = packet.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard sent == packet.count, let head = readExactly(fd, 16), let n = UsbMux.bodyLength(header: head) else { return nil }
        return readExactly(fd, n)
    }

    static func readExactly(_ fd: Int32, _ n: Int) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: max(n, 1))
        while out.count < n {
            let k = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, n - out.count) }
            if k <= 0 { return nil }
            out.append(contentsOf: buf[0..<k])
        }
        return out
    }
}
#endif

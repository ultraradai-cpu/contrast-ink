// The tablet link's server on the Mac (docs/pad-protocol.md): the Mac is the PC. It listens on TCP 47820 (or the next
// free port) advertised with Bonjour as _contrastink._tcp, and on its USB door 127.0.0.1:47830 (code ""), lets in one
// tablet that proves it knows the code, sends it pictures of the screen (one at a time, paced by FRAME_ACK) and hands
// what it draws to the app. The same rules and limits as the Windows app's PadServer.cs. Everything runs on one
// serial queue; the app's handlers are called on `deliver` (the main queue).
#if canImport(Network) && canImport(CryptoKit)
import ContrastInkCore
import CryptoKit
import Foundation
import Network

/// One connection's bytes, whatever carries them (a network connection, or a usbmuxd socket to an iPad).
protocol PadPipe: AnyObject {
    /// Starts reading: `received` gets each block of bytes, then nil once (closed or failed). Called on `queue`.
    func start(queue: DispatchQueue, received: @escaping (Data?) -> Void)
    /// Writes; `done` (on the queue) says whether it went.
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

/// A connected socket (an iPad through usbmuxd): read on its own thread, written on a serial queue with a 3-second
/// send timeout (a stalled tablet fails the write and is dropped).
final class FDPipe: PadPipe {
    private let fd: Int32
    private let writes = DispatchQueue(label: "pad usb write")
    private let lock = NSLock()
    private var cancelled = false
    init(fd: Int32) {
        self.fd = fd
        var tv = timeval(tv_sec: Int(PadPC.writeStall), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    func start(queue: DispatchQueue, received: @escaping (Data?) -> Void) {
        let fd = self.fd
        let t = Thread { [self] in
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                let d = Data(buf[0..<n])
                queue.async { received(d) }
            }
            queue.async { received(nil) }
            self.writes.async { Darwin.close(fd) }   // after the last write
        }
        t.name = "pad usb read"
        t.start()
    }

    func send(_ data: Data, done: @escaping (Bool) -> Void) {
        let fd = self.fd
        writes.async { [self] in
            var ok = true
            data.withUnsafeBytes { raw in
                var at = 0
                while at < raw.count {
                    lock.lock(); let gone = cancelled; lock.unlock()
                    if gone { ok = false; return }
                    let n = Darwin.write(fd, raw.baseAddress! + at, raw.count - at)
                    if n <= 0 { ok = false; return }
                    at += n
                }
            }
            done(ok)
        }
    }

    func cancel() {
        lock.lock(); let was = cancelled; cancelled = true; lock.unlock()
        if !was { shutdown(fd, SHUT_RDWR) }
    }
}

public final class PadServer {
    public struct Config {
        /// The Mac's name (CHALLENGE, WELCOME, and the Bonjour name).
        public var name: String
        /// The first Wi-Fi port tried; up to 9 more after it. 0: any free port (tests).
        public var port: UInt16 = PadProtocol.defaultPort
        /// The USB door on 127.0.0.1; 0: any free port (tests); nil: none.
        public var usbPort: UInt16? = PadPC.usbPort
        /// Advertise with Bonjour (off in tests).
        public var advertise = true
        public init(name: String) { self.name = name }
    }

    // the app's handlers, called on `deliver`
    /// A tablet connected (its name, whether by the cable) or went (nil).
    public var onConnection: ((String?, Bool) -> Void)?
    /// A new code, after too many wrong ones.
    public var onCodeChanged: ((String) -> Void)?
    /// A message from the tablet (strokes, hover, commands), in order.
    public var onMessage: ((UInt8, Data) -> Void)?
    /// The listeners are up (Wi-Fi port, USB port), or one failed (its error, for the log).
    public var onReady: ((UInt16, UInt16?) -> Void)?
    public var onError: ((String) -> Void)?
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
    private var guardian = PadGuard()
    private var _code: String
    private var wifi: NWListener?, usb: NWListener?
    private var wifiPort: UInt16 = 0, usbDoor: UInt16?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var current: Peer?
    private var pending = 0
    private var timer: DispatchSourceTimer?
    private var running = false
    private var capturing = false
    private var lastFrame = Date.distantPast
    private var inbox = 0

    final class Peer {
        let pipe: PadPipe
        let usb: Bool
        var accept: PadAccept
        var frames = PadFrames(maxLength: PadPC.helloMax)
        var step = 0          // 0: waiting for HELLO, 1: CHALLENGE sent, waiting for PROOF, 2: in
        var deadline: Date
        var heard = Date()
        var counted = true    // among the strangers not yet in
        var closed = false
        var ackPending = false
        var sentAt = Date.distantPast
        var outbox: [Date] = []   // when each unfinished write began
        var name = ""
        init(pipe: PadPipe, usb: Bool, accept: PadAccept) {
            self.pipe = pipe; self.usb = usb; self.accept = accept
            deadline = Date().addingTimeInterval(PadPC.helloWithin)
        }
    }

    public init(key: P256.KeyAgreement.PrivateKey, config: Config, code: String? = nil, deliver: DispatchQueue = .main) {
        pcKey = key
        self.config = config
        self.deliver = deliver
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
            if let p = config.usbPort { openUsbDoor(p) }
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
            usb?.cancel(); usb = nil
            for p in Array(peers.values) { close(p) }
        }
    }

    /// Ends the tablet's connection.
    public func drop() { q.async { [self] in if let c = current { close(c) } } }

    /// To the connected tablet, if any, sealed. From any thread; never blocks.
    public func send(_ message: Data) { q.async { [self] in if let c = current { send(c, message) } } }

    /// An iPad's connection opened through usbmuxd (a socket that is now a pipe to the iPad's port 47830).
    public func attachUsb(fd: Int32) {
        q.async { [self] in
            guard running, pending < PadPC.maxPending else { Darwin.close(fd); return }
            accept(FDPipe(fd: fd), usb: true)
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
            report("tablet link: can't listen on port \(port): \(error)")
            return
        }
        if config.advertise {
            // TXT v=2: the protocol version, as the Windows app advertises it
            l.service = NWListener.Service(name: config.name, type: PadProtocol.serviceType, domain: nil,
                                           txtRecord: Data([3]) + Data("v=\(PadProtocol.version)".utf8))
        }
        l.newConnectionHandler = { [weak self] c in self?.incoming(c, usb: false) }
        l.stateUpdateHandler = { [weak self, weak l] s in
            guard let self, let l else { return }
            switch s {
            case .ready:
                self.wifiPort = l.port?.rawValue ?? port
                self.deliver.async { self.onReady?(self.wifiPort, self.usbDoor) }
            case .failed(let e):
                l.cancel()
                if self.wifi === l { self.wifi = nil }
                if tries > 1, port != 0 { self.listen(port: port + 1, tries: tries - 1) }
                else { self.report("tablet link: no free network port (\(e))") }
            default: break
            }
        }
        wifi = l
        l.start(queue: q)
    }

    private func openUsbDoor(_ port: UInt16) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // loopback only: reachable from this Mac (Android's adb reverse arrives here), never from the network
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.incoming(c, usb: true) }
            l.stateUpdateHandler = { [weak self, weak l] s in
                guard let self, let l else { return }
                switch s {
                case .ready:
                    self.usbDoor = l.port?.rawValue ?? port
                    self.deliver.async { self.onReady?(self.wifiPort, self.usbDoor) }
                case .failed(let e):
                    l.cancel()
                    if self.usb === l { self.usb = nil; self.usbDoor = nil }
                    self.report("tablet link: USB door 127.0.0.1:\(port) unavailable (\(e))")
                default: break
                }
            }
            usb = l
            l.start(queue: q)
        } catch {
            report("tablet link: USB door: \(error)")
        }
    }

    private func report(_ text: String) { deliver.async { [weak self] in self?.onError?(text) } }

    private func incoming(_ c: NWConnection, usb: Bool) {
        guard running, pending < PadPC.maxPending else { c.cancel(); return }
        if usb {
            // the USB door only ever hears this Mac itself
            guard case .hostPort(let host, _) = c.endpoint, Self.isLoopback(host) else { c.cancel(); return }
        }
        accept(NWPipe(c), usb: usb)
    }

    static func isLoopback(_ h: NWEndpoint.Host) -> Bool {
        switch h {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a == IPv6Address("::ffff:127.0.0.1")
        case .name(let n, _): return n == "localhost" || n == "127.0.0.1" || n == "::1"
        @unknown default: return false
        }
    }

    private func accept(_ pipe: PadPipe, usb: Bool) {
        pending += 1
        let p = Peer(pipe: pipe, usb: usb, accept: PadAccept(pcKey: pcKey, name: config.name))
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
            p.deadline = Date().addingTimeInterval(PadPC.proofWithin)
        }
    }

    /// The PROOF: opened, the tablet knows the code (it never crossed the network) and the session starts, replacing
    /// a connected tablet. Not opened: a wrong code, counted against guessing (not over the cable: no code there).
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
        p.step = 2
        p.frames.maxLength = PadProtocol.maxPayload
        p.name = p.accept.device
        p.heard = now
        if p.counted { p.counted = false; pending -= 1 }
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
        p.pipe.cancel()
        if p.counted { p.counted = false; pending -= 1 }
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
            if let first = p.outbox.first, now.timeIntervalSince(first) > PadPC.writeStall { close(p); continue }
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

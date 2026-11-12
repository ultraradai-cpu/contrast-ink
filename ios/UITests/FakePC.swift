import CryptoKit
import Foundation
import Network

/// A pretend PC for the pad-mode UI tests: listens on the Mac's loopback (the simulator shares the Mac's network,
/// so the app reaches it at 127.0.0.1) and speaks version 2 of the link exactly as a PC does: CHALLENGE with its
/// own key, checks PROOF with its code, then WELCOME, STATE and FRAMEs sealed, the next FRAME only after FRAME_ACK,
/// and the PC's exact REJECT texts. It keeps every message the app sends (opened), in order, with which connection
/// it came on. Written straight from docs/pad-protocol.md with CryptoKit, not with the app's own code, so it checks
/// the app against the spec and not against itself.
final class FakePC {
    struct Message {
        let type: UInt8
        let payload: Data
        /// It came inside a SEALED message (everything after PROOF must).
        let sealed: Bool
        /// Which connection it came on: 1 for the first.
        let connection: Int
    }

    // the PC's REJECT texts, word for word (docs/pad-protocol.md)
    static let rejectOldTablet = "Please update Contrast Ink on the tablet."
    static let rejectWrongCode = "Wrong code: type the code Contrast Ink shows on the PC (⚙ Settings)."

    /// The spec's test-vector PC key: its PC check is 6FC6-6A90.
    static let vectorKey = try! P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))

    let name: String
    let code: String
    private var key: P256.KeyAgreement.PrivateKey

    private let queue = DispatchQueue(label: "fake-pc")
    private let lock = NSLock()
    private var listener: NWListener?
    private var session: Session?
    private var connections = 0
    private var received: [Message] = []
    /// The picture sent after WELCOME, and again 0.1 s after each FRAME_ACK (nil: only the test sends FRAMEs).
    private var paced: Data?
    private(set) var port: UInt16 = 0

    /// One connection: its bytes so far, how far it got, and its two directions' keys once PROOF is in.
    private final class Session {
        let c: NWConnection
        let id: Int
        var buffer = Data()
        var stage = 0   // 0: waiting for HELLO, 1: CHALLENGE sent, waiting for PROOF, 2: in
        var tabletKey: Data?
        var salt = Data()
        var toPC: SymmetricKey?, toTablet: SymmetricKey?
        var sent: UInt64 = 0, opened: UInt64 = 0
        init(_ c: NWConnection, _ id: Int) { self.c = c; self.id = id }
    }

    init(name: String, code: String = "123456", key: P256.KeyAgreement.PrivateKey = FakePC.vectorKey) {
        self.name = name
        self.code = code
        self.key = key
    }

    /// The PC check this PC's screen would show next to the code.
    var check: String { Self.check(key.publicKey.x963Representation) }

    static func check(_ point: Data) -> String {
        let h = SHA256.hash(data: point).prefix(4).map { String(format: "%02X", $0) }.joined()
        return "\(h.prefix(4))-\(h.suffix(4))"
    }

    /// Another key (as if Contrast Ink were reinstalled on the PC, or another machine took its name).
    func setKey(_ k: P256.KeyAgreement.PrivateKey) { queue.sync { key = k } }

    /// Send `picture` after WELCOME and then one after each FRAME_ACK (nil: stop).
    func pace(_ picture: Data?) {
        queue.async {
            self.paced = picture
            if let picture, let s = self.session, s.stage == 2 { self.sendSealed(0x83, picture, on: s) }
        }
    }

    /// Starts listening on a free port (or `port`, when set from an earlier run); false if it couldn't.
    func start(port wanted: UInt16 = 0) -> Bool {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: wanted == 0 ? .any : NWEndpoint.Port(rawValue: wanted)!)
        guard let l = try? NWListener(using: params) else { return false }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { s in if case .ready = s { ready.signal() } }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
        guard ready.wait(timeout: .now() + 10) == .success, let p = l.port?.rawValue else { return false }
        port = p
        return true
    }

    func stop() {
        queue.sync {
            session?.c.cancel()
            session = nil
            listener?.cancel()
        }
    }

    /// The connection goes, as when the Wi-Fi drops: the app should come back by itself.
    func drop() { queue.sync { session?.c.cancel(); session = nil } }

    /// Connections made so far.
    var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return connections }

    /// The cable PC: connects to the app's USB door, 127.0.0.1:`port`, as the PC does through usbmuxd (the simulator
    /// shares the Mac's loopback), trying again until the app listens. Then it is the PC on that connection: it waits
    /// for HELLO and answers as on Wi-Fi (with this FakePC's code, "" for the cable). False if it never got through.
    func dial(port: UInt16 = 47830, timeout: TimeInterval = 20) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let done = DispatchSemaphore(value: 0)
            let ready = Flag()
            c.stateUpdateHandler = { s in
                switch s {
                case .ready: ready.set(); done.signal()
                case .waiting, .failed, .cancelled: done.signal()
                default: break
                }
            }
            c.start(queue: queue)
            _ = done.wait(timeout: .now() + 2)
            if ready.isSet {
                queue.sync {
                    c.stateUpdateHandler = nil
                    self.register(c)
                }
                return true
            }
            queue.sync { c.stateUpdateHandler = nil; c.cancel() }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Waits until the app has closed that connection.
    func waitClosed(connection: Int, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            lock.lock(); let gone = closed.contains(connection); lock.unlock()
            if gone { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private var closed = Set<Int>()

    /// A yes/no set on the network queue and read on the test's thread.
    private final class Flag {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func accept(_ c: NWConnection) {
        register(c)
        c.start(queue: queue)
    }

    private func register(_ c: NWConnection) {
        // a new connection replaces the one before (the same tablet back after a Wi-Fi drop), as the PC does
        session?.c.cancel()
        lock.lock(); connections += 1; let id = connections; lock.unlock()
        let s = Session(c, id)
        session = s
        read(s)
    }

    private func read(_ s: Session) {
        s.c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.got(data, on: s) }
            if done || error != nil {
                self.lock.lock(); self.closed.insert(s.id); self.lock.unlock()
                return
            }
            if self.session === s { self.read(s) }
        }
    }

    private func got(_ data: Data, on s: Session) {
        s.buffer.append(data)
        while s.buffer.count >= 5 {
            let b = [UInt8](s.buffer.prefix(5))
            let len = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
            guard s.buffer.count >= 5 + len else { break }
            let type = b[0], payload = Data(s.buffer.dropFirst(5).prefix(len))
            s.buffer = Data(s.buffer.dropFirst(5 + len))
            handle(type, payload, on: s)
            if session !== s { return }
        }
    }

    private func record(_ type: UInt8, _ payload: Data, sealed: Bool, on s: Session) {
        lock.lock(); received.append(Message(type: type, payload: payload, sealed: sealed, connection: s.id)); lock.unlock()
    }

    private func handle(_ type: UInt8, _ payload: Data, on s: Session) {
        switch s.stage {
        case 0:
            record(type, payload, sealed: false, on: s)
            guard type == 0x01,
                  let h = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  h["code"] == nil, h["version"] as? Int == 2,
                  let k = (h["key"] as? String).flatMap({ Data(base64Encoded: $0) }), k.count == 65
            else { return reject(Self.rejectOldTablet, on: s) }
            s.tabletKey = k
            s.salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            let json: [String: String] = ["key": key.publicKey.x963Representation.base64EncodedString(),
                                          "salt": s.salt.base64EncodedString(), "name": name]
            send(0x86, try! JSONSerialization.data(withJSONObject: json), on: s)
            s.stage = 1
        case 1:
            record(type, payload, sealed: false, on: s)
            guard type == 0x04, let k = s.tabletKey,
                  let pub = try? P256.KeyAgreement.PublicKey(x963Representation: k),
                  let secret = try? key.sharedSecretFromKeyAgreement(with: pub) else { return reject(Self.rejectWrongCode, on: s) }
            let x = secret.withUnsafeBytes { Data($0) }
            let keys = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: SHA256.hash(data: x)), salt: s.salt,
                                              info: Data(("contrastink pad v2 " + code).utf8), outputByteCount: 64)
            let bytes = keys.withUnsafeBytes { Data($0) }
            s.toPC = SymmetricKey(data: bytes.prefix(32))
            s.toTablet = SymmetricKey(data: bytes.suffix(32))
            // PROOF: COMMAND "hello" sealed with counter 1. A wrong code's keys can't open it.
            guard let inner = open(payload, on: s), inner == Data([0x20, 0, 0, 0, 5]) + Data("hello".utf8)
            else { return reject(Self.rejectWrongCode, on: s) }
            s.stage = 2
            sendSealed(0x81, Data(#"{"name":"\#(name)","screenW":1600,"screenH":900,"version":2}"#.utf8), on: s)
            sendSealed(0x84, Data(#"{"tool":"pen","color":0,"width":1,"opacity":1.0,"fading":false,"canUndo":false}"#.utf8), on: s)
            if let paced { sendSealed(0x83, paced, on: s) }
        default:
            guard type == 0x7F else { return record(type, payload, sealed: false, on: s) }   // in the clear: the test fails on it
            guard let inner = open(payload, on: s), inner.count >= 5 else { s.c.cancel(); return }   // altered or replayed: closed
            let t = inner[inner.startIndex], p = Data(inner.dropFirst(5))
            record(t, p, sealed: true, on: s)
            if t == 0x02 { sendSealed(0x85, Data(), on: s) }   // PING → PONG
            if t == 0x03, paced != nil {   // FRAME_ACK: the next picture in a moment
                queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, self.session === s, let p = self.paced else { return }
                    self.sendSealed(0x83, p, on: s)
                }
            }
        }
    }

    private func reject(_ why: String, on s: Session) {
        send(0x82, Data(why.utf8), on: s)
        queue.asyncAfter(deadline: .now() + 0.3) { s.c.cancel() }   // then the PC closes
    }

    /// A SEALED payload → the whole message inside, or nil (another key, altered, or a counter not above the last).
    private func open(_ payload: Data, on s: Session) -> Data? {
        let p = [UInt8](payload)
        guard let k = s.toPC, p.count >= 28, p[0..<4] == [0, 0, 0, 0] else { return nil }
        let n = p[4..<12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard n > s.opened,
              let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: p[0..<12]), ciphertext: p[12..<(p.count - 16)], tag: p[(p.count - 16)...]),
              let m = try? AES.GCM.open(box, using: k) else { return nil }
        s.opened = n
        return m
    }

    private static func header(_ type: UInt8, _ n: Int) -> Data {
        Data([type, UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
    }

    private func send(_ type: UInt8, _ payload: Data, on s: Session) {
        s.c.send(content: Self.header(type, payload.count) + payload, completion: .idempotent)
    }

    private func sendSealed(_ type: UInt8, _ payload: Data, on s: Session) {
        guard let k = s.toTablet else { return }
        s.sent += 1
        let nonce = Data([0, 0, 0, 0] + (0..<8).map { UInt8(s.sent >> (56 - 8 * UInt64($0)) & 0xFF) })
        let box = try! AES.GCM.seal(Self.header(type, payload.count) + payload, using: k, nonce: AES.GCM.Nonce(data: nonce))
        send(0x7F, nonce + box.ciphertext + box.tag, on: s)
    }

    /// A message from the test, sealed, on the current connection (a FRAME, a STATE).
    func send(_ type: UInt8, _ payload: Data) {
        queue.async { if let s = self.session, s.stage == 2 { self.sendSealed(type, payload, on: s) } }
    }

    func send(_ type: UInt8, json: String) { send(type, Data(json.utf8)) }

    var messages: [Message] { lock.lock(); defer { lock.unlock() }; return received }

    /// Waits until a message of this type has arrived (after the first `after` messages); returns its index.
    @discardableResult
    func waitFor(_ type: UInt8, after: Int = 0, timeout: TimeInterval = 10, where ok: (Message) -> Bool = { _ in true }) -> Int? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let all = messages
            if after < all.count, let i = all[after...].firstIndex(where: { $0.type == type && ok($0) }) { return i }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    // MARK: reading the app's payloads

    static func f32(_ d: Data, at i: Int) -> Double {
        let b = [UInt8](d)
        let bits = UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
        return Double(Float(bitPattern: bits))
    }

    /// STROKE_POINTS: u16 n, then n × (f32 x, f32 y).
    static func points(_ d: Data) -> [(x: Double, y: Double)] {
        let b = [UInt8](d)
        guard b.count >= 2 else { return [] }
        let n = Int(b[0]) << 8 | Int(b[1])
        guard b.count == 2 + n * 8 else { return [] }
        return (0..<n).map { (f32(d, at: 2 + $0 * 8), f32(d, at: 6 + $0 * 8)) }
    }
}

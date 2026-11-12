import Foundation
import Network

/// A pretend PC for the pad-mode UI test: listens on the Mac's loopback (the simulator shares the Mac's network,
/// so the app reaches it at 127.0.0.1), answers PINGs, and keeps every message the app sends, in order.
/// Written straight from docs/pad-protocol.md rather than with the app's own code, so it checks the app against
/// the spec and not against itself.
final class FakePC {
    struct Message { let type: UInt8; let payload: Data }

    private let queue = DispatchQueue(label: "fake-pc")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    private var received: [Message] = []
    private(set) var port: UInt16 = 0

    /// Starts listening on a free port; false if it couldn't within a few seconds.
    func start() -> Bool {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
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
        connection?.cancel()
        listener?.cancel()
    }

    private func accept(_ c: NWConnection) {
        connection?.cancel()
        connection = c
        c.start(queue: queue)
        read(c)
    }

    private func read(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.got(data) }
            if !done && error == nil { self.read(c) }
        }
    }

    private func got(_ data: Data) {
        buffer.append(data)
        while buffer.count >= 5 {
            let b = [UInt8](buffer.prefix(5))
            let len = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
            guard buffer.count >= 5 + len else { break }
            let m = Message(type: b[0], payload: Data(buffer.dropFirst(5).prefix(len)))
            buffer = Data(buffer.dropFirst(5 + len))
            lock.lock(); received.append(m); lock.unlock()
            if m.type == 0x02 { send(0x85, Data()) }   // PING → PONG
        }
    }

    func send(_ type: UInt8, _ payload: Data) {
        let n = UInt32(payload.count)
        var d = Data([type, UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        d.append(payload)
        queue.async { self.connection?.send(content: d, completion: .idempotent) }
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

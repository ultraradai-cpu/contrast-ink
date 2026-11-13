import ContrastInkCore
import Foundation
import Network
import UIKit

/// The USB door of pad mode (docs/pad-protocol.md, "USB (phase 2)"): while pad mode is open the iPad listens on its
/// own loopback address, 127.0.0.1:47830. The PC reaches it through the cable (Apple's usbmuxd delivers its
/// connections on the iPad's loopback); nothing on the Wi-Fi can. On a connection the iPad speaks first (HELLO) and
/// runs the version-2 handshake with the empty code. The cable is not proof on its own (any app on the iPad can reach
/// its loopback door), so the first time with a PC its check is shown and the PROOF waits for "It matches", as on
/// Wi-Fi. Once the PC's sealed WELCOME has come, the open connection is handed to the PadClient, which then uses it
/// instead of Wi-Fi.
@MainActor
final class PadCable {
    static let port: UInt16 = 47830

    weak var client: PadClient?
    /// The key the presenter chose to trust with "Connect anyway" after a cable warning.
    var acceptKey: Data?
    /// The key of a PC whose check the presenter said doesn't match: its next tries (the PC dials every few seconds)
    /// are closed without asking again, until pad mode is opened again.
    private var refusedKey: Data?

    private var listener: NWListener?
    private var restart: DispatchWorkItem?
    /// The connection being let in (its handshake), at most one.
    private var candidate: Candidate?

    private final class Candidate {
        let c: NWConnection
        var decoder = PadDecoder()
        var link = PadLink()
        var handshake = PadHandshake()
        var pending: (name: String, key: Data)?
        /// The PROOF, held while the presenter compares the PC check (the first time with this PC).
        var heldProof: Data?
        init(_ c: NWConnection) { self.c = c }
    }

    /// The handshake must be done this long after the connection came: a PC that says nothing is closed.
    static let handshakeLimit: TimeInterval = 10

    func start() {
        guard listener == nil else { return }
        restart?.cancel()
        restart = nil
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // bound to the loopback address: usbmuxd's connections arrive there, the Wi-Fi can never reach it
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { tcp.noDelay = true }
        guard let l = try? NWListener(using: params) else { return retryLater() }
        l.newConnectionHandler = { [weak self] c in
            Task { @MainActor [weak self] in
                guard let self else { c.cancel(); return }
                self.arrived(c)
            }
        }
        l.stateUpdateHandler = { [weak self, weak l] s in
            Task { @MainActor [weak self, weak l] in
                guard let self, let l, self.listener === l else { return }
                if case .failed = s {
                    // the port was busy (another app, an earlier run closing): try again in a moment
                    self.listener?.cancel()
                    self.listener = nil
                    self.retryLater()
                }
            }
        }
        listener = l
        l.start(queue: .main)
    }

    func stop() {
        restart?.cancel()
        restart = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        endCandidate()
        acceptKey = nil
        refusedKey = nil
    }

    private func retryLater() {
        let work = DispatchWorkItem { [weak self] in Task { @MainActor [weak self] in self?.start() } }
        restart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Only the loopback: anything else (which the binding already rules out) is closed at once.
    private static func isLoopback(_ e: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = e else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a.asIPv4?.isLoopback == true
        case .name(let n, _): return n == "localhost" || n == "127.0.0.1" || n == "::1"
        @unknown default: return false
        }
    }

    private func arrived(_ c: NWConnection) {
        guard listener != nil, Self.isLoopback(c.endpoint), let client, client.cableMayCome() else {
            // one cable connection at a time: extras are closed (started first, so the close reaches the PC)
            c.stateUpdateHandler = { s in
                switch s {
                case .ready, .failed, .waiting: c.cancel()
                case .cancelled: c.stateUpdateHandler = nil
                default: break
                }
            }
            c.start(queue: .main)
            return
        }
        let k = Candidate(c)
        candidate = k
        c.stateUpdateHandler = { [weak self, weak k] s in
            Task { @MainActor [weak self, weak k] in
                guard let self, let k, self.candidate === k else { return }
                switch s {
                case .ready: self.send(k.link.hello(device: UIDevice.current.name), on: k)   // the iPad speaks first
                case .failed, .cancelled: self.fail(k)
                default: break
                }
            }
        }
        c.start(queue: .main)
        receive(k)
        deadline(k)
    }

    /// A PC that doesn't get through the handshake in time is closed (not while the presenter compares the check:
    /// that has its own limit).
    private func deadline(_ k: Candidate) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handshakeLimit) { [weak self, weak k] in
            Task { @MainActor [weak self, weak k] in
                guard let self, let k, self.candidate === k, !k.handshake.isConfirming else { return }
                self.fail(k)
            }
        }
    }

    private func receive(_ k: Candidate) {
        k.c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self, weak k] data, _, done, error in
            Task { @MainActor [weak self, weak k] in
                guard let self, let k, self.candidate === k else { return }
                if let data, !data.isEmpty { self.got(data, k) }
                guard self.candidate === k else { return }   // handed over, or closed
                if done || error != nil { self.fail(k) } else { self.receive(k) }
            }
        }
    }

    private func got(_ data: Data, _ k: Candidate) {
        let messages: [PadMessage]
        do { messages = try k.decoder.feed(data) } catch { return fail(k) }
        for (i, m) in messages.enumerated() {
            switch m {
            case .challenge(let json) where k.handshake.step == .hello:
                guard challenged(json, k) else { return }
            case .sealed(let p) where k.handshake.expectsSealed:
                let inner: PadMessage?
                do { inner = try k.link.open(p) } catch { return fail(k) }
                guard let inner else { continue }   // a type this iPad doesn't know: skipped
                // a REJECT, or anything else before WELCOME: closed
                guard case .welcome(let w) = inner else { return fail(k) }
                guard let p = k.pending, k.handshake.welcomed() else { return fail(k) }
                // the PC opened the PROOF made with the empty code: only now is its key remembered
                PadPins.remember(p.key, for: p.name)
                acceptKey = nil
                candidate = nil
                k.c.stateUpdateHandler = nil
                client?.cableOpened(PadClient.CableSession(
                    connection: k.c, decoder: k.decoder, link: k.link, handshake: k.handshake, welcome: w,
                    check: PadCrypto.check(p.key), rest: Array(messages[(i + 1)...])))
                return
            default:
                return fail(k)   // a REJECT (in the clear), or bytes that aren't Contrast Ink version 2
            }
        }
    }

    /// The PC's CHALLENGE over the cable: the same key rules as Wi-Fi, the first-time question included.
    private func challenged(_ json: Data, _ k: Candidate) -> Bool {
        guard let c = PadChallenge.parse(json) else { fail(k); return false }
        if let refusedKey, refusedKey == c.key { fail(k); return false }   // the presenter said no to this one
        let decision = k.handshake.challenge(received: c.key, remembered: PadPins.key(for: c.name), accepted: acceptKey)
        guard let decision else { fail(k); return false }
        if decision == .warnDifferent {
            // not the PC paired with: stop, sending nothing more
            endCandidate()
            client?.cableWarned(name: c.name, check: PadCrypto.check(c.key), key: c.key)
            return false
        }
        guard let proof = k.link.proof(c, code: "") else { fail(k); return false }
        k.pending = (c.name, c.key)
        if decision == .askToConfirm {
            // the first time with this PC: nothing more goes until the presenter says its check matches
            k.heldProof = proof
            client?.cableAsks(name: c.name, check: PadCrypto.check(c.key))
            DispatchQueue.main.asyncAfter(deadline: .now() + PadHandshake.confirmLimit + 0.5) { [weak self, weak k] in
                Task { @MainActor [weak self, weak k] in
                    guard let self, let k, self.candidate === k, k.handshake.tick() else { return }
                    self.fail(k)
                    self.client?.cableCheckEnded(PadHandshake.tooLongText)
                }
            }
            return true
        }
        send(proof, on: k)
        return true
    }

    /// "It matches" for the PC on the cable: the PROOF goes now (unless the presenter took too long).
    func checkMatches() {
        guard let k = candidate, k.handshake.isConfirming, let proof = k.heldProof else { return }
        guard k.handshake.confirm() else {
            fail(k)
            client?.cableCheckEnded(PadHandshake.tooLongText)
            return
        }
        k.heldProof = nil
        send(proof, on: k)
        deadline(k)
    }

    /// "It doesn't": closed, nothing sent, and that PC isn't asked about again in this visit.
    func checkDiffers() {
        guard let k = candidate, k.handshake.isConfirming else { return }
        k.handshake.deny()
        refusedKey = k.pending?.key
        fail(k)
        client?.cableCheckEnded(PadHandshake.deniedText)
    }

    private func send(_ data: Data, on k: Candidate) { k.c.send(content: data, completion: .idempotent) }

    private func fail(_ k: Candidate) {
        guard candidate === k else { return }
        endCandidate()
        client?.cableFailed()
    }

    private func endCandidate() {
        guard let k = candidate else { return }
        candidate = nil
        k.c.stateUpdateHandler = nil
        k.c.cancel()
    }
}

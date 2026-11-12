import ContrastInkCore
import Foundation
import Network
import UIKit

/// Pad mode's link to the PC (docs/pad-protocol.md): finds PCs on the Wi-Fi with Bonjour, connects with the code the
/// PC shows, shows the PC's screen as it arrives, and sends what the pen does. The bytes are ContrastInkCore's
/// PadProtocol; this is only the networking around them.
///
/// Network.framework calls back on the main queue, and every callback hops onto the main actor before it touches
/// anything, so all the state below is only ever changed on the main thread.
@MainActor
final class PadClient: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        /// The PC stopped answering or the Wi-Fi dropped: the last picture stays, with Reconnect.
        case lost(String)
        /// The PC said no ("Wrong code"): the presenter needs to change something before trying again.
        case rejected(String)
    }

    /// A PC that advertised itself on this network.
    struct FoundPC: Identifiable, Equatable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var found: [FoundPC] = []
    /// Set once the PC took the code; kept while lost (the pad stays on screen), cleared by disconnect().
    @Published private(set) var welcome: PadWelcome?
    @Published private(set) var state = PadState()
    /// The latest picture of the PC's screen.
    @Published private(set) var picture: UIImage?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    /// Each connection's number: callbacks from an older one (closing after a reconnect) are ignored.
    private var generation = 0
    private var decoder = PadDecoder()
    private var target: (endpoint: NWEndpoint, code: String)?
    private var lastHeard = Date()
    private var pinger: Timer?
    private let queue = DispatchQueue.main

    var connectedName: String { welcome?.name ?? "PC" }

    // MARK: finding PCs

    func startBrowsing() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: PadProtocol.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let pcs = results.compactMap { r -> FoundPC? in
                if case .service(let name, _, _, _) = r.endpoint { return FoundPC(name: name, endpoint: r.endpoint) }
                return nil
            }
            Task { @MainActor [weak self] in
                // one entry per PC, in a steady order (a PC on Wi-Fi and Ethernet shows up twice)
                var seen = Set<String>()
                self?.found = pcs.filter { seen.insert($0.name).inserted }.sorted { $0.name < $1.name }
            }
        }
        b.start(queue: queue)
        browser = b
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    // MARK: connecting

    func connect(to pc: FoundPC, code: String) { connect(pc.endpoint, code: code) }

    /// A typed address (`192.168.1.20` or `192.168.1.20:47820`). False when it can't be an address.
    @discardableResult
    func connect(address: String, code: String) -> Bool {
        guard let a = PadProtocol.address(address), let port = NWEndpoint.Port(rawValue: a.port) else { return false }
        connect(.hostPort(host: NWEndpoint.Host(a.host), port: port), code: code)
        return true
    }

    /// Tries the last PC again, with the same code (after "Lost the PC").
    func reconnect() {
        guard let target else { return }
        connect(target.endpoint, code: target.code)
    }

    /// Leaves the PC: back to the list of PCs.
    func disconnect() {
        closeConnection()
        target = nil
        welcome = nil
        picture = nil
        state = PadState()
        phase = .idle
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func connect(_ endpoint: NWEndpoint, code: String) {
        closeConnection()
        target = (endpoint, code)
        generation += 1
        let gen = generation
        decoder = PadDecoder()
        phase = .connecting
        lastHeard = Date()   // the 6 s for the PC to answer start now

        // a pen stroke is many tiny messages: send each at once rather than waiting to fill a packet
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(PadProtocol.silenceLimit)
        let c = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        c.stateUpdateHandler = { [weak self] s in
            Task { @MainActor [weak self] in self?.connectionChanged(s, gen: gen) }
        }
        connection = c
        c.start(queue: queue)
        receive(on: c, gen: gen)

        pinger?.invalidate()
        pinger = Timer.scheduledTimer(withTimeInterval: PadProtocol.pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        UIApplication.shared.isIdleTimerDisabled = true   // the iPad must not dim while it's the pad
    }

    private func closeConnection() {
        generation += 1
        pinger?.invalidate()
        pinger = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func connectionChanged(_ s: NWConnection.State, gen: Int) {
        guard gen == generation else { return }
        switch s {
        case .ready:
            // HELLO first, always: nothing else is sent before it (pings start 2 s later)
            if let target { send(PadProtocol.hello(code: target.code, device: UIDevice.current.name)) }
        case .failed(let e): lose("Lost the PC (\(e.localizedDescription))")
        case .waiting(let e):
            // "waiting": no route or refused. Network.framework would retry by itself; say so instead of hanging
            if welcome == nil { lose("Couldn't reach the PC (\(e.localizedDescription))") } else { lose("Lost the PC") }
        default: break
        }
    }

    /// Every 2 s: a PING, and a check that the PC said something in the last 6 s (it answers every PING, and sends
    /// pictures besides, so 6 s of silence means it's gone even when TCP hasn't noticed).
    private func tick() {
        guard connection != nil else { return }
        if Date().timeIntervalSince(lastHeard) > PadProtocol.silenceLimit {
            lose(welcome == nil ? "Couldn't reach the PC" : "Lost the PC")
            return
        }
        if phase == .connected { send(PadProtocol.ping()) }   // never before HELLO
    }

    private func lose(_ why: String) {
        closeConnection()
        if case .rejected = phase { return }   // the PC closing after REJECT is not "lost"
        phase = .lost(why)
    }

    // MARK: receiving

    private func receive(on c: NWConnection, gen: Int) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                if let data, !data.isEmpty { self.got(data) }
                guard gen == self.generation else { return }   // got() may have closed it (REJECT, a broken stream)
                if done || error != nil {
                    self.lose("Lost the PC")
                } else {
                    self.receive(on: c, gen: gen)
                }
            }
        }
    }

    private func got(_ data: Data) {
        lastHeard = Date()
        let messages: [PadMessage]
        do { messages = try decoder.feed(data) } catch {
            lose("Lost the PC (it sent something that isn't Contrast Ink)")
            return
        }
        for m in messages {
            switch m {
            case .welcome(let w):
                welcome = w
                phase = .connected
                if let target { remember(target.code) }
            case .reject(let why):
                closeConnection()
                welcome = nil
                picture = nil
                phase = .rejected(why.isEmpty ? "The PC said no" : why)
                return
            case .frame(let jpeg):
                if let img = UIImage(data: jpeg) { picture = img }
                // FRAME_ACK once the picture is on screen: SwiftUI draws it this turn of the run loop, so ack just after
                let gen = generation
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation else { return }
                    self.send(PadProtocol.frameAck())
                }
            case .state(let json): state = PadState.parse(json, over: state)
            case .pong: break   // lastHeard is already updated
            }
        }
    }

    private func remember(_ code: String) { UserDefaults.standard.set(code, forKey: PadView.codeKey) }

    // MARK: sending

    private func send(_ data: Data) {
        guard let c = connection else { return }
        c.send(content: data, completion: .idempotent)
    }

    var canDraw: Bool { phase == .connected }

    func strokeBegin(_ p: Pt, eraserEnd: Bool = false) {
        guard canDraw else { return }
        send(PadProtocol.strokeBegin(x: p.x, y: p.y, end: eraserEnd ? .eraser : .tip))
    }

    func strokePoints(_ pts: [Pt]) {
        guard canDraw, !pts.isEmpty else { return }
        send(PadProtocol.strokePoints(pts.map { (x: $0.x, y: $0.y) }))
    }

    func strokeEnd() { if canDraw { send(PadProtocol.strokeEnd()) } }
    func strokeCancel() { if canDraw { send(PadProtocol.strokeCancel()) } }
    func hover(_ p: Pt) { if canDraw { send(PadProtocol.hover(x: p.x, y: p.y)) } }
    func hoverEnd() { if canDraw { send(PadProtocol.hoverEnd()) } }
    func command(_ c: String) { if canDraw { send(PadProtocol.command(c)) } }
}

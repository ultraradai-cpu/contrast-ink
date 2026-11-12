import ContrastInkCore
import Foundation
import ImageIO
import Network
import UIKit

/// Pad mode's link to the PC (docs/pad-protocol.md, version 2): finds PCs on the Wi-Fi with Bonjour, connects,
/// checks it is the PC it paired with before (by the PC's key), proves it knows the code without sending it, and
/// from then on everything both ways is encrypted. It shows the PC's screen as it arrives and sends what the pen
/// does. The bytes and the crypto are ContrastInkCore's PadProtocol and PadLink; this is the networking around them.
///
/// Network.framework calls back on the main queue, and every callback hops onto the main actor before it touches
/// anything, so all the state below is only ever changed on the main thread.
@MainActor
final class PadClient: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// The first connection to this PC, until it says WELCOME.
        case connecting
        case connected
        /// The link dropped after the PC had let this iPad in: trying again by itself, the last picture kept.
        case reconnecting(String)
        /// The PC couldn't be reached, or stopped answering and the quiet retries didn't bring it back.
        case lost(String)
        /// The PC said no ("Wrong code"): the presenter needs to change something before trying again.
        case rejected(String)
        /// The PC answered with a different key from the one remembered for its name. Nothing more was sent.
        case notThePC(name: String, check: String)
        /// The first time with this PC (or after "Connect anyway"): its check is on screen and nothing more is sent
        /// until the presenter says it matches what the PC shows.
        case confirming(name: String, check: String)
    }

    /// A PC that advertised itself on this network.
    struct FoundPC: Identifiable, Equatable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var found: [FoundPC] = []
    /// Why no PCs can be listed (Local Network not allowed), or nil.
    @Published private(set) var browseProblem: String?
    /// Set once the PC let this iPad in; kept while reconnecting or lost (the pad stays on screen), cleared by disconnect().
    @Published private(set) var welcome: PadWelcome?
    @Published private(set) var state = PadState()
    /// The latest picture of the PC's screen.
    @Published private(set) var picture: UIImage?
    /// The PC's check (XXXX-XXXX), shown in the toolbar.
    @Published private(set) var pcCheck: String?

    /// The session open now goes through the USB cable, not the Wi-Fi.
    @Published private(set) var byCable = false
    /// A PC on the cable answered with another key than the one remembered for its name, while Wi-Fi was in use.
    @Published private(set) var cableNotice: String?

    /// The code typed last, kept only while the app runs (the PC makes a new one each time it starts).
    private(set) var lastCode = ""

    /// Wi-Fi or the cable, and what to do when the cable comes or goes (ContrastInkCore's rules, tested there).
    private var route = PadRoute()
    /// The USB door: listens on the loopback while pad mode is open.
    private let cable = PadCable()
    /// The key of the PC on the cable that "not the PC you paired with" is about (what "Connect anyway" trusts).
    private var cableWarnedKey: Data?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    /// Each connection's number: callbacks from an older one (closing after a reconnect) are ignored.
    private var generation = 0
    private var decoder = PadDecoder()
    private var link = PadLink()
    /// Where the handshake is, and what may be sent (ContrastInkCore's rules, tested there).
    private var handshake = PadHandshake()
    private var target: Target?
    /// What the CHALLENGE said, kept until WELCOME proves the PC knew the code (only then is its key remembered).
    private var pending: (name: String, key: Data)?
    /// The PROOF, held back while the presenter compares the PC check; sent only on "It matches".
    private var heldProof: Data?
    /// The key the presenter chose to trust with "Connect anyway", for the next connection.
    private var acceptKey: Data?
    /// The key of the PC that let this iPad in during this visit: a reconnect must find the same one.
    private var sessionKey: Data?
    /// The key seen in the last CHALLENGE (what "Connect anyway" accepts).
    private var seenKey: Data?
    private var retries = 0
    private var retryWork: DispatchWorkItem?
    private var lastHeard = Date()
    private var pinger: Timer?
    private let queue = DispatchQueue.main

    private struct Target {
        let endpoint: NWEndpoint
        let code: String
        /// The name the PC was found under (Bonjour): its key is remembered under it. Nil for a typed address
        /// (then the CHALLENGE's name).
        let name: String?
    }

    /// Tries after a drop before saying "Lost the PC": a Wi-Fi blip is usually over within a few seconds.
    static let quietRetries = 2
    static let unreachable = "Couldn't reach the PC — check both are on the same Wi-Fi and Contrast Ink on the PC has ⚙ Settings → Let a Tablet Draw Here ticked."
    static let localNetworkOff = "Allow Local Network for Contrast Ink: Settings → Privacy & Security → Local Network."

    var connectedName: String { welcome?.name ?? pending?.name ?? target?.name ?? "PC" }

    init() { cable.client = self }

    // MARK: the USB cable

    static let unplugged = "The USB cable was unplugged. Plug it in again, or connect over Wi-Fi."

    /// A cable session that has just opened (the PC's sealed WELCOME came): everything PadClient needs to carry on
    /// with it, including any messages that came in the same read after WELCOME.
    struct CableSession {
        let connection: NWConnection
        let decoder: PadDecoder
        let link: PadLink
        let handshake: PadHandshake
        let welcome: PadWelcome
        let check: String
        let rest: [PadMessage]
    }

    /// Pad mode is open: listen for the PC on the cable (no code needed, so from the connect screen too).
    func startCable() { cable.start() }

    /// Leaving pad mode: no more listening.
    func stopCable() { cable.stop() }

    /// A connection came through the cable: let it in only when no other cable connection is.
    func cableMayCome() -> Bool { route.cableArrived() }

    /// The cable connection being let in ended before its session opened.
    func cableFailed() { route.cableFailed() }

    /// The PC on the cable isn't the one paired with under its name: say so (nothing more was sent to it).
    func cableWarned(name: String, check: String, key: Data) {
        route.cableFailed()
        switch phase {
        case .idle, .lost, .rejected, .notThePC:
            if welcome == nil {
                cableWarnedKey = key
                phase = .notThePC(name: name, check: check)
                return
            }
        default: break
        }
        // Wi-Fi is in use: it carries on, and the warning shows beside it
        cableNotice = "On the USB cable: this isn't the PC you paired with as \(name) (its PC check is now \(check))."
    }

    /// The cable's session is open: it replaces Wi-Fi (closed now, and not tried while the cable is in).
    func cableOpened(_ s: CableSession) {
        closeConnection()   // the Wi-Fi connection, its retries and its pings
        route.cableOpened()
        generation += 1
        let gen = generation
        connection = s.connection
        decoder = s.decoder
        link = s.link
        handshake = s.handshake
        pending = nil
        heldProof = nil
        byCable = true
        cableNotice = nil
        cableWarnedKey = nil
        welcome = s.welcome
        pcCheck = s.check
        picture = nil
        state = PadState()
        retries = 0
        phase = .connected
        lastHeard = Date()
        s.connection.stateUpdateHandler = { [weak self] st in
            Task { @MainActor [weak self] in self?.connectionChanged(st, gen: gen) }
        }
        receive(on: s.connection, gen: gen)
        pinger = Timer.scheduledTimer(withTimeInterval: PadProtocol.pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        UIApplication.shared.isIdleTimerDisabled = true
        for m in s.rest {
            guard gen == generation else { return }
            handle(m)
        }
    }

    /// The cable's session ended (unplugged, or the PC stopped answering): back to Wi-Fi by itself when a code was
    /// typed earlier in this visit, otherwise the connect screen.
    private func cableEnded() {
        closeConnection()
        byCable = false
        let next = route.cableDropped()
        if next == .wifi, target != nil {
            retries = 0
            phase = .reconnecting("The USB cable was unplugged: back to Wi-Fi.")
            open()
            return
        }
        route.forget()
        welcome = nil
        picture = nil
        state = PadState()
        pcCheck = nil
        phase = .lost(Self.unplugged)
        UIApplication.shared.isIdleTimerDisabled = false
    }

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
        // Without this, a refused Local Network permission looks like "Looking for PCs…" forever
        b.stateUpdateHandler = { [weak self, weak b] s in
            Task { @MainActor [weak self] in
                guard let self, let b, self.browser === b else { return }
                self.browserChanged(s)
            }
        }
        b.start(queue: queue)
        browser = b
    }

    func stopBrowsing() {
        browser?.stateUpdateHandler = nil
        browser?.cancel()
        browser = nil
    }

    private func browserChanged(_ s: NWBrowser.State) {
        switch s {
        case .ready: browseProblem = nil
        case .waiting(let e):
            // waiting: iOS will carry on by itself once allowed; say what to do meanwhile
            browseProblem = Self.policyDenied(e) ? Self.localNetworkOff : "Can't look for PCs on this network right now (\(Self.plain(e)))."
        case .failed(let e):
            browseProblem = Self.policyDenied(e) ? Self.localNetworkOff : "Can't look for PCs on this network right now (\(Self.plain(e)))."
            // a failed browser never recovers: start a new one in a moment (the permission may be given meanwhile)
            stopBrowsing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startBrowsing() }
        default: break
        }
    }

    /// Local Network not allowed: Bonjour answers with its "policy denied" error (kDNSServiceErr_PolicyDenied).
    private static func policyDenied(_ e: NWError) -> Bool {
        if case .dns(let code) = e { return code == -65570 }
        return false
    }

    // MARK: connecting

    func connect(to pc: FoundPC, code: String) { start(Target(endpoint: pc.endpoint, code: code, name: pc.name)) }

    /// A typed address (`192.168.1.20` or `192.168.1.20:47820`). False when it can't be an address.
    @discardableResult
    func connect(address: String, code: String) -> Bool {
        guard let a = PadProtocol.address(address), let port = NWEndpoint.Port(rawValue: a.port) else { return false }
        start(Target(endpoint: .hostPort(host: NWEndpoint.Host(a.host), port: port), code: code, name: nil))
        return true
    }

    /// The presenter starts a new connection: nothing carries over from an earlier PC's.
    private func start(_ t: Target) {
        acceptKey = nil
        sessionKey = nil
        welcome = nil
        picture = nil
        state = PadState()
        pcCheck = nil
        target = t
        lastCode = t.code
        retries = 0
        route.wifiChosen()   // held for after the cable, if one comes
        cableWarnedKey = nil
        open()
    }

    /// Tries the last PC again, with the same code (Reconnect).
    func reconnect() {
        guard target != nil else { return }
        retries = 0
        open()
    }

    /// After "not the PC you paired with": the presenter knows the PC's Contrast Ink was reinstalled. The next
    /// connection takes that key (and, once the PC lets the iPad in, remembers it instead of the old one).
    func connectAnyway() {
        if let k = cableWarnedKey {
            // the warning was about the PC on the cable: its next connection (the PC tries every few seconds) goes on
            cable.acceptKey = k
            cableWarnedKey = nil
            phase = .idle
            return
        }
        guard target != nil, let k = seenKey else { return }
        acceptKey = k
        retries = 0
        open()
    }

    /// Leaves the PC: back to the list of PCs.
    func disconnect() {
        closeConnection()
        target = nil
        welcome = nil
        picture = nil
        state = PadState()
        pcCheck = nil
        acceptKey = nil
        sessionKey = nil
        byCable = false
        cableNotice = nil
        cableWarnedKey = nil
        route.forget()
        phase = .idle
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func open() {
        // never Wi-Fi while the cable's session is open
        guard let target, route.wifiStarting() else { return }
        closeConnection()
        generation += 1
        let gen = generation
        decoder = PadDecoder()
        link = PadLink()   // a fresh key pair for every connection
        handshake = PadHandshake()
        pending = nil
        heldProof = nil
        if welcome == nil { phase = .connecting } else if case .reconnecting = phase {} else { phase = .reconnecting("") }
        lastHeard = Date()   // the 6 s for the PC to answer start now

        // a pen stroke is many tiny messages: send each at once rather than waiting to fill a packet
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(PadProtocol.silenceLimit)
        let c = NWConnection(to: target.endpoint, using: NWParameters(tls: nil, tcp: tcp))
        c.stateUpdateHandler = { [weak self] s in
            Task { @MainActor [weak self] in self?.connectionChanged(s, gen: gen) }
        }
        connection = c
        c.start(queue: queue)
        receive(on: c, gen: gen)

        pinger = Timer.scheduledTimer(withTimeInterval: PadProtocol.pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        UIApplication.shared.isIdleTimerDisabled = true   // the iPad must not dim while it's the pad
    }

    private func closeConnection() {
        generation += 1
        retryWork?.cancel()
        retryWork = nil
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
            // HELLO first, always: nothing else is sent before it, and nothing after it until the CHALLENGE
            // (a cable session arrives with its handshake already done)
            if !byCable, handshake.step == .hello { send(link.hello(device: UIDevice.current.name)) }
        case .failed(let e): dropped(Self.plain(e))
        case .waiting(let e):
            // "waiting": no route or refused. Network.framework would retry by itself; say so instead of hanging
            dropped(Self.plain(e))
        default: break
        }
    }

    /// Every 2 s: a PING, and a check that the PC said something in the last 6 s (it answers every PING, and sends
    /// pictures besides, so 6 s of silence means it's gone even when TCP hasn't noticed).
    private func tick() {
        guard connection != nil else { return }
        if handshake.isConfirming {
            // the PC is quiet while it waits for the PROOF (up to 30 s): only the presenter's time counts
            if handshake.tick() { endCheck() }
            return
        }
        if Date().timeIntervalSince(lastHeard) > PadProtocol.silenceLimit {
            dropped("The PC stopped answering.")
            return
        }
        if handshake.step == .open { sendSealed(PadProtocol.ping()) }   // never before the PC let this iPad in
    }

    /// The connection ended without a REJECT. Once the PC had let this iPad in, try again quietly a couple of times
    /// (the picture stays, the pad stays on screen); before that, say plainly what to check.
    private func dropped(_ why: String) {
        if byCable { return cableEnded() }
        closeConnection()
        guard welcome != nil else {
            phase = .lost(Self.unreachable)
            return
        }
        if retries < Self.quietRetries {
            retries += 1
            phase = .reconnecting(why)
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in self?.open() }
            }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(retries), execute: work)
            return
        }
        phase = .lost("Lost the PC: \(why)")
    }

    /// The PC said why it won't take this iPad: show its words as they are, keep the picture.
    private func rejected(_ why: String) {
        if byCable { return cableEnded() }
        closeConnection()
        phase = .rejected(why.isEmpty ? "The PC said no." : why)
    }

    /// Network.framework's errors, in words a presenter can act on.
    static func plain(_ e: NWError) -> String {
        switch e {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "The PC refused the connection: is Contrast Ink running on it, with Let a Tablet Draw Here ticked?"
            case .ETIMEDOUT: return "The PC didn't answer in time."
            case .ENETUNREACH, .EHOSTUNREACH, .EHOSTDOWN, .ENETDOWN: return "The PC can't be reached from this network."
            case .ECONNRESET, .EPIPE, .ECONNABORTED, .ENOTCONN: return "The connection to the PC was cut."
            default: return "The network connection failed."
            }
        case .dns: return "The PC's name couldn't be found on this network."
        case .tls: return "The network connection failed."
        @unknown default: return "The network connection failed."
        }
    }

    // MARK: receiving

    private func receive(on c: NWConnection, gen: Int) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                if let data, !data.isEmpty { self.got(data) }
                guard gen == self.generation else { return }   // got() may have closed it (REJECT, a broken stream)
                if done || error != nil {
                    self.dropped("The connection to the PC was cut.")
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
            broken()
            return
        }
        let gen = generation
        for m in messages {
            guard gen == generation else { return }   // an earlier message closed it
            handle(m)
        }
    }

    private func handle(_ m: PadMessage) {
        switch m {
        case .challenge(let json) where handshake.step == .hello && !byCable: challenged(json)
        // REJECT comes in the clear, only before the PC let this iPad in (wrong code, locked out, old tablet)
        case .reject(let why) where handshake.expectsReject: rejected(why)
        case .sealed(let p) where handshake.expectsSealed: opened(p)
        // anything else in the clear is not version 2, or someone else's bytes: never shown, never trusted
        default: broken()
        }
    }

    /// The PC's CHALLENGE: is it the PC paired with before? If so, prove the code at once. The first time (or after
    /// "Connect anyway"), only once the presenter has seen the PC shows the same check: a machine pretending to be
    /// the PC never gets a PROOF to try every code against.
    private func challenged(_ json: Data) {
        guard let target, let c = PadChallenge.parse(json) else { return broken() }
        let name = target.name ?? c.name
        let check = PadCrypto.check(c.key)
        seenKey = c.key
        guard let decision = handshake.challenge(received: c.key, remembered: PadPins.key(for: name),
                                                 session: sessionKey, accepted: acceptKey) else { return broken() }
        if decision == .warnDifferent {
            // not the PC paired with: stop here, sending nothing more (not even the PROOF a guesser could use)
            closeConnection()
            cableWarnedKey = nil   // "Connect anyway" is about this Wi-Fi PC
            phase = .notThePC(name: name, check: check)
            return
        }
        guard let proof = link.proof(c, code: target.code) else { return broken() }
        pending = (name, c.key)
        pcCheck = check
        if decision == .askToConfirm {
            heldProof = proof
            phase = .confirming(name: name, check: check)
            return
        }
        send(proof)
    }

    /// "It matches": the PROOF goes now (unless the presenter took too long).
    func checkMatches() {
        guard handshake.isConfirming, let proof = heldProof else { return }
        guard handshake.confirm() else { return endCheck() }
        heldProof = nil
        lastHeard = Date()   // the PC's 6 s to answer start now
        phase = welcome == nil ? .connecting : .reconnecting("")
        send(proof)
    }

    /// "It doesn't": close without sending anything more.
    func checkDiffers() {
        guard handshake.isConfirming else { return }
        handshake.deny()
        endCheck()
    }

    /// The check ended without a match (denied, or too long): close, nothing sent, and say why.
    private func endCheck() {
        let why: String
        if case .ended(let w) = handshake.step { why = w } else { why = PadHandshake.tooLongText }
        closeConnection()
        heldProof = nil
        pending = nil
        acceptKey = nil
        phase = .rejected(why)
    }

    private func opened(_ payload: Data) {
        let m: PadMessage?
        do { m = try link.open(payload) } catch { return broken() }
        guard let m else { return }   // a type this iPad doesn't know: skipped
        switch m {
        case .welcome(let w):
            guard let p = pending, handshake.welcomed() else { return }
            // the PC opened PROOF and answered with the same keys: it knows the code. Only now is its key remembered.
            PadPins.remember(p.key, for: p.name)
            sessionKey = p.key
            acceptKey = nil
            welcome = w
            retries = 0
            phase = .connected
        case .reject(let why): rejected(why)
        case .frame(let jpeg) where handshake.step == .open: show(jpeg)
        case .state(let json) where handshake.step == .open: state = PadState.parse(json, over: state)
        default: break   // a PONG (lastHeard is already updated), or nothing before WELCOME
        }
    }

    /// Bytes that aren't Contrast Ink version 2, or a sealed message that was altered or replayed: close.
    private func broken() {
        if welcome == nil {
            closeConnection()
            phase = .lost("The PC's answer wasn't Contrast Ink's: update Contrast Ink on the PC, and check the address.")
        } else {
            dropped("The connection to the PC was disturbed.")
        }
    }

    /// A FRAME: its size checked and decoded off the main thread, then shown, and only then acknowledged.
    /// A picture that can't be decoded (or is too big) is not acknowledged: the PC sends another in a moment.
    private func show(_ jpeg: Data) {
        let gen = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let img = PadPicture.prepare(jpeg)
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation, let img else { return }
                self.picture = img
                // FRAME_ACK once the picture is on screen: SwiftUI draws it this turn of the run loop, so ack just after
                DispatchQueue.main.async { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, gen == self.generation else { return }
                        self.sendSealed(PadProtocol.frameAck())
                    }
                }
            }
        }
    }

    // MARK: sending

    /// In the clear: only HELLO and PROOF.
    private func send(_ data: Data) {
        guard let c = connection else { return }
        c.send(content: data, completion: .idempotent)
    }

    /// Everything after the PC let this iPad in.
    private func sendSealed(_ message: Data) {
        guard handshake.step == .open, let sealed = link.seal(message) else { return }
        send(sealed)
    }

    var canDraw: Bool { phase == .connected }

    func strokeBegin(_ p: Pt, eraserEnd: Bool = false) {
        guard canDraw else { return }
        sendSealed(PadProtocol.strokeBegin(x: p.x, y: p.y, end: eraserEnd ? .eraser : .tip))
    }

    func strokePoints(_ pts: [Pt]) {
        guard canDraw, !pts.isEmpty else { return }
        sendSealed(PadProtocol.strokePoints(pts.map { (x: $0.x, y: $0.y) }))
    }

    func strokeEnd() { if canDraw { sendSealed(PadProtocol.strokeEnd()) } }
    func strokeCancel() { if canDraw { sendSealed(PadProtocol.strokeCancel()) } }
    func hover(_ p: Pt) { if canDraw { sendSealed(PadProtocol.hover(x: p.x, y: p.y)) } }
    func hoverEnd() { if canDraw { sendSealed(PadProtocol.hoverEnd()) } }
    func command(_ c: String) { if canDraw { sendSealed(PadProtocol.command(c)) } }
}

/// The PCs this iPad has paired with: each one's public key, by its name. A PC that answers under a known name with
/// another key is not the PC paired with (or its Contrast Ink was reinstalled): the presenter decides.
enum PadPins {
    static let defaultsKey = "padPCKeys"

    static func key(for name: String) -> Data? {
        (UserDefaults.standard.dictionary(forKey: defaultsKey)?[name] as? String).flatMap { Data(base64Encoded: $0) }
    }

    static func remember(_ key: Data, for name: String) {
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        all[name] = key.base64EncodedString()
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }
}

/// A FRAME's JPEG made ready to show, away from the main thread.
enum PadPicture {
    /// The PC sends at most 1600 wide; anything over 4096 px either way is refused, not decoded, so a hostile machine
    /// can't make the iPad decode something that eats its memory.
    static let maxSide = 4096

    /// The picture's size from its header first (refused before any decoding when too big), then decoded and made
    /// ready to draw, so the main thread only ever shows it. Nil for anything that isn't a picture.
    static func prepare(_ jpeg: Data) -> UIImage? {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, noCache), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, noCache) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= maxSide, h <= maxSide,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let img = UIImage(cgImage: cg)
        return img.preparingForDisplay() ?? img
    }
}

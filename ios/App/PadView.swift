import ContrastInkCore
import SwiftUI
import UIKit

/// The app's own UI test opens pad mode straight onto a fake PC: `-padTest 127.0.0.1:47999 123456` (no Bonjour,
/// which a test runner can't rely on). Only in Debug builds (what the UI test runs): a build for a real iPad has no
/// way to be pointed at a machine from its launch arguments.
enum PadLaunch {
    static let test: (address: String, code: String)? = {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-padTest"), i + 2 < a.count else { return nil }
        return (a[i + 1], a[i + 2])
        #else
        return nil
        #endif
    }()
}

/// Pad mode: this iPad shows a PC's screen and what is drawn on it is drawn by the PC (where OBS records it).
/// First the list of PCs and the code, then the PC's screen with a toolbar.
struct PadView: View {
    /// The address and the PC are remembered for next time; the code never is (the PC makes a new one each run).
    static let addressKey = "padAddress", pcKey = "padPC"

    /// Back to the home screen (nil in the UI test, which only ever shows the pad).
    var close: (() -> Void)?
    @StateObject private var client = PadClient()

    var body: some View {
        Group {
            if client.welcome != nil { PadScreen(client: client) } else { PadConnectView(client: client, close: close) }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // a code saved by an older version: the PC has a new one by now, and it isn't kept any more
            UserDefaults.standard.removeObject(forKey: "padCode")
            if let t = PadLaunch.test, client.phase == .idle { client.connect(address: t.address, code: t.code) }
        }
        .onDisappear { client.disconnect(); client.stopBrowsing() }
    }
}

/// The first time with a PC: its check, to compare with the PC's screen before anything that could reveal the code
/// is sent. The same panel on the list of PCs and on the pad (after "Connect anyway" while reconnecting).
struct PadCheckPanel: View {
    @ObservedObject var client: PadClient
    let name: String
    let check: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield").font(.largeTitle).foregroundStyle(Color.contrastBlue)
            Text("First time with \(name): does the PC show the PC check \(check)? (⚙ Settings, beside the code)")
                .font(.title3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("padFirstTime")
            HStack(spacing: 16) {
                Button { client.checkDiffers() } label: { Text("It doesn't").frame(minWidth: 120) }
                    .buttonStyle(.bordered).tint(Color.noticeText)
                    .accessibilityIdentifier("padCheckDiffers")
                Button { client.checkMatches() } label: { Text("It matches").bold().frame(minWidth: 120) }
                    .buttonStyle(.borderedProminent).tint(Color.contrastBlue)
                    .accessibilityIdentifier("padCheckMatches")
            }
        }
        .foregroundStyle(Color.offText)
        .frame(maxWidth: 460)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.inkBar.opacity(0.97)))
    }
}

/// "Not the PC you paired with": what it says, wherever it shows.
private func notThePCText(_ name: String, _ check: String) -> String {
    "This isn't the PC you paired with as \(name): its PC check is now \(check). If you didn't reinstall Contrast Ink on that PC, don't connect."
}

// MARK: choosing the PC

struct PadConnectView: View {
    @ObservedObject var client: PadClient
    var close: (() -> Void)?
    @State private var chosen: String? = UserDefaults.standard.string(forKey: PadView.pcKey)
    @State private var address = UserDefaults.standard.string(forKey: PadView.addressKey) ?? ""
    @State private var code = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let why = client.browseProblem {
                        Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(Color.noticeText)
                            .accessibilityIdentifier("padBrowseProblem")
                    } else if client.found.isEmpty {
                        Label("Looking for PCs running Contrast Ink on this Wi-Fi…", systemImage: "wifi")
                            .foregroundStyle(Color.offText.opacity(0.7))
                    }
                    ForEach(client.found) { pc in
                        Button { chosen = pc.name; address = "" } label: {
                            HStack {
                                Label(pc.name, systemImage: "desktopcomputer")
                                Spacer()
                                if chosenPC?.name == pc.name { Image(systemName: "checkmark").foregroundStyle(Color.contrastBlue) }
                            }
                        }
                    }
                } header: { Text("PCs on this Wi-Fi") }
                Section {
                    TextField("192.168.1.20 or 192.168.1.20:47820", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: address) { if !$0.isEmpty { chosen = nil } }
                        .accessibilityIdentifier("padAddress")
                } header: { Text("Or type the PC's address") } footer: {
                    Text("The PC shows its address under the code: use it when the PC isn't found above (some networks hide it).")
                }
                Section {
                    TextField("6 digits", text: $code)
                        .keyboardType(.numberPad)
                        .font(.title2.monospacedDigit())
                        .onChange(of: code) { v in
                            let digits = String(v.filter { $0.isASCII && $0.isNumber }.prefix(6))
                            if digits != v { code = digits }
                        }
                        .accessibilityIdentifier("padCode")
                } header: { Text("The code the PC shows") }
                Section {
                    Button { connect() } label: {
                        HStack {
                            Text(client.phase == .connecting ? "Connecting…" : "Connect").bold()
                            if client.phase == .connecting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!canConnect || client.phase == .connecting || isConfirming)
                    .accessibilityIdentifier("padConnect")
                    if let why = message {
                        Text(why).foregroundStyle(Color.noticeText).accessibilityIdentifier("padMessage")
                    }
                    if case .notThePC = client.phase {
                        Button("Connect anyway") { client.connectAnyway() }
                            .foregroundStyle(Color.noticeText)
                            .accessibilityIdentifier("padConnectAnyway")
                    }
                } footer: {
                    Text("The PC's pictures come to this iPad encrypted, and the code never crosses the network. For patient images, a private network or the PC's own hotspot is still the safest. The first time, check that the PC check this iPad shows matches the one under the code on the PC.")
                }
            }
            .navigationTitle("Pad for a PC")
            .toolbar {
                if let close {
                    ToolbarItem(placement: .cancellationAction) { Button("Back") { client.disconnect(); close() } }
                }
            }
        }
        .overlay {
            if case .confirming(let name, let check) = client.phase {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    PadCheckPanel(client: client, name: name, check: check).padding(16)
                }
            }
        }
        // the UI test connects straight to its fake PC: no Bonjour (nor its permission prompt) in a test run
        .onAppear {
            if code.isEmpty { code = client.lastCode }
            if PadLaunch.test == nil { client.startBrowsing() }
        }
    }

    /// The chosen PC, if it's (still) on the network.
    private var chosenPC: PadClient.FoundPC? {
        if let chosen, let pc = client.found.first(where: { $0.name == chosen }) { return pc }
        // nothing chosen and nothing typed: the only PC around is the one
        if address.isEmpty, client.found.count == 1 { return client.found[0] }
        return nil
    }

    private var isConfirming: Bool { if case .confirming = client.phase { return true }; return false }

    private var canConnect: Bool {
        PadProtocol.isCode(code) && (chosenPC != nil || PadProtocol.address(address) != nil)
    }

    private var message: String? {
        if let problem { return problem }
        switch client.phase {
        case .rejected(let why), .lost(let why): return why
        case .notThePC(let name, let check): return notThePCText(name, check)
        default: return nil
        }
    }

    private func connect() {
        problem = nil
        let d = UserDefaults.standard
        if let pc = chosenPC, address.isEmpty || PadProtocol.address(address) == nil {
            d.set(pc.name, forKey: PadView.pcKey)
            client.connect(to: pc, code: code)
        } else if client.connect(address: address, code: code) {
            d.set(address, forKey: PadView.addressKey)
            d.removeObject(forKey: PadView.pcKey)
        } else {
            problem = "That isn't an address: type it as the PC shows it, like 192.168.1.20 or 192.168.1.20:47820."
        }
    }
}

// MARK: the pad

struct PadScreen: View {
    @ObservedObject var client: PadClient

    var body: some View {
        VStack(spacing: 0) {
            PadToolbar(client: client)
            GeometryReader { geo in
                let size = pictureSize
                let fit = Fit.aspect(Size(size.width, size.height), in: Size(geo.size.width, geo.size.height))
                let rect = CGRect(x: fit.x, y: fit.y, width: fit.width, height: fit.height)
                ZStack(alignment: .topLeading) {
                    Color.black
                    Group {
                        if let img = client.picture {
                            Image(uiImage: img).resizable().interpolation(.medium)
                        } else {
                            ZStack {
                                Color.inkBar
                                Text("Waiting for the PC's screen…").foregroundStyle(Color.offText)
                            }
                        }
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(client.picture == nil ? "Waiting for the PC's screen" : "The PC's screen")
                    .accessibilityValue(client.picture == nil ? "" : "shown")
                    .accessibilityIdentifier("padPicture")
                    // the whole area takes the pen (one that slides off the picture draws along its edge)
                    PadSurface(client: client, picture: rect, state: client.state)
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .background(Color.black)
        .overlay {
            if case .confirming(let name, let check) = client.phase {
                PadCheckPanel(client: client, name: name, check: check)
            } else if client.phase != .connected {
                lostCard
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    /// The picture's shape: the latest frame's, or before one arrives, the PC's screen's.
    private var pictureSize: CGSize {
        if let p = client.picture, p.size.width > 0, p.size.height > 0 { return p.size }
        let w = client.welcome ?? PadWelcome()
        return CGSize(width: w.screenW, height: w.screenH)
    }

    @ViewBuilder private var lostCard: some View {
        VStack(spacing: 14) {
            switch client.phase {
            case .connecting, .reconnecting:
                ProgressView()
                Text("Reconnecting to \(client.connectedName)…").accessibilityIdentifier("padReconnecting")
                if case .reconnecting(let why) = client.phase, !why.isEmpty {
                    Text(why).font(.callout).multilineTextAlignment(.center).foregroundStyle(Color.offText.opacity(0.8))
                }
            case .lost(let why), .rejected(let why):
                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                Text(why).multilineTextAlignment(.center).accessibilityIdentifier("padMessage")
                Button { client.reconnect() } label: { Text("Reconnect").bold().frame(minWidth: 160) }
                    .buttonStyle(.borderedProminent).tint(Color.contrastBlue)
                    .accessibilityIdentifier("padReconnect")
            case .notThePC(let name, let check):
                Image(systemName: "exclamationmark.shield").font(.largeTitle).foregroundStyle(Color.noticeText)
                Text(notThePCText(name, check)).multilineTextAlignment(.center).accessibilityIdentifier("padMessage")
                Button("Connect anyway") { client.connectAnyway() }.foregroundStyle(Color.noticeText)
                    .accessibilityIdentifier("padConnectAnyway")
            default: EmptyView()
            }
            Button("Disconnect") { client.disconnect() }
        }
        .foregroundStyle(Color.offText)
        .frame(maxWidth: 460)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.inkBar.opacity(0.95)))
    }
}

/// The pad's toolbar, in the look of the presenter's (and the same buttons as Android's pad): each button is a
/// COMMAND to the PC, and what is lit up is what the PC says (STATE), so the iPad never shows a tool the PC isn't using.
struct PadToolbar: View {
    @ObservedObject var client: PadClient

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { drawing; bar; actions }.padding(.horizontal, 8).padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) { drawing }
                HStack(spacing: 4) { actions }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) { drawing }
                    HStack(spacing: 4) { actions }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.inkBar)
    }

    private var bar: some View { Divider().frame(height: 28).overlay(Color.offText.opacity(0.3)) }

    @ViewBuilder private var drawing: some View {
        Button { client.disconnect() } label: { Image(systemName: "xmark") }
            .buttonStyle(BarButton(on: false)).named("Disconnect").accessibilityIdentifier("padDisconnect")
        bar
        tool(.pen, "pencil.tip", "Pen")
        tool(.highlighter, "highlighter", "Highlighter")
        tool(.arrow, "arrow.up.right", "Arrow")
        tool(.oval, "circle", "Circle")
        tool(.eraser, "eraser", "Eraser")
        Button { client.command(PadProtocol.Command.tool(.laser)) } label: {
            Image(systemName: "circle.fill").foregroundStyle(client.state.tool == .laser ? Color.white : Color(uiColor: UIColor(hex: Laser.color)))
        }
        .buttonStyle(BarButton(on: client.state.tool == .laser))
        .named("Laser pointer")
        ForEach(Settings.colors.indices, id: \.self) { i in
            Button { client.command(PadProtocol.Command.color(i)) } label: {
                Circle().fill(Color(uiColor: UIColor(hex: Settings.colors[i])))
                    .overlay(Circle().stroke(Color.offText.opacity(0.6), lineWidth: Settings.colorNames[i] == "Black" ? 1 : 0))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(BarButton(on: false))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.contrastBlue, lineWidth: client.state.color == i ? 2.5 : 0))
            .named(Settings.colorNames[i])
        }
    }

    /// The widths start the second row: the first is full with the tools and colours on a narrow iPad.
    @ViewBuilder private var actions: some View {
        ForEach(Settings.widths.indices, id: \.self) { i in
            Button { client.command(PadProtocol.Command.width(i)) } label: {
                Circle().frame(width: Settings.widths[i] + 3, height: Settings.widths[i] + 3)
            }
            .buttonStyle(BarButton(on: client.state.width == i))
            .named("\(Settings.widthNames[i]) line")
        }
        Button { client.command(client.state.fading ? PadProtocol.Command.fadeOff : PadProtocol.Command.fadeOn) } label: {
            Image(systemName: "timer")
        }
        .buttonStyle(BarButton(on: client.state.fading)).named("Fading ink")
        // dimmed when the PC says there is nothing to undo (still pressable: its STATE may be a moment behind)
        Button { client.command(PadProtocol.Command.undo) } label: { Image(systemName: "arrow.uturn.backward") }
            .buttonStyle(BarButton(on: false)).opacity(client.state.canUndo ? 1 : 0.4)
            .named("Undo").accessibilityIdentifier("padUndo")
        Button { client.command(PadProtocol.Command.clear) } label: { Image(systemName: "trash") }
            .buttonStyle(BarButton(on: false)).named("Clear all marks")
        bar
        Button { client.command(PadProtocol.Command.previous) } label: { Image(systemName: "chevron.left") }
            .buttonStyle(BarButton(on: false)).named("Previous slide")
        Button { client.command(PadProtocol.Command.next) } label: { Image(systemName: "chevron.right") }
            .buttonStyle(BarButton(on: false)).named("Next slide")
        bar
        VStack(alignment: .leading, spacing: 0) {
            Label(client.connectedName, systemImage: "desktopcomputer")
                .font(.callout).foregroundStyle(Color.offText).lineLimit(1).fixedSize()
                .accessibilityIdentifier("padPCName")
            if let check = client.pcCheck {
                Text("PC check \(check)").font(.caption2.monospacedDigit()).foregroundStyle(Color.offText.opacity(0.7))
                    .fixedSize().accessibilityIdentifier("padPCCheck")
            }
        }
    }

    private func tool(_ t: Tool, _ symbol: String, _ name: String) -> some View {
        Button { client.command(PadProtocol.Command.tool(t)) } label: { Image(systemName: symbol) }
            .buttonStyle(BarButton(on: client.state.tool == t))
            .named(name)
    }
}

// MARK: the touch surface

/// Where the pen (or a finger) draws: a plain UIView, so every touch, coalesced point and hover arrives as UIKit
/// sees it, with no gesture recogniser waiting to decide what a touch is.
struct PadSurface: UIViewRepresentable {
    let client: PadClient
    let picture: CGRect
    let state: PadState

    func makeUIView(context: Context) -> PadTouchView { PadTouchView(client: client) }

    func updateUIView(_ v: PadTouchView, context: Context) {
        v.picture = picture
        v.state = state
    }
}

final class PadTouchView: UIView {
    weak var client: PadClient?
    /// The PC's screen inside this view: strokes are sent as fractions of it.
    var picture = CGRect.zero
    var state = PadState()

    private var active: UITouch?
    /// A second finger came: nothing draws until every finger has lifted.
    private var cancelled = false
    private var pending: [Pt] = []
    private var link: CADisplayLink?
    private var live: CAShapeLayer?
    private var livePath = UIBezierPath()
    private let hover = UIHoverGestureRecognizer()
    private var lastHover = Date.distantPast
    private var hovering = false

    /// How long the iPad keeps its own copy of a finished stroke: by then the PC's picture shows it.
    static let keepAfterLift = 0.6
    /// Points go to the PC in batches this far apart (one a screen refresh), not one message per touch sample.
    static let batch = 0.016

    init(client: PadClient) {
        self.client = client
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        accessibilityIdentifier = "padSurface"
        hover.addTarget(self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func fraction(_ p: CGPoint) -> Pt {
        PadProtocol.fraction(Pt(p.x, p.y), in: Rect(picture.minX, picture.minY, picture.width, picture.height))
    }

    // MARK: strokes

    /// Apple Pencil touched the glass since the app started: from then on only the Pencil draws, so a palm that
    /// lands before the Pencil (resting the hand to write) never starts a stroke.
    private static var pencilSeen = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where t.type == .pencil { Self.pencilSeen = true }
        for t in touches {
            if let a = active, t !== a {
                if t.type == .pencil, a.type != .pencil {
                    // the palm landed first and started a stroke (before any Pencil was seen): drop it, the Pencil draws
                    drop()
                    begin(t)
                } else if a.type == .pencil, t.type != .pencil {
                    continue   // a palm while Apple Pencil draws is ignored
                } else {
                    cancel()   // a second finger means "not a stroke"
                }
            } else if active == nil {
                if t.type == .pencil { cancelled = false; begin(t) }
                else if !Self.pencilSeen, !cancelled { begin(t) }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let a = active, touches.contains(a) else { return }
        for c in event?.coalescedTouches(for: a) ?? [a] { add(c.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let a = active, touches.contains(a) {
            for c in event?.coalescedTouches(for: a) ?? [a] { add(c.location(in: self)) }
            flush()
            client?.strokeEnd()
            finishLive()
            active = nil
            stopLink()
        }
        allLifted(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let a = active, touches.contains(a) { cancel() }
        allLifted(event)
    }

    private func allLifted(_ event: UIEvent?) {
        let down = event?.allTouches?.contains { $0.phase != .ended && $0.phase != .cancelled } ?? false
        if !down { cancelled = false; active = nil }
    }

    private func begin(_ t: UITouch) {
        active = t
        endHover()
        let p = t.location(in: self)
        // Apple Pencil reports no eraser end on iPad: every stroke is the tip (end = 0)
        client?.strokeBegin(fraction(p))
        startLive(at: p)
        pending = []
        let l = CADisplayLink(target: LinkTarget { [weak self] in self?.flush() }, selector: #selector(LinkTarget.tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func add(_ p: CGPoint) {
        pending.append(fraction(p))
        livePath.addLine(to: p)
        live?.path = livePath.cgPath
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        client?.strokePoints(pending)
        pending = []
    }

    /// A second finger: drop the stroke, and draw nothing more until every finger has lifted.
    private func cancel() {
        drop()
        cancelled = true
    }

    /// The PC forgets the stroke (STROKE_CANCEL) and the iPad's own copy goes.
    private func drop() {
        client?.strokeCancel()
        live?.removeFromSuperlayer()
        live = nil
        pending = []
        active = nil
        stopLink()
    }

    private func stopLink() { link?.invalidate(); link = nil }

    // MARK: the stroke as the iPad draws it (until the PC's picture has it)

    private func startLive(at p: CGPoint) {
        let s = CAShapeLayer()
        s.fillColor = nil
        s.lineCap = .round
        s.lineJoin = .round
        // the PC's pen width is in slide points of a 1024-wide slide: the same share of the picture here
        let zoom = picture.width > 0 ? picture.width / 1024 : 1
        let w = CGFloat(Settings.widths[min(max(state.width, 0), Settings.widths.count - 1)]) * zoom
        let ink = UIColor(hex: Settings.colors[min(max(state.color, 0), Settings.colors.count - 1)])
        switch state.tool {
        case .highlighter:
            s.strokeColor = ink.withAlphaComponent(0.35).cgColor
            s.lineWidth = CGFloat(Settings.highlighterWidth(Double(w)))
        case .laser:
            s.strokeColor = UIColor(hex: Laser.color).cgColor
            s.lineWidth = CGFloat(Laser.width(Double(w)))
        case .eraser:
            s.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
            s.lineWidth = 2
            s.lineDashPattern = [6, 6]
        default:
            s.strokeColor = ink.withAlphaComponent(CGFloat(state.opacity)).cgColor
            s.lineWidth = max(1, w)
        }
        livePath = UIBezierPath()
        livePath.move(to: p)
        livePath.addLine(to: p)   // a dot shows at once
        s.path = livePath.cgPath
        layer.addSublayer(s)
        live = s
    }

    private func finishLive() {
        guard let s = live else { return }
        live = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keepAfterLift) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            s.opacity = 0
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { s.removeFromSuperlayer() }
        }
    }

    // MARK: hover (Apple Pencil above the glass: the laser's dot on the PC)

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            guard active == nil, Date().timeIntervalSince(lastHover) >= Self.batch else { return }
            lastHover = Date()
            hovering = true
            client?.hover(fraction(g.location(in: self)))
        default:
            endHover()
        }
    }

    private func endHover() {
        guard hovering else { return }
        hovering = false
        client?.hoverEnd()
    }
}

/// CADisplayLink holds its target strongly: this small object breaks the cycle.
private final class LinkTarget {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func tick() { action() }
}

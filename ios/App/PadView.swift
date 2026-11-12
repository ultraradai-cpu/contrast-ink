import ContrastInkCore
import SwiftUI
import UIKit

/// The app's own UI test opens pad mode straight onto a fake PC: `-padTest 127.0.0.1:47999 123456` (no Bonjour,
/// which a test runner can't rely on).
enum PadLaunch {
    static let test: (address: String, code: String)? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-padTest"), i + 2 < a.count else { return nil }
        return (a[i + 1], a[i + 2])
    }()
}

/// Pad mode: this iPad shows a PC's screen and what is drawn on it is drawn by the PC (where OBS records it).
/// First the list of PCs and the code, then the PC's screen with a toolbar.
struct PadView: View {
    static let addressKey = "padAddress", codeKey = "padCode", pcKey = "padPC"

    /// Back to the home screen (nil in the UI test, which only ever shows the pad).
    var close: (() -> Void)?
    @StateObject private var client = PadClient()

    var body: some View {
        Group {
            if client.welcome != nil { PadScreen(client: client) } else { PadConnectView(client: client, close: close) }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let t = PadLaunch.test, client.phase == .idle { client.connect(address: t.address, code: t.code) }
        }
        .onDisappear { client.disconnect(); client.stopBrowsing() }
    }
}

// MARK: choosing the PC

struct PadConnectView: View {
    @ObservedObject var client: PadClient
    var close: (() -> Void)?
    @State private var chosen: String? = UserDefaults.standard.string(forKey: PadView.pcKey)
    @State private var address = UserDefaults.standard.string(forKey: PadView.addressKey) ?? ""
    @State private var code = UserDefaults.standard.string(forKey: PadView.codeKey) ?? ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if client.found.isEmpty {
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
                    .disabled(!canConnect || client.phase == .connecting)
                    .accessibilityIdentifier("padConnect")
                    if let why = message { Text(why).foregroundStyle(Color.noticeText) }
                }
            }
            .navigationTitle("Pad for a PC")
            .toolbar {
                if let close {
                    ToolbarItem(placement: .cancellationAction) { Button("Back") { client.disconnect(); close() } }
                }
            }
        }
        // the UI test connects straight to its fake PC: no Bonjour (nor its permission prompt) in a test run
        .onAppear { if PadLaunch.test == nil { client.startBrowsing() } }
    }

    /// The chosen PC, if it's (still) on the network.
    private var chosenPC: PadClient.FoundPC? {
        if let chosen, let pc = client.found.first(where: { $0.name == chosen }) { return pc }
        // nothing chosen and nothing typed: the only PC around is the one
        if address.isEmpty, client.found.count == 1 { return client.found[0] }
        return nil
    }

    private var canConnect: Bool {
        PadProtocol.isCode(code) && (chosenPC != nil || PadProtocol.address(address) != nil)
    }

    private var message: String? {
        if let problem { return problem }
        switch client.phase {
        case .rejected(let why): return why
        case .lost(let why): return why
        default: return nil
        }
    }

    private func connect() {
        problem = nil
        let d = UserDefaults.standard
        d.set(code, forKey: PadView.codeKey)
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
                    .accessibilityLabel("The PC's screen")
                    .accessibilityIdentifier("padPicture")
                    // the whole area takes the pen (one that slides off the picture draws along its edge)
                    PadSurface(client: client, picture: rect, state: client.state)
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .background(Color.black)
        .overlay { if client.phase != .connected { lostCard } }
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
            case .connecting:
                ProgressView()
                Text("Connecting to \(client.connectedName)…")
            case .lost(let why), .rejected(let why):
                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                Text(why).multilineTextAlignment(.center)
                Button { client.reconnect() } label: { Text("Reconnect").bold().frame(minWidth: 160) }
                    .buttonStyle(.borderedProminent).tint(Color.contrastBlue)
                    .accessibilityIdentifier("padReconnect")
            default: EmptyView()
            }
            Button("Disconnect") { client.disconnect() }
        }
        .foregroundStyle(Color.offText)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.inkBar.opacity(0.95)))
    }
}

/// The pad's toolbar, in the look of the presenter's: each button is a COMMAND to the PC, and what is lit up is what
/// the PC says (STATE), so the iPad never shows a tool the PC isn't using.
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

    @ViewBuilder private var actions: some View {
        Button { client.command(PadProtocol.Command.undo) } label: { Image(systemName: "arrow.uturn.backward") }
            .buttonStyle(BarButton(on: false)).named("Undo").accessibilityIdentifier("padUndo")
        Button { client.command(PadProtocol.Command.clear) } label: { Image(systemName: "trash") }
            .buttonStyle(BarButton(on: false)).named("Clear all marks")
        bar
        Button { client.command(PadProtocol.Command.previous) } label: { Image(systemName: "chevron.left") }
            .buttonStyle(BarButton(on: false)).named("Previous slide")
        Button { client.command(PadProtocol.Command.next) } label: { Image(systemName: "chevron.right") }
            .buttonStyle(BarButton(on: false)).named("Next slide")
        bar
        Label(client.connectedName, systemImage: "desktopcomputer")
            .font(.callout).foregroundStyle(Color.offText).lineLimit(1).fixedSize()
            .accessibilityIdentifier("padPCName")
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if active == nil, !cancelled {
                begin(t)
            } else if let a = active, t !== a {
                // a palm while Apple Pencil draws is ignored; any other second touch means "not a stroke"
                if a.type == .pencil, t.type != .pencil { continue }
                cancel()
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

    private func cancel() {
        client?.strokeCancel()
        live?.removeFromSuperlayer()
        live = nil
        pending = []
        active = nil
        cancelled = true
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

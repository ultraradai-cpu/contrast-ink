import ContrastInkCore
import PencilKit
import SwiftUI
import UniformTypeIdentifiers

// Contrast colours, as in the Windows toolbar: logo blue when on, light grey on dark ink when off
extension Color {
    static let inkBar = Color(red: 0x14 / 255, green: 0x1A / 255, blue: 0x22 / 255)
    static let contrastBlue = Color(red: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255)
    static let offText = Color(red: 0xE3 / 255, green: 0xE8 / 255, blue: 0xF0 / 255)
    static let noticeText = Color(red: 1, green: 0.6, blue: 0.55)
}

struct RootView: View {
    @EnvironmentObject var lecture: Lecture

    var body: some View {
        if PadLaunch.test != nil { PadView() }   // the UI test of pad mode, straight onto its fake PC
        else if lecture.deck == nil { HomeView() } else { PresenterView() }
    }
}

// MARK: home

struct HomeView: View {
    @EnvironmentObject var lecture: Lecture
    @State private var decks: [URL] = []
    @State private var picking: Picking?
    @State private var importing = Picking.pdf   // what the open picker is for (kept after it closes)
    @State private var problem: String?
    @State private var padOpen = false

    enum Picking: Identifiable { case pdf, images; var id: Int { hashValue } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { importing = .pdf; picking = .pdf } label: { Label("Open slides (PDF)", systemImage: "doc.richtext") }
                    Button { importing = .images; picking = .images } label: { Label("Open images", systemImage: "photo.on.rectangle") }
                    Button { lecture.open(Deck(title: "Whiteboard", source: .whiteboard)) } label: { Label("Whiteboard", systemImage: "rectangle.and.pencil.and.ellipsis") }
                } footer: {
                    Text("In PowerPoint: File → Export → PDF, then open the PDF here. Each slide keeps its own marks.")
                }
                Section {
                    Button { padOpen = true } label: { Label("Use this iPad as a pad for a PC", systemImage: "ipad.landscape") }
                } footer: {
                    Text("Contrast Ink on the PC shows a code: the PC's screen comes to this iPad, and what you draw here is drawn on the PC (and recorded there).")
                }
                if !decks.isEmpty {
                    Section("Recent slides") {
                        ForEach(decks, id: \.self) { url in
                            Button { open(url) } label: { Label(url.deletingPathExtension().lastPathComponent, systemImage: "rectangle.on.rectangle") }
                        }
                        .onDelete { idx in
                            for i in idx { try? FileManager.default.removeItem(at: decks[i]) }
                            decks = Library.decks()
                        }
                    }
                }
                if let problem { Text(problem).foregroundStyle(Color.noticeText) }
            }
            .navigationTitle("Contrast Ink")
        }
        .onAppear { decks = Library.decks() }
        .fullScreenCover(isPresented: $padOpen) { PadView(close: { padOpen = false }).environmentObject(lecture) }
        // one picker for both (two .fileImporter on one view: some iOS versions only ever show the last)
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: importing == .images ? [.image] : [.pdf],
                      allowsMultipleSelection: importing == .images) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            if importing == .pdf {
                do { open(try Library.add(urls[0])) } catch { problem = "Couldn't open that PDF: \(error.localizedDescription)" }
            } else {
                let images = Library.loadImages(urls)
                if images.isEmpty { problem = "Those files couldn't be read as pictures."; return }
                lecture.open(Deck(title: "Images", source: .images(images)))
            }
        }
    }

    private func open(_ url: URL) {
        guard let deck = Deck.open(pdf: url) else { problem = "\(url.lastPathComponent) couldn't be opened as a PDF."; return }
        Library.touch(url)
        problem = nil
        lecture.open(deck)
    }
}

// MARK: presenting

struct PresenterView: View {
    @EnvironmentObject var lecture: Lecture
    @EnvironmentObject var recorder: LectureRecorder
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(showSettings: $showSettings)
            if let n = recorder.notice {
                Button { recorder.notice = nil } label: {
                    Text(n).font(.footnote).foregroundStyle(Color.noticeText).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12).padding(.vertical, 6).background(Color.inkBar)
                .accessibilityHint("Tap to dismiss")
            }
            // the slide: everything below the toolbar. Only this part is in a recording.
            StageView(lecture: lecture, recorder: recorder)
                .ignoresSafeArea(edges: .bottom)
        }
        .background(Color.black)
        .background(KeyboardShortcuts())
        .overlay(alignment: .bottomTrailing) {
            // the app's UI test reads how many marks are on the slide (invisible, and only in a test run)
            if ProcessInfo.processInfo.arguments.contains("-uitest") {
                Text("\(lecture.drawing.strokes.count)").font(.caption2).opacity(0.02)
                    .accessibilityIdentifier("markCount")
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}

/// Hardware keyboard and presenter clicker keys, from the one table in the core (Keys.table).
struct KeyboardShortcuts: View {
    @EnvironmentObject var lecture: Lecture

    var body: some View {
        ZStack {
            ForEach(Keys.table.indices, id: \.self) { i in
                let (key, action) = Keys.table[i]
                if let k = KeyboardShortcuts.equivalent(key) {
                    Button("") { run(action) }.keyboardShortcut(k, modifiers: [])
                }
            }
            Button("") { lecture.undo() }.keyboardShortcut("z", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    static func equivalent(_ key: String) -> KeyEquivalent? {
        switch key {
        case "right": return .rightArrow
        case "left": return .leftArrow
        case "up": return .upArrow
        case "down": return .downArrow
        case "space": return .space
        case "pageDown": return .pageDown
        case "pageUp": return .pageUp
        case "return": return .return
        default: return key.count == 1 ? KeyEquivalent(Character(key)) : nil
        }
    }

    private func run(_ a: KeyAction) {
        switch a {
        case .next: lecture.next()
        case .previous: lecture.previous()
        case .pen: lecture.choose(.pen)
        case .highlighter: lecture.choose(.highlighter)
        case .arrow: lecture.choose(.arrow)
        case .oval: lecture.choose(.oval)
        case .eraser: lecture.choose(.eraser)
        case .laser: lecture.choose(.laser)
        case .clear: lecture.clear()
        case .fade: lecture.settings.fadingInk.toggle()
        case .thinner: lecture.thinner()
        case .thicker: lecture.thicker()
        case .undo: lecture.undo()
        case .color(let c): lecture.choose(color: c)
        }
    }
}

struct ToolbarView: View {
    @EnvironmentObject var lecture: Lecture
    @EnvironmentObject var recorder: LectureRecorder
    @Binding var showSettings: Bool

    var body: some View {
        // one row when it fits (iPad held sideways); two rows when it doesn't (upright, iPhone); scrolling as a last resort
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { drawing; bar; slides }.padding(.horizontal, 8).padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) { drawing }
                HStack(spacing: 4) { slides }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) { drawing }
                    HStack(spacing: 4) { slides }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.inkBar)
    }

    private var bar: some View { Divider().frame(height: 28).overlay(Color.offText.opacity(0.3)) }

    /// Close, the tools, colours and widths.
    @ViewBuilder private var drawing: some View {
        Button { Task { if recorder.active { await recorder.stop() }; lecture.close() } } label: { Image(systemName: "xmark") }
            .buttonStyle(BarButton(on: false)).named("Close slides")
        bar
        tool(.pen, "pencil.tip", "Pen (P)")
        tool(.highlighter, "highlighter", "Highlighter (H)")
        tool(.arrow, "arrow.up.right", "Arrow (A)")
        tool(.oval, "circle", "Circle (O)")
        tool(.eraser, "eraser", "Eraser (E)")
        Button { lecture.choose(.laser) } label: {
            Image(systemName: "circle.fill").foregroundStyle(lecture.settings.tool == .laser ? Color.white : Color(uiColor: UIColor(hex: Laser.color)))
        }
        .buttonStyle(BarButton(on: lecture.settings.tool == .laser))
        .named("Laser pointer (L)")
        ForEach(Settings.colors.indices, id: \.self) { i in
            Button { lecture.choose(color: i) } label: {
                Circle().fill(Color(uiColor: UIColor(hex: Settings.colors[i])))
                    .overlay(Circle().stroke(Color.offText.opacity(0.6), lineWidth: Settings.colorNames[i] == "Black" ? 1 : 0))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(BarButton(on: false))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.contrastBlue, lineWidth: lecture.settings.color == i ? 2.5 : 0))
            .named("\(Settings.colorNames[i]) (\(i + 1))")
        }
        ForEach(Settings.widths.indices, id: \.self) { i in
            Button { lecture.settings.width = i } label: {
                Circle().frame(width: Settings.widths[i] + 3, height: Settings.widths[i] + 3)
            }
            .buttonStyle(BarButton(on: lecture.settings.width == i))
            .named("\(Settings.widthNames[i]) line")
        }
        Slider(value: $lecture.settings.opacity, in: Settings.minOpacity...1)
            .frame(width: 110)
            .tint(Color.contrastBlue)
            .named("Opacity of the pen, arrow and circle")
        Text("\(Int((lecture.settings.opacity * 100).rounded()))%")
            .font(.callout.monospacedDigit()).foregroundStyle(Color.offText)
            .frame(width: 44, alignment: .leading)
    }

    /// Fading, undo, clear, the slide number, recording and settings.
    @ViewBuilder private var slides: some View {
        Button { lecture.settings.fadingInk.toggle() } label: { Image(systemName: "timer") }
            .buttonStyle(BarButton(on: lecture.settings.fadingInk)).named("Fading ink (F)")
        Button { lecture.undo() } label: { Image(systemName: "arrow.uturn.backward") }
            .buttonStyle(BarButton(on: false)).named("Undo (Z)").accessibilityIdentifier("undo")
        Button { lecture.clear() } label: { Image(systemName: "trash") }
            .buttonStyle(BarButton(on: false)).named("Clear all marks (C)")
        bar
        Button { lecture.previous() } label: { Image(systemName: "chevron.left") }
            .buttonStyle(BarButton(on: false)).named("Previous slide").accessibilityIdentifier("previous")
        Text("\(lecture.page + 1) / \(lecture.pageCount)").font(.callout.monospacedDigit()).foregroundStyle(Color.offText)
            .fixedSize()
            .accessibilityIdentifier("slideNumber")
        Button { lecture.next() } label: { Image(systemName: "chevron.right") }
            .buttonStyle(BarButton(on: false)).named("Next slide").accessibilityIdentifier("next")
        bar
        recordButtons
        Button { showSettings = true } label: { Image(systemName: "gearshape") }
            .buttonStyle(BarButton(on: false)).named("Settings")
    }

    private func tool(_ t: Tool, _ symbol: String, _ name: String) -> some View {
        Button { lecture.choose(t) } label: { Image(systemName: symbol) }
            .buttonStyle(BarButton(on: lecture.settings.tool == t))
            .named(name)
    }

    @ViewBuilder private var recordButtons: some View {
        let on = recorder.active
        Button { recorder.recordTapped() } label: {
            Image(systemName: on ? "stop.circle.fill" : "record.circle")
                .foregroundStyle(recorder.state == .paused ? Color.orange : Color.red)
        }
        .buttonStyle(BarButton(on: false))
        .disabled(recorder.state == .starting || recorder.state == .stopping)
        .named(on ? "Stop recording" : "Record")
        if on {
            Button { recorder.pauseTapped() } label: { Image(systemName: recorder.state == .paused ? "play.fill" : "pause.fill") }
                .buttonStyle(BarButton(on: false))
                .named(recorder.state == .paused ? "Resume recording" : "Pause recording")
            Text(Chapters.time(recorder.elapsed, hours: recorder.elapsed >= 3600))
                .font(.callout.monospacedDigit()).foregroundStyle(Color.offText)
        }
    }
}

extension View {
    /// A toolbar button's name: for screen readers always, and shown on Pencil or pointer hover unless switched off
    /// (Settings → Toolbar → Show button names).
    func named(_ name: String) -> some View { modifier(ButtonName(name: name)) }
}

private struct ButtonName: ViewModifier {
    let name: String
    @EnvironmentObject var lecture: Lecture
    func body(content: Content) -> some View {
        if lecture.settings.showButtonNames { content.accessibilityLabel(name).help(name) }
        else { content.accessibilityLabel(name) }
    }
}

struct BarButton: ButtonStyle {
    var on: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(on ? Color.white : Color.offText)
            .frame(minWidth: 44, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.contrastBlue : Color.clear))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

struct SettingsView: View {
    @EnvironmentObject var lecture: Lecture
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Finger draws too", isOn: $lecture.settings.fingerDraws)
                } footer: { Text("Off: only Apple Pencil draws, and a finger swipes to the next or previous slide.") }
                Section {
                    Toggle("Show button names", isOn: $lecture.settings.showButtonNames)
                } header: { Text("Toolbar") } footer: {
                    Text("Hovering Apple Pencil or a pointer over a button shows its name, like \"Pen (P)\". Off: no names.")
                }
                Section("Undo") {
                    Toggle("Double-tap on Apple Pencil", isOn: $lecture.settings.pencilTapUndoes)
                    Toggle("Two-finger tap on the slide", isOn: $lecture.settings.twoFingerTapUndoes)
                }
                Section("Keys (keyboard or presenter clicker)") {
                    Text("→ ↓ Space Page Down: next slide · ← ↑ Page Up: previous")
                    Text("P pen · H highlighter · A arrow · O circle (Shift: perfect circle) · E eraser")
                    Text("1–6 colour · [ ] thinner / thicker · F fading ink (Shift keeps a mark) · C clear · Z or ⌘Z undo")
                }
                .font(.footnote)
                Section("Projector") {
                    Text("Connect a projector or TV (HDMI adapter or AirPlay): it shows the slide and your marks only, without the toolbar. Marks appear there when the Pencil lifts.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

// MARK: projector

/// What a projector or TV shows: the slide and its marks, filling the screen, nothing else.
struct ProjectorView: View {
    @EnvironmentObject var lecture: Lecture
    @Environment(\.displayScale) private var scale   // the projector's own, not the iPad's

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let deck = lecture.deck {
                    let size = deck.pageSize(lecture.page)
                    let fit = Fit.aspect(Size(size.width, size.height), in: Size(geo.size.width, geo.size.height))
                    ZStack {
                        Image(uiImage: deck.image(lecture.page, pixelWidth: fit.width * scale)).resizable()
                        // PencilKit draws the marks itself: only what changed is redrawn (fading ink changes 30 times a second)
                        ProjectorInk(drawing: lecture.drawing, slideSize: size, viewSize: CGSize(width: fit.width, height: fit.height))
                        ProjectorLaser(scale: fit.width / size.width, penWidth: Settings.widths[lecture.settings.width])
                    }
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.x + fit.width / 2, y: fit.y + fit.height / 2)
                }
            }
        }
        .ignoresSafeArea()
    }

}

/// The laser on the projector, as on the iPad: redrawn every frame while there is something to show.
struct ProjectorLaser: View {
    let scale: CGFloat
    let penWidth: Double
    @ObservedObject private var laser = LaserPointer.shared

    var body: some View {
        TimelineView(.animation(paused: !laser.showing)) { timeline in
            Canvas { ctx, _ in
                ctx.withCGContext { cg in laser.draw(in: cg, scale: scale, penWidth: penWidth, now: timeline.date) }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The marks on the projector: a canvas nobody draws on, zoomed like the iPad's, in light mode (PencilKit would
/// swap black and white in dark mode).
struct ProjectorInk: UIViewRepresentable {
    let drawing: PKDrawing
    let slideSize: CGSize
    let viewSize: CGSize

    func makeUIView(context: Context) -> PKCanvasView {
        let c = PKCanvasView()
        c.isUserInteractionEnabled = false
        c.drawingPolicy = .pencilOnly
        c.backgroundColor = .clear
        c.isOpaque = false
        c.isScrollEnabled = false
        c.showsVerticalScrollIndicator = false
        c.showsHorizontalScrollIndicator = false
        c.contentInsetAdjustmentBehavior = .never
        c.overrideUserInterfaceStyle = .light
        return c
    }

    func updateUIView(_ c: PKCanvasView, context: Context) {
        guard slideSize.width > 0, viewSize.width > 0 else { return }
        let zoom = viewSize.width / slideSize.width
        if c.zoomScale != zoom { c.minimumZoomScale = zoom; c.maximumZoomScale = zoom; c.zoomScale = zoom }
        c.contentSize = viewSize
        c.contentOffset = .zero
        if c.drawing != drawing { c.drawing = drawing }
    }
}

import ContrastInkCore
import PDFKit
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-recorderTest") { RecorderSelfTestView() } else { main }
        #else
        main
        #endif
    }

    @ViewBuilder private var main: some View {
        if PadLaunch.isTest { PadView() }   // the UI test of pad mode, straight onto its fake PC
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
    @State private var working = false
    @State private var padOpen = false
    /// A PDF that needs its password before it opens.
    @State private var locked: Locked?
    @State private var password = ""

    enum Picking: Identifiable { case pdf, images; var id: Int { hashValue } }

    struct Locked {
        let url: URL
        let doc: PDFDocument
    }

    var body: some View {
        NavigationStack {
            List {
                if let expiry = Sideload.warning {
                    Section {
                        Label(expiry, systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(Color.noticeText)
                            .accessibilityIdentifier("expiryWarning")
                    }
                }
                Section {
                    Button { importing = .pdf; picking = .pdf } label: { Label("Open slides (PDF)", systemImage: "doc.richtext") }
                    Button { importing = .images; picking = .images } label: { Label("Open images", systemImage: "photo.on.rectangle") }
                    Button { lecture.open(Deck(title: "Whiteboard", source: .whiteboard, key: "Whiteboard")) } label: { Label("Whiteboard", systemImage: "rectangle.and.pencil.and.ellipsis") }
                } footer: {
                    Text("In PowerPoint: File → Export → PDF, then open the PDF here. Each slide keeps its own marks, and they are kept for the next time you open the slides.")
                }
                Section {
                    Button { padOpen = true } label: { Label("Use this iPad as a pad for a PC", systemImage: "ipad.landscape") }
                } footer: {
                    Text("Contrast Ink on the PC shows a code: the PC's screen comes to this iPad, and what you draw here is drawn on the PC (and recorded there).")
                }
                if working { HStack { ProgressView(); Text("Opening…") } }
                if let problem { Text(problem).foregroundStyle(Color.noticeText).accessibilityIdentifier("homeProblem") }
                if !decks.isEmpty {
                    Section("Recent slides") {
                        ForEach(decks, id: \.self) { url in
                            Button { open(url) } label: {
                                Label(Library.isImageDeck(url) ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent,
                                      systemImage: Library.isImageDeck(url) ? "photo.on.rectangle" : "rectangle.on.rectangle")
                            }
                            .contextMenu {
                                if SavedMarks.exists(key: url.lastPathComponent) {
                                    Button(role: .destructive) { SavedMarks.remove(key: url.lastPathComponent); decks = Library.decks() } label: {
                                        Label("Clear saved marks", systemImage: "eraser")
                                    }
                                }
                            }
                        }
                        .onDelete { idx in
                            for i in idx { Library.remove(decks[i]) }
                            decks = Library.decks()
                        }
                    }
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-importTest") { ImportTestButtons(picked: picked) }
                #endif
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
            picked(urls, importing)
        }
        .alert("This PDF has a password", isPresented: Binding(get: { locked != nil }, set: { if !$0 { locked = nil } })) {
            SecureField("Password", text: $password).accessibilityIdentifier("pdfPassword")
            Button("Open") { unlock() }
            Button("Cancel", role: .cancel) { locked = nil }
        } message: {
            Text("Type the password of \(locked?.url.deletingPathExtension().lastPathComponent ?? "the PDF") to open it.")
        }
    }

    /// Files picked in Files (or by the UI test): copied into the library away from the main thread, then opened.
    private func picked(_ urls: [URL], _ kind: Picking) {
        problem = nil
        working = true
        Task {
            if kind == .pdf {
                let url = urls[0]
                let r = await Task.detached { Result { try Library.add(url) } }.value
                working = false
                switch r {
                case .success(let dest): decks = Library.decks(); open(dest)
                case .failure(let e): problem = e.localizedDescription
                }
            } else {
                let r = await Task.detached { Library.addImages(urls) }.value
                decks = Library.decks()
                guard let folder = r.folder else {
                    working = false
                    problem = SlideImages.unreadable(r.failed, of: urls.count)
                    return
                }
                open(folder, unreadable: SlideImages.unreadable(r.failed, of: urls.count))
            }
        }
    }

    private func open(_ url: URL, unreadable: String? = nil) {
        problem = nil
        if Library.isImageDeck(url) {
            working = true
            Task {
                let deck = await Task.detached { Deck.open(images: url) }.value
                working = false
                guard let deck else { problem = "\(url.lastPathComponent) has no pictures that can be read."; return }
                Library.touch(url)
                lecture.open(deck)
                if let unreadable { lecture.notice = unreadable }
            }
            return
        }
        guard let doc = Deck.open(pdf: url) else { problem = "\(url.lastPathComponent) couldn't be opened as a PDF."; return }
        if doc.isLocked { password = ""; locked = Locked(url: url, doc: doc); return }
        Library.touch(url)
        lecture.open(Deck(title: url.deletingPathExtension().lastPathComponent, source: .pdf(doc), key: url.lastPathComponent))
    }

    private func unlock() {
        guard let l = locked else { return }
        locked = nil
        guard l.doc.unlock(withPassword: password), l.doc.pageCount > 0 else {
            problem = "Wrong password for \(l.url.deletingPathExtension().lastPathComponent)."
            return
        }
        Library.touch(l.url)
        lecture.open(Deck(title: l.url.deletingPathExtension().lastPathComponent, source: .pdf(l.doc), key: l.url.lastPathComponent))
    }
}

#if DEBUG
/// The UI test's way in without the Files picker (`-importTest`, Debug builds only): each button makes the file a
/// test needs and goes through the same import as a picked file.
private struct ImportTestButtons: View {
    let picked: @MainActor ([URL], HomeView.Picking) -> Void

    var body: some View {
        Section("Import test") {
            Button("Locked PDF") { picked([Self.pdf("Locked", password: "secret")], .pdf) }.accessibilityIdentifier("testImportLocked")
            Button("Broken PDF") { picked([Self.file("Broken.pdf", Data("this is not a PDF".utf8))], .pdf) }.accessibilityIdentifier("testImportBroken")
            Button("Same PDF twice") { picked([Self.pdf("Twice")], .pdf) }.accessibilityIdentifier("testImportTwice")
            Button("Pictures, one broken") {
                picked([Self.lines("a.png"), Self.file("b.png", Data("not a picture".utf8)), Self.picture("c.png")], .images)
            }.accessibilityIdentifier("testImportImages")
        }
    }

    private static var dir: URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("import-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func file(_ name: String, _ data: Data) -> URL {
        let u = dir.appendingPathComponent(name)
        try? data.write(to: u)
        return u
    }

    private static func pdf(_ name: String, password: String? = nil) -> URL {
        let f = UIGraphicsPDFRendererFormat()
        if let password {
            f.documentInfo = [kCGPDFContextUserPassword as String: password, kCGPDFContextOwnerPassword as String: password]
        }
        let size = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let data = UIGraphicsPDFRenderer(bounds: size, format: f).pdfData { ctx in
            ctx.beginPage()
            UIColor.darkGray.setFill(); ctx.fill(size)
            (name as NSString).draw(at: CGPoint(x: 80, y: 80), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 56), .foregroundColor: UIColor.white])
        }
        return file("\(name).pdf", data)
    }

    /// Black lines on a see-through background (as a diagram exported from a drawing app often is).
    private static func lines(_ name: String) -> URL {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false
        let img = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600), format: f).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 290, width: 800, height: 20))
            ctx.fill(CGRect(x: 390, y: 0, width: 20, height: 600))
        }
        return file(name, img.pngData() ?? Data())
    }

    private static func picture(_ name: String) -> URL {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        let img = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600), format: f).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        return file(name, img.pngData() ?? Data())
    }
}
#endif

/// A sideloaded copy stops opening when its profile expires (7 days with a free Apple ID): warned 48 hours ahead.
enum Sideload {
    static var expiry: Date? {
        #if DEBUG
        // the UI test: `-expiresIn <seconds>` stands for a profile
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-expiresIn"), i + 1 < a.count, let s = Double(a[i + 1]) { return Date().addingTimeInterval(s) }
        #endif
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return Provision.expiration(data)
    }

    static var warning: String? { Provision.warning(expires: expiry) }
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
                .accessibilityIdentifier("recorderNotice")
            }
            if let n = lecture.notice {
                Button { lecture.notice = nil } label: {
                    Text(n).font(.footnote).foregroundStyle(Color.noticeText).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12).padding(.vertical, 6).background(Color.inkBar)
                .accessibilityHint("Tap to dismiss")
                .accessibilityIdentifier("lectureNotice")
            }
            if lecture.restoredMarks {
                HStack {
                    Text("The marks from last time are back.").font(.footnote).foregroundStyle(Color.offText)
                    Spacer()
                    Button("Clear saved marks") { lecture.clearSavedMarks() }
                        .font(.footnote.bold()).accessibilityIdentifier("clearSavedMarks")
                    Button { lecture.dismissRestored() } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel("Keep them").accessibilityIdentifier("keepSavedMarks")
                }
                .padding(.horizontal, 12).padding(.vertical, 6).background(Color.inkBar)
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
        // the stage's own key commands (Stage.keyCommands), which ask for priority over the system's use of them
        case "pageDown", "pageUp", "return": return nil
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
    @State private var confirmClose = false

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
        // asked once, outside the layouts ViewThatFits tries (each has its own ✕)
        .confirmationDialog("Close the slides?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button(recorder.busy ? "Stop recording and close" : "Close the slides", role: .destructive) { close() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(recorder.busy
                 ? "The recording stops and is saved. Your marks are kept for the next time you open these slides."
                 : "Your marks are kept for the next time you open these slides.")
        }
    }

    private var bar: some View { Divider().frame(height: 28).overlay(Color.offText.opacity(0.3)) }

    /// Close, the tools, colours and widths.
    @ViewBuilder private var drawing: some View {
        Button { if lecture.hasMarks || recorder.busy { confirmClose = true } else { close() } } label: { Image(systemName: "xmark") }
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
        .accessibilityAddTraits(lecture.settings.tool == .laser ? .isSelected : [])
        ForEach(Settings.colors.indices, id: \.self) { i in
            Button { lecture.choose(color: i) } label: {
                Circle().fill(Color(uiColor: UIColor(hex: Settings.colors[i])))
                    .overlay(Circle().stroke(Color.offText.opacity(0.6), lineWidth: Settings.colorNames[i] == "Black" ? 1 : 0))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(BarButton(on: false))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.contrastBlue, lineWidth: lecture.settings.color == i ? 2.5 : 0))
            .named("\(Settings.colorNames[i]) (\(i + 1))")
            .accessibilityAddTraits(lecture.settings.color == i ? .isSelected : [])
        }
        ForEach(Settings.widths.indices, id: \.self) { i in
            Button { lecture.settings.width = i } label: {
                Circle().frame(width: Settings.widths[i] + 3, height: Settings.widths[i] + 3)
            }
            .buttonStyle(BarButton(on: lecture.settings.width == i))
            .named("\(Settings.widthNames[i]) line")
            .accessibilityAddTraits(lecture.settings.width == i ? .isSelected : [])
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
            .accessibilityAddTraits(lecture.settings.fadingInk ? .isSelected : [])
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
            .accessibilityAddTraits(lecture.settings.tool == t ? .isSelected : [])
    }

    /// ✕: a recording (even one still starting) is stopped and saved first; the marks are saved for next time.
    private func close() {
        Task {
            await recorder.stop()
            lecture.close()
        }
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
                Section {
                    Toggle("Also save recordings to Photos", isOn: $lecture.settings.alsoSaveToPhotos)
                        .accessibilityIdentifier("alsoSaveToPhotos")
                } header: { Text("Recording") } footer: {
                    Text("Recordings are always kept in Files → On My iPad → Contrast Ink → Recordings. Off by default: with iCloud Photos on, a copy in Photos is uploaded to iCloud, patient images included.")
                }
                Section("Keys (keyboard or presenter clicker)") {
                    Text("→ ↓ Space Page Down Return: next slide · ← ↑ Page Up: previous")
                    Text("P pen · H highlighter · A arrow · O circle (Shift: perfect circle) · E eraser · L laser pointer")
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
                        ProjectorSlide(deck: deck, page: lecture.page, pixelWidth: fit.width * scale)
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

/// The slide on the projector, drawn away from the main thread (black until it is ready).
struct ProjectorSlide: View {
    let deck: Deck
    let page: Int
    let pixelWidth: CGFloat
    @State private var image: UIImage?
    @State private var shownPage = -1

    var body: some View {
        ZStack {
            Color.black
            if let image, shownPage == page { Image(uiImage: image).resizable() }
        }
        .task(id: "\(ObjectIdentifier(deck).hashValue) \(page) \(Int(pixelWidth))") {
            if let hit = deck.cachedImage(page, pixelWidth: pixelWidth) { image = hit; shownPage = page; return }
            let p = page
            let img = await withCheckedContinuation { (c: CheckedContinuation<UIImage, Never>) in
                deck.loadImage(p, pixelWidth: pixelWidth) { c.resume(returning: $0) }
            }
            image = img
            shownPage = p
        }
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

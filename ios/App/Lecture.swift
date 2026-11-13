import Combine
import ContrastInkCore
import GameController
import PencilKit
import UIKit

/// Everything about the lecture on screen: the deck, the slide, each slide's marks, the tools, and fading ink.
/// One shared copy, so the projector shows exactly what the iPad shows.
@MainActor
final class Lecture: ObservableObject {
    static let shared = Lecture()

    @Published private(set) var deck: Deck?
    @Published private(set) var page = 0
    /// The marks on the slide showing now. Changes whenever a mark is added, removed, undone or fades.
    @Published private(set) var drawing = PKDrawing()
    @Published var settings: Settings { didSet { saveSettings(); applyTool?() } }
    /// The deck opened with marks saved from an earlier time (the presenter may clear them).
    @Published private(set) var restoredMarks = false
    /// Something to tell the presenter on the slides' screen (pictures that couldn't be read), or nil.
    @Published var notice: String?

    /// Called when the tool, colour or width changes (the stage picks up the new pen).
    var applyTool: (() -> Void)?
    /// Called on every slide change (the recorder makes a chapter).
    var slideChanged: ((Int) -> Void)?

    private var marks = PageMarks(empty: PKDrawing())
    // fading ink, by each stroke's creation time (a stroke has no other identity)
    private var fading: [Date: (born: Date, color: UIColor)] = [:]
    private var faded: Set<Date> = []
    private var fadeLink: CADisplayLink?
    /// Marks that belong to slides other than this one: PencilKit can hand one back with the next stroke.
    private var otherSlides: Set<Date> = []
    /// The slide the pen (or a shape's drag) went down on: the stroke is that slide's even if the slide changes first.
    private var penPage = PenPage()
    /// Which slides' marks changed since the last save, and when the next save is due.
    private var debounce = SaveDebounce()
    private var saveTimer: Timer?

    private init() {
        settings = Settings.decode(UserDefaults.standard.data(forKey: "settings"),
                                   isPhone: UIDevice.current.userInterfaceIdiom == .phone)
        // leaving the screen (Home, another app; the iPad's own screen going while a projector stays on): keep the marks
        MainScreen.onLeave { [weak self] in self?.saveMarks(); SavedMarks.flush() }
        // marks are saved a moment after each change (SaveDebounce): a crash loses at most the last seconds
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.saveMarks(force: false) }
        }
    }

    private func saveSettings() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "settings") }
    }

    // MARK: deck and slides

    func open(_ deck: Deck) {
        if self.deck != nil { saveMarks() }
        debounce = SaveDebounce()
        marks.reset()
        fading = [:]; faded = []
        penPage = PenPage()
        self.deck = deck
        page = 0
        otherSlides = []
        // the marks left on this deck last time come back
        var restored: [Int: PKDrawing] = [:]
        if let key = deck.key {
            let saved = SavedMarks.load(key: key)
            if let last = saved.keys.max() { deck.growWhiteboard(to: last + 1) }
            // slides the deck no longer has keep their marks on disk (MarksPlan): only the others are shown
            for (p, data) in MarksPlan.restore(saved, pageCount: deck.pageCount).shown {
                if let d = try? PKDrawing(data: data), !d.strokes.isEmpty { restored[p] = d }
            }
        }
        marks.restore(restored)
        restoredMarks = !restored.isEmpty
        drawing = marks.drawing
        UIApplication.shared.isIdleTimerDisabled = true   // the screen must not dim mid-lecture
    }

    /// Closing the deck ends the lecture; its marks are kept for the next time it is opened.
    func close() {
        saveMarks()
        deck = nil
        marks.reset()
        fading = [:]; faded = []
        restoredMarks = false
        notice = nil
        drawing = PKDrawing()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Any slide has a mark (closing asks first).
    var hasMarks: Bool { marks.hasMarks }

    /// A slide's marks changed: saved a couple of seconds later (or at once on a slide change or leaving the screen).
    private func changed(_ page: Int) { debounce.changed(page: page, now: Date().timeIntervalSinceReferenceDate) }

    /// The slides whose marks changed go to disk, encoded off the main thread. `force`: now (a slide change, leaving
    /// the screen, closing), else only once the debounce is due. Fading marks aren't kept: they were going anyway.
    func saveMarks(force: Bool = true) {
        guard let deck, let key = deck.key,
              let pages = debounce.take(now: Date().timeIntervalSinceReferenceDate, force: force), !pages.isEmpty else { return }
        var changes: [Int: PKDrawing] = [:]
        for p in pages {
            changes[p] = PKDrawing(strokes: marks.drawing(on: p).strokes.filter { fading[$0.path.creationDate] == nil })
        }
        SavedMarks.save(changes, key: key, pageCount: deck.pageCount)
    }

    /// "Keep them": the note about restored marks goes.
    func dismissRestored() { restoredMarks = false }

    /// "Clear saved marks": every slide clean, and nothing kept on disk.
    func clearSavedMarks() {
        guard let deck else { return }
        if let key = deck.key { SavedMarks.remove(key: key) }
        let leaving = marks.drawing.strokes.map(\.path.creationDate)
        otherSlides.formUnion(leaving)
        let p = page
        debounce = SaveDebounce()
        marks.reset()
        marks.show(page: p)
        fading = [:]
        restoredMarks = false
        drawing = marks.drawing
    }

    var pageCount: Int { deck?.pageCount ?? 0 }

    func next() {
        guard let deck else { return }
        if page + 1 >= deck.pageCount {
            guard deck.isWhiteboard else { return }
            deck.addWhiteboardPage()
        }
        go(to: page + 1)
    }

    func previous() { if page > 0 { go(to: page - 1) } }

    func go(to p: Int) {
        guard deck != nil, p != page, p >= 0, p < pageCount else { return }
        // fading marks are not kept for when the slide comes back: they were going anyway
        let leaving = marks.drawing.strokes.map(\.path.creationDate)
        let kept = PKDrawing(strokes: marks.drawing.strokes.filter { fading[$0.path.creationDate] == nil })
        if kept.strokes.count != marks.drawing.strokes.count {
            marks.replaceQuietly(kept)
            // gone for good: undo on this slide later must not bring them back
            for d in leaving where fading[d] != nil { faded.insert(d); fading[d] = nil }
        }
        otherSlides.formUnion(leaving)
        marks.show(page: p)
        otherSlides.subtract(marks.drawing.strokes.map(\.path.creationDate))
        page = p
        drawing = marks.drawing
        slideChanged?(p)
        saveMarks()   // any change waiting: now
    }

    // MARK: marks

    /// The pen touched the slide (or a shape's drag began): what it draws belongs to this slide.
    func beginStroke() { penPage.begin(on: page) }

    /// A shape's drag ended without a shape.
    func cancelStroke() { _ = penPage.finish(current: page) }

    /// The presenter finished a stroke (`new` is the canvas's drawing), or erased marks (`erasing`).
    ///
    /// The slide's marks are the app's, not the canvas's: the canvas can be behind (fading went on while the pen was
    /// down) or hand back marks that aren't this slide's (another slide's, or ones that already faded away). So only
    /// strokes that are really new are taken from it, and only the eraser can take marks away (InkMerge). A stroke
    /// begun before the slide changed (a clicker pressed while the pen was down) goes to the slide it was begun on.
    func canvasChanged(_ new: PKDrawing, erasing: Bool = false) {
        let target = penPage.finish(current: page)
        let ignore = faded.union(otherSlides)
        if target != page, target >= 0, target < pageCount {
            let m = InkMerge.merge(slide: marks.drawing(on: target).strokes, canvas: new.strokes, erasing: erasing,
                                   ignore: ignore, id: { $0.path.creationDate })
            let ids = m.added.map(\.path.creationDate)
            otherSlides.formUnion(ids)   // never this slide's, whatever the canvas hands back later
            if settings.fadingInk && !Lecture.shiftHeld {
                // a fading mark on a slide no longer showing was going anyway (as on any slide change)
                faded.formUnion(ids)
                let kept = m.strokes.filter { !ids.contains($0.path.creationDate) }
                if kept.count != marks.drawing(on: target).strokes.count { marks.commit(PKDrawing(strokes: kept), on: target) }
            } else {
                marks.commit(PKDrawing(strokes: m.strokes), on: target)
            }
            drawing = marks.drawing   // the canvas shows this slide's marks again when the pen lifts
            changed(target)
            return
        }
        let m = InkMerge.merge(slide: marks.drawing.strokes, canvas: new.strokes, erasing: erasing,
                               ignore: ignore, id: { $0.path.creationDate })
        if settings.fadingInk && !Lecture.shiftHeld && !m.added.isEmpty {
            for s in m.added { fading[s.path.creationDate] = (Date(), s.ink.color) }
            startFading()
        }
        marks.commit(PKDrawing(strokes: m.strokes))
        drawing = marks.drawing   // also puts the canvas right when it showed something else
        changed(page)
    }

    /// An arrow or oval was drawn: one stroke, like any mark, on the slide its drag began on.
    func add(shape points: [Pt]) {
        guard points.count > 1 else { cancelStroke(); return }
        let tool = settings.tool
        let width = CGFloat(Settings.widths[settings.width])
        let stroke = Lecture.stroke(points, color: tool == .highlighter ? inkColor : markColor, width: width, marker: tool == .highlighter)
        let target = penPage.finish(current: page)
        var d = marks.drawing(on: target)
        d.strokes.append(stroke)
        penPage.begin(on: target)
        canvasChanged(d)
    }

    func undo() {
        let gone = faded
        marks.undo { d in PKDrawing(strokes: d.strokes.filter { !gone.contains($0.path.creationDate) }) }
        // a mark brought back that was fading starts its time again, fully visible
        var d = marks.drawing, changed = false
        for (i, s) in d.strokes.enumerated() {
            guard let f = fading[s.path.creationDate] else { continue }
            fading[s.path.creationDate] = (Date(), f.color)
            d.strokes[i].ink = PKInk(s.ink.inkType, color: f.color)
            changed = true
        }
        if changed { marks.replaceQuietly(d); startFading() }
        drawing = marks.drawing
        self.changed(page)
    }

    func clear() {
        marks.clear()
        drawing = marks.drawing
        changed(page)
    }

    var canUndo: Bool { marks.canUndo }

    func drawing(on page: Int) -> PKDrawing { page == self.page ? drawing : marks.drawing(on: page) }

    // MARK: tools

    var inkColor: UIColor { UIColor(hex: Settings.colors[settings.color]) }
    /// The pen's, arrow's and circle's colour at the chosen opacity (the highlighter keeps its own see-through look).
    var markColor: UIColor { inkColor.withAlphaComponent(CGFloat(settings.opacity)) }

    var pkTool: PKTool {
        let w = CGFloat(Settings.widths[settings.width])
        switch settings.tool {
        case .pen, .arrow, .oval, .laser: return PKInkingTool(.pen, color: markColor, width: w)   // the laser never reaches the canvas
        case .highlighter: return PKInkingTool(.marker, color: inkColor, width: CGFloat(Settings.highlighterWidth(Double(w))))
        case .eraser: return PKEraserTool(.vector)   // touch a mark to remove it, as on Windows
        }
    }

    func choose(_ tool: Tool) { settings.tool = tool }

    func choose(color: Int) {
        settings.color = color
        if settings.tool == .eraser { settings.tool = .pen }   // picking a colour means "draw"
    }

    func thinner() { settings.width = max(0, settings.width - 1) }
    func thicker() { settings.width = min(Settings.widths.count - 1, settings.width + 1) }

    /// Shift on a hardware keyboard: keeps a fading mark, and makes an oval a circle.
    static var shiftHeld: Bool {
        guard let k = GCKeyboard.coalesced?.keyboardInput else { return false }
        return k.button(forKeyCode: .leftShift)?.isPressed == true || k.button(forKeyCode: .rightShift)?.isPressed == true
    }

    // MARK: fading ink

    private func startFading() {
        guard fadeLink == nil else { return }
        let link = CADisplayLink(target: FadeTarget { [weak self] in self?.fadeTick() }, selector: #selector(FadeTarget.tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        fadeLink = link
    }

    private func fadeTick() {
        let now = Date()
        var d = marks.drawing, changed = false
        var keep: [PKStroke] = []
        for s in d.strokes {
            guard let f = fading[s.path.creationDate] else { keep.append(s); continue }
            let o = Fade.opacity(age: now.timeIntervalSince(f.born))
            if o <= 0 { faded.insert(s.path.creationDate); fading[s.path.creationDate] = nil; changed = true; continue }
            var t = s
            if o < 1 {
                var a: CGFloat = 0; f.color.getRed(nil, green: nil, blue: nil, alpha: &a)
                t.ink = PKInk(s.ink.inkType, color: f.color.withAlphaComponent(a * o))
                changed = true
            }
            keep.append(t)
        }
        if changed { d = PKDrawing(strokes: keep); marks.replaceQuietly(d); drawing = d }
        // marks cleared or on another slide: forgotten after a while (they can no longer come back sensibly)
        let onSlide = Set(d.strokes.map(\.path.creationDate))
        for (k, f) in fading where !onSlide.contains(k) && now.timeIntervalSince(f.born) > 120 { fading[k] = nil }
        if !fading.keys.contains(where: onSlide.contains) { fadeLink?.invalidate(); fadeLink = nil }
    }

    // MARK: building strokes

    /// One ink line through `points` (slide points), with sharp corners.
    static func stroke(_ points: [Pt], color: UIColor, width: CGFloat, marker: Bool) -> PKStroke {
        let pts = Shapes.sharpCorners(points).enumerated().map { i, p in
            PKStrokePoint(location: CGPoint(x: p.x, y: p.y), timeOffset: TimeInterval(i) * 0.005,
                          size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(marker ? .marker : .pen, color: color), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }
}

/// CADisplayLink holds its target strongly: this small object breaks the cycle.
private final class FadeTarget {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func tick() { action() }
}

extension UIColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

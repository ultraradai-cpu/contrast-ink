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

    private init() {
        settings = Settings.decode(UserDefaults.standard.data(forKey: "settings"))
    }

    private func saveSettings() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "settings") }
    }

    // MARK: deck and slides

    func open(_ deck: Deck) {
        marks.reset()
        fading = [:]; faded = []
        self.deck = deck
        page = 0
        otherSlides = []
        drawing = marks.drawing
        UIApplication.shared.isIdleTimerDisabled = true   // the screen must not dim mid-lecture
    }

    /// Closing the deck ends the lecture: its marks go with it (as when a slide show ends on Windows).
    func close() {
        deck = nil
        marks.reset()
        fading = [:]; faded = []
        drawing = PKDrawing()
        UIApplication.shared.isIdleTimerDisabled = false
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
    }

    // MARK: marks

    /// The presenter finished a stroke (`new` is the canvas's drawing), or erased marks (`erasing`).
    ///
    /// The slide's marks are the app's, not the canvas's: the canvas can be behind (fading went on while the pen was
    /// down) or hand back marks that aren't this slide's (another slide's, or ones that already faded away). So only
    /// strokes that are really new are taken from it, and only the eraser can take marks away.
    func canvasChanged(_ new: PKDrawing, erasing: Bool = false) {
        let current = marks.drawing.strokes
        let known = Set(current.map(\.path.creationDate))
        let onCanvas = Set(new.strokes.map(\.path.creationDate))
        var strokes = erasing ? current.filter { onCanvas.contains($0.path.creationDate) } : current
        let added = new.strokes.filter {
            let d = $0.path.creationDate
            return !known.contains(d) && !faded.contains(d) && !otherSlides.contains(d)
        }
        if settings.fadingInk && !Lecture.shiftHeld && !added.isEmpty {
            for s in added { fading[s.path.creationDate] = (Date(), s.ink.color) }
            startFading()
        }
        strokes += added
        marks.commit(PKDrawing(strokes: strokes))
        drawing = marks.drawing   // also puts the canvas right when it showed something else
    }

    /// An arrow or oval was drawn: one stroke, like any mark.
    func add(shape points: [Pt]) {
        guard points.count > 1 else { return }
        let tool = settings.tool
        let width = CGFloat(Settings.widths[settings.width])
        let stroke = Lecture.stroke(points, color: tool == .highlighter ? inkColor : markColor, width: width, marker: tool == .highlighter)
        var d = marks.drawing
        d.strokes.append(stroke)
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
    }

    func clear() {
        marks.clear()
        drawing = marks.drawing
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

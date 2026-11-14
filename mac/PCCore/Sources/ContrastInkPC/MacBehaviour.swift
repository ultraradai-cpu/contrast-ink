import ContrastInkCore
import Foundation

/// Hold Control to draw, without taking Control-click (the Mac's right-click) or Control-drag (Horos, OsiriX) from
/// the app below: drawing starts only once Control has been held on its own for `delay` with no mouse button pressed.
/// A click while Control is down passes through, and drawing doesn't start until Control is let go and held again.
/// Fed by polling (the modifier keys and mouse buttons, which need no permission) and by mouse-down events.
public struct ControlHold: Equatable, Sendable {
    public static let delay: TimeInterval = 0.3
    public enum Change: Equatable, Sendable { case start, stop }

    private var downSince: Double?
    private var clicked = false
    /// Drawing is on because Control is held.
    public private(set) var drawing = false

    public init() {}

    /// The state now: Control down with no other modifier, any mouse button down. `.start` or `.stop` when drawing
    /// should switch on or off.
    public mutating func update(controlAlone: Bool, mouseDown: Bool, now: Double) -> Change? {
        guard controlAlone else {
            downSince = nil
            clicked = false
            if drawing { drawing = false; return .stop }
            return nil
        }
        if drawing { return nil }
        if mouseDown { click() }
        if clicked { return nil }
        guard let since = downSince else { downSince = now; return nil }
        guard now - since >= Self.delay else { return nil }
        drawing = true
        return .start
    }

    /// A mouse button went down: before drawing started, the click is the app's (Control-click, Control-drag).
    public mutating func click() {
        guard !drawing else { return }
        clicked = true
        downSince = nil
    }

    /// Drawing was switched off some other way (Esc, F9): wait for Control to be let go before starting again.
    public mutating func stopped() {
        if drawing { drawing = false; clicked = true }
    }
}

/// Which screen the drawing layer covers, by the screens' IDs (display UUIDs) in macOS's order (the first is the
/// main screen, with the menu bar).
public enum ScreenChoice {
    /// The chosen screen when it is connected; the main screen while it isn't (a projector's dropout: it comes back
    /// by itself when the screen returns). With no screen chosen by ID (an older saved copy), the saved index.
    /// Nil when macOS lists no screen for the moment.
    public static func index(ids: [String], chosenID: String?, savedIndex: Int) -> Int? {
        guard !ids.isEmpty else { return nil }
        if let chosenID { return ids.firstIndex(of: chosenID) ?? 0 }
        return ids.indices.contains(savedIndex) ? savedIndex : 0
    }

    /// The 🖥 button: the screen after the one covered now.
    public static func next(ids: [String], covered: Int) -> Int? {
        guard ids.count > 1 else { return nil }
        return (covered + 1) % ids.count
    }
}

/// The marks kept for each screen: the layer moving to another screen (the presenter's 🖥, or a projector dropping
/// out for a moment) shows that screen's own marks, and the first screen's come back with it. A screen whose size
/// changed (a new resolution) gets its marks stretched to the new size.
public struct ScreenMarks: Sendable {
    private struct Kept: Sendable { var board: InkBoard; var width: Double; var height: Double }
    private var kept: [String: Kept] = [:]
    public private(set) var current: String?
    private var width = 0.0, height = 0.0

    public init() {}

    /// The layer covers screen `id`, this size, from now on. `board`: the marks shown until now (those of the screen
    /// covered before). Returns the marks to show.
    public mutating func cover(_ id: String, width w: Double, height h: Double, board: InkBoard) -> InkBoard {
        defer { current = id; width = w; height = h }
        if current == id { return Self.fit(board, width, height, w, h) }
        if let c = current { kept[c] = Kept(board: board, width: width, height: height) }
        guard let k = kept.removeValue(forKey: id) else { return InkBoard() }
        return Self.fit(k.board, k.width, k.height, w, h)
    }

    private static func fit(_ b: InkBoard, _ w0: Double, _ h0: Double, _ w: Double, _ h: Double) -> InkBoard {
        guard w0 > 0, h0 > 0, w > 0, h > 0 else { return b }
        return b.scaled(x: w / w0, y: h / h0)
    }
}

/// ✕ with something that quitting would lose or cut off: asked first.
public enum QuitCheck {
    /// The question to ask, or nil to quit at once.
    public static func question(marks: Int, recording: Bool, tablet: Bool) -> String? {
        var what: [String] = []
        if marks > 0 { what.append(marks == 1 ? "the mark on the screen goes" : "the \(marks) marks on the screen go") }
        if recording { what.append("OBS goes on recording without Contrast Ink's ⏹") }
        if tablet { what.append("the tablet is disconnected") }
        guard !what.isEmpty else { return nil }
        let list = what.count == 1 ? what[0] : what.dropLast().joined(separator: ", ") + " and " + what.last!
        return "Quit Contrast Ink? " + list.prefix(1).uppercased() + list.dropFirst() + "."
    }
}

/// Something that would otherwise be said again and again (a failing picture of the screen, twice a second): said
/// once for each key, until reset (a new tablet connection).
public struct OnceEach: Sendable {
    private var said = Set<String>()
    public init() {}
    /// True the first time for this key.
    public mutating func first(_ key: String) -> Bool { said.insert(key).inserted }
    public mutating func reset() { said = [] }
}

/// The log file: kept at most `maxBytes`; past that it becomes "<name>.old.log" (one old file, replaced each time).
public enum LogFile {
    public static let maxBytes = 1_000_000

    public static func oldURL(_ url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("old").appendingPathExtension(url.pathExtension.isEmpty ? "log" : url.pathExtension)
    }

    /// Adds a line, rotating first when it wouldn't fit.
    public static func append(_ line: String, to url: URL, maxBytes: Int = maxBytes) {
        let data = Data(line.utf8)
        let fm = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        if size > 0, size + data.count > maxBytes {
            let old = oldURL(url)
            try? fm.removeItem(at: old)
            if (try? fm.moveItem(at: url, to: old)) == nil { try? fm.removeItem(at: url) }
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// What the Mac tells the presenter about its permissions (kept here so the tests can hold it to what is true).
public enum MacTexts {
    /// Without Screen Recording, macOS 14 and later give no picture at all (13 gives the desktop picture only).
    public static let screenRecordingMissing = "Screen Recording: not allowed yet (the tablet then shows no picture of the screen)."
    /// Under the pad's addresses while no tablet is connected: networks that keep devices apart (hospital Wi-Fi).
    public static let noSharedWifi = "No shared Wi-Fi? Internet Sharing needs Ethernet or iPhone USB as its source; otherwise use a phone hotspot or the USB cable."
    public static let screenRecordingForTablet = "The tablet's picture of the screen needs Screen Recording: System Settings → Privacy & Security → Screen Recording → Contrast Ink, then quit and reopen it. Until then the tablet shows no picture."
}

/// The toolbar's fixed colours (Look on the Mac), checked against WCAG AA in the tests: text 4.5:1 on the bar and on
/// a button under the pointer, glyphs that only mark a state 3:1.
public enum MacPalette {
    public static let bar = "#141A22"
    public static let ink = "#E3E8F0"
    /// The logo blue: a chosen button's fill (white text on it), the chosen colour's ring.
    public static let blue = "#2563EB"
    /// Blue as text on the bar (the grip's dots): the logo blue is too dark for text there.
    public static let blueText = "#60A5FA"
    /// Secondary text: headings, permissions, the ⏺ of an unconnected OBS.
    public static let grey = "#9AA5B5"
    /// The film under the pointer: ink at this opacity over the bar.
    public static let hoverAlpha = 0.1
    public static let recRed = "#FF6159"
    public static let amber = "#FFB020"
    public static let warning = "#FA8072"
    /// The laser button's ● (the laser itself is Core's Laser.color).
    public static let laserGlyph = "#FF6464"

    /// The bar under the pointer: the hover film over the bar.
    public static var hover: String { Contrast.blend(ink, over: bar, alpha: hoverAlpha) }
}

/// WCAG 2 contrast.
public enum Contrast {
    public static func luminance(_ hex: String) -> Double {
        let c = Ink.rgb(hex) ?? (0, 0, 0)
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    public static func ratio(_ a: String, _ b: String) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `top` at `alpha` over `bottom`, as a colour.
    public static func blend(_ top: String, over bottom: String, alpha: Double) -> String {
        let t = Ink.rgb(top) ?? (0, 0, 0), b = Ink.rgb(bottom) ?? (0, 0, 0)
        func m(_ x: Double, _ y: Double) -> Int { Int(((x * alpha + y * (1 - alpha)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", m(t.r, b.r), m(t.g, b.g), m(t.b, b.b))
    }
}

/// The part of the drawing layer a stroke covers, for drawing only that part again.
public enum InkArea {
    /// The box around the points, widened by `pad` on every side (half the line's width and a little more). Nil with
    /// no points.
    public static func bounds(_ pts: [Pt], pad: Double) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard let f = pts.first else { return nil }
        var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
        for p in pts.dropFirst() { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return (minX - pad, minY - pad, maxX - minX + 2 * pad, maxY - minY + 2 * pad)
    }

    /// The points a pen or highlighter line added since it had `drawn` points: those to draw again, with the one
    /// before them (the join). A shape (arrow, oval) changes whole: all of it.
    public static func fresh(_ pts: [Pt], drawn: Int, wholeShape: Bool) -> [Pt] {
        if wholeShape || drawn <= 0 || drawn > pts.count { return pts }
        return Array(pts[(drawn - 1)...])
    }
}

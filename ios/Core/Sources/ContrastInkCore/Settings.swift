import Foundation

public enum Tool: String, Codable, CaseIterable, Sendable { case pen, highlighter, arrow, oval, eraser }

/// What the app remembers between lectures. The same colours, widths and tools as the Windows app.
public struct Settings: Codable, Equatable, Sendable {
    // red, yellow, green, cyan and white stand out on dark MR/CT images; black is for white slides; red works on both
    public static let colors = ["#FF3B30", "#FFD60A", "#34C759", "#00D4FF", "#FFFFFF", "#111111"]
    public static let colorNames = ["Red", "Yellow", "Green", "Cyan", "White", "Black"]
    /// Pen thickness in slide points (a slide is laid out 1024 points wide): thin for labels, thick for a video.
    public static let widths: [Double] = [3, 6, 10]
    public static let widthNames = ["Thin", "Medium", "Thick"]

    /// The highlighter is a wide, see-through version of the same thickness.
    public static func highlighterWidth(_ width: Double) -> Double { width * 4 + 6 }

    public var tool: Tool = .pen
    public var color = 0
    public var width = 1
    public var fadingInk = false
    /// Off: only Apple Pencil draws, a finger swipes slides (like the Windows app, where a finger always clicks).
    public var fingerDraws = false
    /// Double-tap on Apple Pencil (2nd generation, Pro) undoes the last mark.
    public var pencilTapUndoes = true
    /// A two-finger tap on the slide undoes the last mark.
    public var twoFingerTapUndoes = true

    public init() {}

    /// Keeps every value in range, so an old or damaged saved copy can't break the app.
    public func cleaned() -> Settings {
        var s = self
        s.color = min(max(s.color, 0), Settings.colors.count - 1)
        s.width = min(max(s.width, 0), Settings.widths.count - 1)
        return s
    }

    /// Reads a saved copy. Anything missing keeps its default; anything unreadable gives the defaults.
    public static func decode(_ json: Data?) -> Settings {
        guard let json, let s = try? JSONDecoderLenient.decode(json) else { return Settings() }
        return s.cleaned()
    }
}

/// Decodes Settings while tolerating keys a newer or older version added or dropped.
enum JSONDecoderLenient {
    static func decode(_ data: Data) throws -> Settings {
        let any = try JSONSerialization.jsonObject(with: data)
        guard let d = any as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
        var s = Settings()
        if let v = d["tool"] as? String, let t = Tool(rawValue: v) { s.tool = t }
        if let v = d["color"] as? Int { s.color = v }
        if let v = d["width"] as? Int { s.width = v }
        if let v = d["fadingInk"] as? Bool { s.fadingInk = v }
        if let v = d["fingerDraws"] as? Bool { s.fingerDraws = v }
        if let v = d["pencilTapUndoes"] as? Bool { s.pencilTapUndoes = v }
        if let v = d["twoFingerTapUndoes"] as? Bool { s.twoFingerTapUndoes = v }
        return s
    }
}

/// What a key on a hardware keyboard or a presenter clicker does. One table, as in the Windows app's KeyPolicy:
/// the slide keys work like PowerPoint's, the letters choose tools.
public enum KeyAction: Equatable, Sendable {
    case next, previous, pen, highlighter, arrow, oval, eraser, clear, fade, thinner, thicker, undo, color(Int)
}

public enum Keys {
    /// Key name → action. Names are single characters, or "right", "left", "down", "up", "space", "pageDown",
    /// "pageUp", "return" for the keys a presenter clicker sends.
    public static let table: [(key: String, action: KeyAction)] = [
        ("right", .next), ("down", .next), ("space", .next), ("pageDown", .next), ("return", .next),
        ("left", .previous), ("up", .previous), ("pageUp", .previous),
        ("p", .pen), ("h", .highlighter), ("a", .arrow), ("o", .oval), ("e", .eraser),
        ("c", .clear), ("f", .fade), ("[", .thinner), ("]", .thicker), ("z", .undo),
    ] + (0..<Settings.colors.count).map { (String($0 + 1), KeyAction.color($0)) }

    public static func action(for key: String) -> KeyAction? { table.first { $0.key == key }?.action }
}

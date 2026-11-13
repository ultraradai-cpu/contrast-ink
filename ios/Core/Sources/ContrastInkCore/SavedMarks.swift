import Foundation

/// Which slide a stroke belongs to: the one showing when the pen (or the arrow or circle) went down. A slide change
/// while the pen is still on the glass (a clicker, a key) must not carry the stroke onto the next slide.
public struct PenPage: Equatable, Sendable {
    public private(set) var began: Int?
    public init() {}

    /// The pen touched down, or a shape's drag began, on `page`.
    public mutating func begin(on page: Int) { began = page }

    /// The stroke reached the app: the slide it began on (or `current` when no beginning was seen). Forgotten after.
    public mutating func finish(current: Int) -> Int {
        defer { began = nil }
        return began ?? current
    }
}

/// What a slide's marks become when the canvas changes. The canvas can be behind (fading went on while the pen was
/// down) or hand back marks that aren't this slide's (another slide's, or ones that already faded away), so only
/// strokes that are really new are taken from it, and only the eraser can take marks away.
public enum InkMerge {
    /// `slide`: the slide's marks now. `canvas`: what the canvas holds. `ignore`: strokes that must never come back
    /// (faded away, or another slide's). Returns the slide's new marks and the strokes that were added.
    public static func merge<S, ID: Hashable>(slide: [S], canvas: [S], erasing: Bool, ignore: Set<ID>,
                                             id: (S) -> ID) -> (strokes: [S], added: [S]) {
        let known = Set(slide.map(id))
        let onCanvas = Set(canvas.map(id))
        var strokes = erasing ? slide.filter { onCanvas.contains(id($0)) } : slide
        let added = canvas.filter { let d = id($0); return !known.contains(d) && !ignore.contains(d) }
        strokes += added
        return (strokes, added)
    }
}

/// Each deck's marks kept on disk (Application Support/Marks/<deck>.marks), so a crash, the battery or closing the
/// deck doesn't lose them: page number → that slide's drawing, as bytes (PencilKit's own data on iPad).
public enum MarksFile {
    public static let version = 1

    public static func encode(_ pages: [Int: Data]) -> Data {
        var p: [String: String] = [:]
        for (k, v) in pages where !v.isEmpty { p[String(k)] = v.base64EncodedString() }
        let object: [String: Any] = ["version": version, "pages": p]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Unreadable or damaged: nothing (the deck opens clean rather than not at all).
    public static func decode(_ data: Data?) -> [Int: Data] {
        guard let data, let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = any["pages"] as? [String: String] else { return [:] }
        var out: [Int: Data] = [:]
        for (k, v) in pages {
            guard let n = Int(k), n >= 0, let d = Data(base64Encoded: v), !d.isEmpty else { continue }
            out[n] = d
        }
        return out
    }

    /// The file's name for a deck's key (its file or folder name): no path separators, never empty.
    public static func fileName(forDeck key: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:")
        let safe = String(key.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (safe.isEmpty ? "Deck" : safe) + ".marks"
    }
}

extension PageMarks {
    /// A change on another slide than the one showing: a stroke begun on it that ended after the slide changed.
    public mutating func commit(_ new: Drawing, on page: Int) {
        let shown = current
        current = page
        commit(new)
        current = shown
    }

    /// Every slide that has marks (to save them).
    public var savedPages: [Int: Drawing] { pages.filter { $0.value.drawing != empty }.mapValues(\.drawing) }

    /// Marks saved earlier come back, with no history to undo.
    public mutating func restore(_ saved: [Int: Drawing]) {
        for (k, v) in saved where v != empty { pages[k] = Page(drawing: v) }
    }

    /// Any slide has a mark.
    public var hasMarks: Bool { pages.values.contains { $0.drawing != empty } }
}

/// Each slide's marks and its own undo history. The next slide starts clean; going back shows its marks again.
/// Generic over the drawing type, so it is tested with plain values (the app uses Apple's PKDrawing).
public struct PageMarks<Drawing: Equatable> {
    struct Page { var drawing: Drawing; var history: [Drawing] = [] }

    public let empty: Drawing
    public let historyLimit: Int
    var pages: [Int: Page] = [:]
    public private(set) var current = 0

    public init(empty: Drawing, historyLimit: Int = 100) {
        self.empty = empty
        self.historyLimit = historyLimit
    }

    /// The marks on the slide showing now.
    public var drawing: Drawing { pages[current]?.drawing ?? empty }

    /// The marks on any slide (for a projector or a recording that shows another slide).
    public func drawing(on page: Int) -> Drawing { pages[page]?.drawing ?? empty }

    public var canUndo: Bool { !(pages[current]?.history.isEmpty ?? true) }

    /// Shows another slide. Its marks come back as they were left.
    public mutating func show(page: Int) { current = page }

    /// The presenter changed the marks (a stroke, an erase, a shape): remembered so it can be undone.
    public mutating func commit(_ new: Drawing) {
        let old = drawing
        guard new != old else { return }
        var p = pages[current] ?? Page(drawing: empty)
        p.history.append(old)
        if p.history.count > historyLimit { p.history.removeFirst(p.history.count - historyLimit) }
        p.drawing = new
        pages[current] = p
    }

    /// A change that is not the presenter's (fading ink thinning or going away): not something to undo.
    public mutating func replaceQuietly(_ new: Drawing) {
        var p = pages[current] ?? Page(drawing: empty)
        p.drawing = new
        pages[current] = p
    }

    /// Removes every mark on this slide. Undo brings them back.
    public mutating func clear() { commit(empty) }

    /// Goes back one step. `cleaning` takes out what must not come back (marks that already faded away); a step
    /// that only differed by those is skipped, as in the Windows app. Returns false when there was nothing to undo.
    @discardableResult
    public mutating func undo(cleaning: (Drawing) -> Drawing = { $0 }) -> Bool {
        guard var p = pages[current] else { return false }
        while let previous = p.history.popLast() {
            let restored = cleaning(previous)
            if restored == p.drawing { continue }
            p.drawing = restored
            pages[current] = p
            return true
        }
        pages[current] = p
        return false
    }

    /// Forgets every slide's marks (a new deck, or the deck closed: marks go with it).
    public mutating func reset() { pages = [:]; current = 0 }
}

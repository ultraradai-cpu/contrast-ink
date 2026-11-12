/// Chapters for a recorded lecture, the same rules as the Windows app (Obs.cs), in the form YouTube reads from a
/// video description: "0:00 Slide 1", one per line, the first at 0:00 and in time order.
public enum Chapters {
    /// A chapter less than a second after the previous one (slides clicked past quickly) replaces it.
    public static func text(_ chapters: [(at: Double, name: String)]) -> String {
        var kept: [(at: Double, name: String)] = []
        for c in chapters.enumerated().sorted(by: { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }).map(\.element) {
            let at = max(0, c.at)
            if let last = kept.last, at - last.at < 1 { kept[kept.count - 1] = (last.at, c.name) }
            else { kept.append((at, c.name)) }
        }
        guard !kept.isEmpty else { return "" }
        if kept[0].at >= 1 { kept.insert((0, "Start"), at: 0) } else { kept[0] = (0, kept[0].name) }
        let hours = kept[kept.count - 1].at >= 3600
        return kept.map { time($0.at, hours: hours) + " " + $0.name }.joined(separator: "\n") + "\n"
    }

    /// "4:05", or "1:04:05" when the video passes an hour (then every line has hours, as YouTube expects).
    public static func time(_ seconds: Double, hours: Bool) -> String {
        let s = Int(max(0, seconds))
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return hours ? "\(s / 3600):\(two(s / 60 % 60)):\(two(s % 60))" : "\(s / 60):\(two(s % 60))"
    }
}

/// The recording's own clock: time in the video, with paused stretches cut out. Times are seconds on the device's
/// host clock (the clock screen-recording frames are stamped with).
public struct Timeline: Equatable, Sendable {
    public private(set) var start: Double?
    public private(set) var pausedTotal: Double = 0
    public private(set) var pausedAt: Double?
    /// When recording last resumed: a sample stamped before it was made during the pause (it can arrive late).
    public private(set) var resumedAt: Double?
    public init() {}

    public var started: Bool { start != nil }
    public var paused: Bool { pausedAt != nil }

    /// The video begins with the first frame written (not while paused: a pause pressed before any picture arrived
    /// holds the start back until resume).
    public mutating func begin(at t: Double) { if start == nil, pausedAt == nil { start = t } }

    public mutating func pause(at t: Double) { if pausedAt == nil { pausedAt = t } }

    public mutating func resume(at t: Double) {
        guard let p = pausedAt else { return }
        if start != nil { pausedTotal += max(0, t - p) }
        pausedAt = nil
        resumedAt = t
    }

    /// Where a frame stamped `t` goes in the video; nil when it must be left out (before the start, paused, or
    /// made during a pause and arriving after it).
    public func videoTime(_ t: Double) -> Double? {
        guard let s = start, pausedAt == nil else { return nil }
        if let r = resumedAt, t < r { return nil }
        let v = t - s - pausedTotal
        return v < 0 ? nil : v
    }

    /// How long the video is at host time `t` (for the timer on the toolbar and for chapters).
    public func elapsed(at t: Double) -> Double {
        guard let s = start else { return 0 }
        let pausedNow = pausedAt.map { max(0, t - $0) } ?? 0
        return max(0, t - s - pausedTotal - pausedNow)
    }
}

/// Keeps one track's times going forward: the video writer stops for good at a sample that isn't later than the last.
public struct Forward: Sendable {
    public private(set) var last: Double?
    public init() {}
    /// True (and remembered) when `t` is later than every time let through before.
    public mutating func admit(_ t: Double) -> Bool {
        if let l = last, t <= l { return false }
        last = t
        return true
    }
}

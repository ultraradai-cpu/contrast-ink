import Foundation

/// Room on the iPad for a recording. A lecture is about 3 GB an hour, and the copy to Photos (when switched on)
/// needs as much again at the end: a full iPad must not end a lecture with a broken file.
public enum RecordingSpace {
    /// Under this, recording doesn't start.
    public static let startMinimum: Int64 = 1_000_000_000
    /// Under this while recording, the presenter is told (once).
    public static let warnBelow: Int64 = 1_000_000_000
    /// Under this while recording, it stops by itself and keeps the file.
    public static let stopBelow: Int64 = 300_000_000

    public enum Verdict: Equatable, Sendable {
        case fine
        case warn(String)
        case stop(String)
    }

    static func mb(_ bytes: Int64) -> String { "\(max(0, bytes) / 1_000_000) MB" }

    /// Before ⏺: nil when there is room, else why not. `free` nil (unknown) doesn't stop it.
    public static func beforeStart(free: Int64?) -> String? {
        guard let free, free < startMinimum else { return nil }
        return "Not enough space to record: \(mb(free)) free on this iPad, and a recording needs at least 1 GB. Delete old recordings (Files → On My iPad → Contrast Ink → Recordings) or other files, then press ⏺ again."
    }

    /// Every minute while recording. `written`: the video's size so far. `alsoPhotos`: the video is copied to
    /// Photos at the end (that copy needs as much room again).
    public static func whileRecording(free: Int64?, written: Int64, alsoPhotos: Bool) -> Verdict {
        guard let free else { return .fine }
        if free < stopBelow {
            return .stop("Recording stopped: this iPad is almost full (\(mb(free)) free). What was recorded is saved.")
        }
        if free < warnBelow {
            return .warn("This iPad is running out of space (\(mb(free)) free). Recording stops by itself at \(mb(stopBelow)) free and keeps what was recorded.")
        }
        if alsoPhotos, free - written < warnBelow {
            return .warn("Space is getting short for the copy to Photos (\(mb(free)) free, the video is \(mb(written))). The video stays in Files either way.")
        }
        return .fine
    }

    /// The copy to Photos fits, leaving the stop margin free.
    public static func photosCopyFits(free: Int64?, fileSize: Int64) -> Bool {
        guard let free else { return true }
        return free - fileSize >= stopBelow
    }
}

/// The recorder's states and what ⏺, ⏹ and ✕ do in each. A stop asked for while recording is still starting (iOS
/// asking for permission) is remembered: once capture has started it is stopped at once, instead of recording on
/// with no one watching.
public struct RecorderPhase: Equatable, Sendable {
    public enum State: Equatable, Sendable { case idle, starting, recording, paused, stopping }
    public private(set) var state = State.idle
    public private(set) var stopWhenStarted = false
    public init() {}

    /// Recording or paused: a file is being written.
    public var active: Bool { state == .recording || state == .paused || state == .stopping }

    /// ⏺ while idle: true when starting now.
    public mutating func startTapped() -> Bool {
        guard state == .idle else { return false }
        state = .starting
        stopWhenStarted = false
        return true
    }

    /// Capture has started. False: a stop was asked for meanwhile, so stop the capture now (state is .stopping).
    public mutating func started() -> Bool {
        guard state == .starting else { return false }
        if stopWhenStarted { stopWhenStarted = false; state = .stopping; return false }
        state = .recording
        return true
    }

    /// Capture didn't start.
    public mutating func failedToStart() { if state == .starting { state = .idle; stopWhenStarted = false } }

    public enum Stop: Equatable, Sendable { case now, whenStarted, nothing }

    /// ⏹, ✕, the app leaving the screen. `.now`: stop and finish the file (state is .stopping).
    public mutating func stopRequested() -> Stop {
        switch state {
        case .recording, .paused: state = .stopping; return .now
        case .starting: stopWhenStarted = true; return .whenStarted
        case .idle, .stopping: return .nothing
        }
    }

    public mutating func pause() { if state == .recording { state = .paused } }
    public mutating func resume() { if state == .paused { state = .recording } }
    public mutating func finished() { state = .idle; stopWhenStarted = false }
}

/// How the end of a recording is told to the presenter: where it is, whether it may be incomplete, and what
/// happened with the copy to Photos.
public enum RecordingReport {
    public enum Photos: Equatable, Sendable {
        case off, saved, notAllowed, noRoom
        case failed(String)
    }

    public static let folder = "Files → On My iPad → Contrast Ink → Recordings"

    public static func text(file name: String, complete: Bool, photos: Photos) -> String {
        var s = complete
            ? "Saved to \(folder) (\(name))."
            : "The video may be incomplete (it was interrupted). What was recorded is kept in \(folder) (\(name))."
        switch photos {
        case .off: break
        case .saved: s += " Also saved to Photos."
        case .notAllowed: s += " Not copied to Photos: allow Photos access for Contrast Ink in Settings."
        case .noRoom: s += " Not copied to Photos: not enough space on this iPad."
        case .failed(let why): s += " Copying it to Photos failed (\(why)); the video in Files is fine."
        }
        return s
    }
}

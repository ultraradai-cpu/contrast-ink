import Foundation

/// What the tablet does with the PC's key from its CHALLENGE (docs/pad-protocol.md, "Version 2", step 4).
public enum PadKeyDecision: Equatable {
    /// The PC paired with before (the same key): send the PROOF at once.
    case proceed
    /// The first time with this PC, or "Connect anyway": show the PC check and wait for the presenter to confirm
    /// it matches the PC's screen before sending the PROOF.
    case askToConfirm
    /// Another key under a name paired with before: warn, and send nothing more.
    case warnDifferent
}

/// The tablet's side of the version 2 handshake, with no networking and no crypto in it, so its rules are tested on
/// any machine: HELLO sent → CHALLENGE → (the presenter confirms the PC check, the first time) → PROOF → WELCOME.
/// The client asks it what to do at each step; nothing is sent that it doesn't allow.
public struct PadHandshake: Equatable {
    public enum Step: Equatable {
        /// HELLO sent, waiting for the CHALLENGE.
        case hello
        /// The first time with this PC: its check is on screen, nothing more is sent until the presenter answers.
        case confirming(since: Date)
        /// PROOF sent, waiting for a sealed WELCOME.
        case proof
        /// WELCOME came: the session is open.
        case open
        /// Another key under a remembered name: stopped, nothing more sent.
        case warned
        /// The presenter said the check doesn't match, or took too long: closed, nothing more sent.
        case ended(String)
    }

    /// The PC waits 30 s for the PROOF; the tablet gives up a little before, so it says why itself.
    public static let confirmLimit: TimeInterval = 25
    public static let deniedText = "Don't connect: this may not be your PC."
    public static let tooLongText = "Took too long: tap Connect again."

    public private(set) var step = Step.hello

    public init() {}

    /// The rule of step 4. `remembered`: the key kept for the name the PC was chosen by (nil the first time).
    /// `session`: the key of the PC that let this tablet in during this visit (a reconnect must find the same).
    /// `accepted`: the key the presenter chose to trust with "Connect anyway" (it is checked by eye again).
    public static func decide(received: Data, remembered: Data?, session: Data? = nil, accepted: Data? = nil) -> PadKeyDecision {
        if let accepted, accepted == received { return .askToConfirm }
        if let session, session != received { return .warnDifferent }
        if let remembered, remembered != received { return .warnDifferent }
        if session == nil, remembered == nil { return .askToConfirm }
        return .proceed
    }

    /// The CHALLENGE arrived. `.proceed`: send the PROOF now; `.askToConfirm`: show the check and wait;
    /// `.warnDifferent`: warn and close. Nil when a CHALLENGE isn't expected now (a broken PC: close).
    public mutating func challenge(received: Data, remembered: Data?, session: Data? = nil, accepted: Data? = nil,
                                   now: Date = Date()) -> PadKeyDecision? {
        guard step == .hello else { return nil }
        let d = Self.decide(received: received, remembered: remembered, session: session, accepted: accepted)
        switch d {
        case .proceed: step = .proof
        case .askToConfirm: step = .confirming(since: now)
        case .warnDifferent: step = .warned
        }
        return d
    }

    /// "It matches": true when the PROOF may be sent now. Too late (or not asked): false, and it has ended.
    public mutating func confirm(now: Date = Date()) -> Bool {
        guard case .confirming(let since) = step else { return false }
        if now.timeIntervalSince(since) > Self.confirmLimit {
            step = .ended(Self.tooLongText)
            return false
        }
        step = .proof
        return true
    }

    /// "It doesn't": ended, nothing sent.
    public mutating func deny() {
        guard case .confirming = step else { return }
        step = .ended(Self.deniedText)
    }

    /// Called now and then: true the moment the presenter has taken too long to answer (it has ended).
    public mutating func tick(now: Date = Date()) -> Bool {
        guard case .confirming(let since) = step, now.timeIntervalSince(since) > Self.confirmLimit else { return false }
        step = .ended(Self.tooLongText)
        return true
    }

    /// A sealed WELCOME opened: true when it was awaited (only then is the PC's key remembered).
    public mutating func welcomed() -> Bool {
        guard step == .proof else { return false }
        step = .open
        return true
    }

    public var isConfirming: Bool { if case .confirming = step { return true }; return false }
    /// Sealed messages are expected (and may be sent, once open).
    public var expectsSealed: Bool { step == .proof || step == .open }
    /// The PC may send REJECT in the clear now (before the session is open; while the presenter compares the check,
    /// the PC may give up waiting).
    public var expectsReject: Bool { step == .hello || step == .proof || isConfirming }
}

import Foundation

/// Which way pad mode reaches the PC, Wi-Fi or the USB cable, and what to do when one comes or goes
/// (docs/pad-protocol.md, "USB (phase 2)"). No networking in it, so its rules are tested on any machine.
///
/// - Wi-Fi only until a cable session opens (sealed WELCOME): then the Wi-Fi session closes and Wi-Fi isn't tried.
/// - The cable drops: back to Wi-Fi by itself if the presenter chose a PC and typed its code earlier in this visit
///   (held in memory only), otherwise the connect screen.
/// - One cable connection at a time (being let in, or open): any other is closed.
public struct PadRoute: Equatable {
    public enum Link: Equatable {
        /// Nothing: the connect screen.
        case none
        /// Connecting, connected or reconnecting over Wi-Fi.
        case wifi
        /// A session open through the cable.
        case usb
    }

    /// Where to go when the cable's session ends.
    public enum AfterCable: Equatable {
        /// Back to the Wi-Fi PC with the code held from earlier.
        case wifi
        /// No code held: the connect screen.
        case connectScreen
    }

    public private(set) var link = Link.none
    /// A Wi-Fi PC and its code were chosen earlier in this visit (the code is kept in memory, never saved).
    public private(set) var wifiHeld = false
    /// A cable connection is being let in (its handshake) or is open: another one is closed.
    public private(set) var cableBusy = false

    public init() {}

    /// Wi-Fi may be tried (a connect, a quiet retry, "Reconnect"): never while the cable's session is open.
    public var mayStartWifi: Bool { link != .usb }

    /// The presenter pressed Connect with a PC and a code: they're held for after the cable.
    public mutating func wifiChosen() { wifiHeld = true }

    /// A Wi-Fi connection is starting. False (and nothing changes) while the cable's session is open.
    @discardableResult
    public mutating func wifiStarting() -> Bool {
        guard mayStartWifi else { return false }
        link = .wifi
        return true
    }

    /// A connection arrived through the cable: true to let it in, false to close it (one at a time).
    public mutating func cableArrived() -> Bool {
        guard !cableBusy else { return false }
        cableBusy = true
        return true
    }

    /// The cable connection being let in ended before its session opened (refused, warned, cut, too slow).
    /// Nothing changes while another cable session is open (the ending one was an extra, closed).
    public mutating func cableFailed() {
        if link != .usb { cableBusy = false }
    }

    /// The cable's session opened (a sealed WELCOME). Whatever Wi-Fi was doing closes now.
    public mutating func cableOpened() {
        cableBusy = true
        link = .usb
    }

    /// The cable's session ended (unplugged, the PC stopped answering): Wi-Fi when a code is held, else the
    /// connect screen.
    public mutating func cableDropped() -> AfterCable {
        cableBusy = false
        if wifiHeld {
            link = .wifi
            return .wifi
        }
        link = .none
        return .connectScreen
    }

    /// The presenter disconnected (or left pad mode): nothing held, nothing open.
    public mutating func forget() { self = PadRoute() }
}

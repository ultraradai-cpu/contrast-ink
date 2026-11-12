import Foundation

/// Pad mode: the iPad as a wireless drawing pad for a PC running Contrast Ink. This is the link itself, byte for
/// byte as written in docs/pad-protocol.md, with no networking code, so the same bytes are tested on any machine
/// (the Windows and Android sides use the same test vectors).
///
/// Every message is `[type: 1 byte][length: 4 bytes, big-endian][payload]`.
public enum PadProtocol {
    /// What the PC advertises with DNS-SD (Bonjour): the iPad looks for this, never for a UDP broadcast.
    public static let serviceType = "_contrastink._tcp"
    /// The PC's port when nothing else is using it (otherwise it advertises the next free one).
    public static let defaultPort: UInt16 = 47820
    /// Version 2: the code never crosses the network and everything after the hello is encrypted (PadCrypto).
    public static let version = 2
    /// A longer message means the stream is broken (or isn't Contrast Ink): the connection closes.
    public static let maxPayload = 16 * 1024 * 1024
    /// How often the iPad says it's still there, and how long a silent PC is given before it counts as lost.
    public static let pingInterval = 2.0
    public static let silenceLimit = 6.0

    /// The message types. Tablet → PC are below 0x80, PC → tablet from 0x80.
    public enum Kind: UInt8, Sendable {
        case hello = 0x01, ping = 0x02, frameAck = 0x03, proof = 0x04
        case strokeBegin = 0x10, strokePoints = 0x11, strokeEnd = 0x12, strokeCancel = 0x13
        case hover = 0x14, hoverEnd = 0x15
        case command = 0x20
        case welcome = 0x81, reject = 0x82, frame = 0x83, state = 0x84, pong = 0x85, challenge = 0x86
        /// Both ways, after the hello: a whole message inside, encrypted (PadSeal).
        case sealed = 0x7F
    }

    /// Which end of Apple Pencil touched: the PC erases with the eraser end whatever its tool is.
    public enum PenEnd: UInt8, Sendable { case tip = 0, eraser = 1 }

    // MARK: tablet → PC

    /// One whole message: the type, the payload's length, the payload.
    public static func message(_ kind: Kind, _ payload: [UInt8] = []) -> Data {
        var d = Data([kind.rawValue])
        d.append(contentsOf: u32(UInt32(payload.count)))
        d.append(contentsOf: payload)
        return d
    }

    /// The first message, always: who this is and its public key for this connection (65 bytes, 04|X|Y). No code:
    /// the code only goes into the keys. The keys are written in the spec's order. A long device name is cut, so
    /// the hello stays well under the PC's 1 KB.
    public static func hello(device: String, key: Data) -> Data {
        let name = String(device.prefix(64))
        let json = "{\"device\":\(jsonString(name)),\"version\":\(version),\"key\":\(jsonString(key.base64EncodedString()))}"
        return message(.hello, Array(json.utf8))
    }

    public static func ping() -> Data { message(.ping) }
    public static func frameAck() -> Data { message(.frameAck) }

    /// The pen touched down at (x, y), fractions of the PC's screen.
    public static func strokeBegin(x: Double, y: Double, end: PenEnd = .tip) -> Data {
        message(.strokeBegin, f32(x) + f32(y) + [end.rawValue])
    }

    /// The points since the last batch. More than a u16 can count (never at ~16 ms a batch) becomes several messages.
    public static func strokePoints(_ points: [(x: Double, y: Double)]) -> Data {
        var out = Data()
        var start = 0
        while start < points.count {
            let chunk = points[start..<min(points.count, start + Int(UInt16.max))]
            var p = u16(UInt16(chunk.count))
            for pt in chunk { p += f32(pt.x) + f32(pt.y) }
            out.append(message(.strokePoints, p))
            start += chunk.count
        }
        return out
    }

    public static func strokeEnd() -> Data { message(.strokeEnd) }
    /// A palm or a second finger: the PC drops the stroke instead of keeping it.
    public static func strokeCancel() -> Data { message(.strokeCancel) }
    /// Apple Pencil above the glass: the laser's dot on the PC.
    public static func hover(x: Double, y: Double) -> Data { message(.hover, f32(x) + f32(y)) }
    public static func hoverEnd() -> Data { message(.hoverEnd) }

    /// A toolbar button: `undo`, `tool:pen`, `color:3`... (the PC is the one place the tool and colour live).
    public static func command(_ text: String) -> Data { message(.command, Array(text.utf8)) }

    /// The words of every command the iPad's toolbar sends, so the app can't misspell one.
    public enum Command {
        public static let undo = "undo", clear = "clear", next = "next", previous = "previous"
        public static let fadeOn = "fade:on", fadeOff = "fade:off"
        public static func tool(_ t: Tool) -> String { "tool:\(t.rawValue)" }
        public static func color(_ i: Int) -> String { "color:\(min(max(i, 0), Settings.colors.count - 1))" }
        public static func width(_ i: Int) -> String { "width:\(min(max(i, 0), Settings.widths.count - 1))" }
        public static func opacity(_ o: Double) -> String {
            let v = o.isFinite ? min(max(o, Settings.minOpacity), 1) : 1
            return "opacity:\(String(format: "%.2f", v))"
        }
    }

    // MARK: where to connect

    /// A typed address: `192.168.1.20` or `192.168.1.20:47820` (and `[fe80::1]:47820` or a bare IPv6 address).
    /// Nil when there is nothing usable in it.
    public static func address(_ text: String) -> (host: String, port: UInt16)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if s.hasPrefix("[") {   // [IPv6]:port
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            if rest.isEmpty { return host.isEmpty ? nil : (host, defaultPort) }
            guard rest.hasPrefix(":"), let p = port(rest.dropFirst()), !host.isEmpty else { return nil }
            return (host, p)
        }
        let colons = s.filter { $0 == ":" }.count
        if colons == 0 { return (s, defaultPort) }
        if colons > 1 { return (s, defaultPort) }   // a bare IPv6 address has no port
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard !parts[0].isEmpty, let p = port(parts[1]) else { return nil }
        return (String(parts[0]), p)
    }

    /// The code the PC shows: exactly six digits.
    public static func isCode(_ text: String) -> Bool { text.count == 6 && text.allSatisfy { $0.isASCII && $0.isNumber } }

    /// A point on the iPad's picture of the PC's screen as fractions of that picture, kept on the screen (a pen
    /// that slides off the picture draws along its edge, as on the PC).
    public static func fraction(_ p: Pt, in picture: Rect) -> Pt {
        guard picture.width > 0, picture.height > 0 else { return Pt(0, 0) }
        func clamp(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
        return Pt(clamp((p.x - picture.x) / picture.width), clamp((p.y - picture.y) / picture.height))
    }

    // MARK: bytes

    static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func u32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    /// Coordinates are fractions: anything outside 0...1 (or not a number) is the nearest edge.
    static func f32(_ v: Double) -> [UInt8] {
        let c = v.isFinite ? min(max(v, 0), 1) : 0
        return u32(Float(c).bitPattern)
    }

    private static func port<S: StringProtocol>(_ s: S) -> UInt16? {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(s), n > 0, n <= 65535 else { return nil }
        return UInt16(n)
    }

    /// A JSON string with the few characters JSON needs escaped (a device name could have a quote in it).
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}

// MARK: PC → tablet

/// The PC took the code: its name and the size of the screen it draws on.
public struct PadWelcome: Equatable, Sendable {
    public var name = "PC"
    public var screenW = 1920
    public var screenH = 1080
    public var version = 1
    public init(name: String = "PC", screenW: Int = 1920, screenH: Int = 1080, version: Int = 1) {
        self.name = name; self.screenW = screenW; self.screenH = screenH; self.version = version
    }

    /// Anything missing or unreadable keeps its default: a WELCOME still means the PC took the code.
    public static func parse(_ payload: Data) -> PadWelcome {
        var w = PadWelcome()
        guard let d = FlatJSON.read(payload) else { return w }
        if let v = d.strings["name"], !v.isEmpty { w.name = v }
        if let v = d.int("screenW"), v > 0 { w.screenW = v }
        if let v = d.int("screenH"), v > 0 { w.screenH = v }
        if let v = d.int("version") { w.version = v }
        return w
    }
}

/// The PC's tool, colour, width and opacity: the iPad's toolbar shows these, never its own guess.
public struct PadState: Equatable, Sendable {
    public var tool: Tool = .pen
    public var color = 0
    public var width = 1
    public var opacity = 1.0
    public var fading = false
    public var canUndo = false
    public init(tool: Tool = .pen, color: Int = 0, width: Int = 1, opacity: Double = 1, fading: Bool = false, canUndo: Bool = false) {
        self.tool = tool; self.color = color; self.width = width; self.opacity = opacity; self.fading = fading; self.canUndo = canUndo
    }

    /// Reads a STATE on top of the last one: a key that is missing or unknown leaves that part as it was.
    public static func parse(_ payload: Data, over old: PadState = PadState()) -> PadState {
        var s = old
        guard let d = FlatJSON.read(payload) else { return s }
        if let v = d.strings["tool"], let t = Tool(rawValue: v) { s.tool = t }
        if let v = d.int("color") { s.color = min(max(v, 0), Settings.colors.count - 1) }
        if let v = d.int("width") { s.width = min(max(v, 0), Settings.widths.count - 1) }
        if let v = d.numbers["opacity"], v.isFinite { s.opacity = min(max(v, Settings.minOpacity), 1) }
        if let v = d.bools["fading"] { s.fading = v }
        if let v = d.bools["canUndo"] { s.canUndo = v }
        return s
    }
}

public enum PadMessage: Equatable, Sendable {
    case welcome(PadWelcome)
    /// Why the PC said no ("Wrong code"); it closes the connection after.
    case reject(String)
    /// A JPEG of the PC's screen. The iPad sends FRAME_ACK once it's showing, and the next one comes.
    case frame(Data)
    /// The raw STATE JSON: read it with PadState.parse over the last state.
    case state(Data)
    case pong
    /// Version 2's answer to the hello, in the clear: the PC's public key, the salt, its name (PadChallenge.parse).
    case challenge(Data)
    /// A SEALED payload: nonce, ciphertext, tag. Opened with PadLink.open.
    case sealed(Data)

    /// One message from the PC by its type; nil for a type the iPad doesn't know (or a tablet → PC one): skipped.
    public static func read(type: UInt8, payload: Data) -> PadMessage? {
        switch PadProtocol.Kind(rawValue: type) {
        case .welcome?: return .welcome(PadWelcome.parse(payload))
        case .reject?: return .reject(String(decoding: payload, as: UTF8.self))
        case .frame?: return .frame(payload)
        case .state?: return .state(payload)
        case .pong?: return .pong
        case .challenge?: return .challenge(payload)
        case .sealed?: return .sealed(payload)
        default: return nil
        }
    }
}

/// The PC's CHALLENGE: its own long-lived public key (the iPad remembers it by the PC's name), the salt for this
/// connection's keys, and its name.
public struct PadChallenge: Equatable, Sendable {
    public var key: Data
    public var salt: Data
    public var name: String
    public init(key: Data, salt: Data, name: String) { self.key = key; self.salt = salt; self.name = name }

    /// Nil when the key isn't 65 bytes starting 04, or the salt isn't 16 bytes: not a PC that speaks version 2.
    public static func parse(_ payload: Data) -> PadChallenge? {
        guard let d = FlatJSON.read(payload),
              let k = d.strings["key"].flatMap({ Data(base64Encoded: $0) }), k.count == 65, k.first == 4,
              let s = d.strings["salt"].flatMap({ Data(base64Encoded: $0) }), s.count == 16
        else { return nil }
        let name = d.strings["name"].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return PadChallenge(key: k, salt: s, name: name.isEmpty ? "PC" : String(name.prefix(64)))
    }
}

public enum PadError: Error, Equatable {
    /// A length over 16 MB: not Contrast Ink, or the stream lost its place. Close the connection.
    case tooLong(UInt32)
    /// A sealed message that was altered, replayed, sealed with other keys (a wrong code), or isn't one whole
    /// message inside: close the connection.
    case refused
}

/// Turns the bytes from the PC, however TCP splits them, into whole messages. Unknown types are skipped (a newer
/// PC may send more), using their length.
public struct PadDecoder: Sendable {
    private var buffer = Data()
    private var failed: PadError?
    public init() {}

    /// Bytes not yet part of a whole message.
    public var pending: Int { buffer.count }

    /// Add what arrived; get every message it completes, in order. After an error every call throws it again.
    public mutating func feed(_ bytes: Data) throws -> [PadMessage] {
        if let failed { throw failed }
        buffer.append(bytes)
        var out: [PadMessage] = []
        var at = buffer.startIndex
        while buffer.endIndex - at >= 5 {
            let type = buffer[at]
            let len = UInt32(buffer[at + 1]) << 24 | UInt32(buffer[at + 2]) << 16 | UInt32(buffer[at + 3]) << 8 | UInt32(buffer[at + 4])
            guard len <= UInt32(PadProtocol.maxPayload) else {
                failed = .tooLong(len)
                buffer = Data()
                throw PadError.tooLong(len)
            }
            let start = at + 5, end = start + Int(len)
            guard end <= buffer.endIndex else { break }
            let payload = Data(buffer[start..<end])
            at = end
            if let m = PadMessage.read(type: type, payload: payload) { out.append(m) }
        }
        buffer = Data(buffer[at...])
        return out
    }
}

// MARK: lenient JSON

/// A flat JSON object read key by key, each value as a string, a number or a true/false. JSONDecoder rather than
/// JSONSerialization: on Apple's systems JSONSerialization's numbers also read as true/false (and the other way round).
private struct FlatJSON: Decodable {
    var strings: [String: String] = [:]
    var numbers: [String: Double] = [:]
    var bools: [String: Bool] = [:]

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        for k in c.allKeys {
            if let b = try? c.decode(Bool.self, forKey: k) { bools[k.stringValue] = b }
            else if let d = try? c.decode(Double.self, forKey: k) { numbers[k.stringValue] = d }
            else if let s = try? c.decode(String.self, forKey: k) { strings[k.stringValue] = s }
        }
    }

    static func read(_ data: Data) -> FlatJSON? { try? JSONDecoder().decode(FlatJSON.self, from: data) }

    /// A whole number: 1920 and 1920.0 both count (another implementation may write either).
    func int(_ key: String) -> Int? {
        guard let d = numbers[key], d.isFinite, d.rounded() == d, abs(d) < 1e9 else { return nil }
        return Int(d)
    }
}

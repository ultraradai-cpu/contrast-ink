import ContrastInkCore
import Foundation

/// The PC's side of the tablet link (docs/pad-protocol.md), with no sockets and no crypto: the messages the PC
/// writes, what it reads from a tablet, and its limits. The same rules as the Windows app's Pad (PadProtocol.cs).
public enum PadPC {
    /// The USB door: the Mac's loopback port Android's `adb reverse` reaches, and the iPad's own loopback port.
    public static let usbPort: UInt16 = 47830
    /// The longest HELLO accepted (a stranger's first message: small, so it can't be used to fill memory).
    public static let helloMax = 1024
    /// Strangers not yet past the code, at once.
    public static let maxPending = 4
    /// The hello within 3 s of connecting; the proof within 30 s (the presenter may be comparing the PC check).
    public static let helloWithin: TimeInterval = 3
    public static let proofWithin: TimeInterval = 30
    /// A tablet silent this long is gone.
    public static let silence: TimeInterval = 10
    /// A tablet that can't take messages this long is dropped.
    public static let writeStall: TimeInterval = 3
    /// Messages waiting to be written to a tablet: more means it isn't keeping up, and it is dropped.
    public static let maxOutbox = 64
    /// Messages from the tablet waiting for the app: more is a flood, and the tablet is dropped.
    public static let maxQueued = 4000
    /// A stroke longer than this is a flood, not a hand.
    public static let maxStrokePoints = 20000
    /// The pictures of the screen: at most this wide, about this often, this JPEG quality.
    public static let frameMaxWidth = 1600
    public static let frameInterval: TimeInterval = 0.1
    public static let jpegQuality = 0.7

    /// The REJECT texts (the spec lists them; the tablets show them as they are).
    public static let updateTablet = "Please update Contrast Ink on the tablet."
    public static let tooManyWrong = "Too many wrong codes: wait 30 seconds, then try again."
    public static let wrongCode = "Wrong code: type the code Contrast Ink shows on the PC (⚙ Settings)."

    // MARK: writing

    public static func message(_ type: UInt8, _ payload: Data = Data()) -> Data {
        var d = Data([type])
        let n = UInt32(payload.count)
        d.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        d.append(payload)
        return d
    }

    public static func message(_ kind: PadProtocol.Kind, _ text: String) -> Data { message(kind.rawValue, Data(text.utf8)) }

    public static func reject(_ why: String) -> Data { message(.reject, why) }
    public static func pong() -> Data { message(PadProtocol.Kind.pong.rawValue) }
    public static func frame(_ jpeg: Data) -> Data { message(PadProtocol.Kind.frame.rawValue, jpeg) }

    /// WELCOME: this Mac's name and the size of the screen it draws on, in pixels.
    public static func welcome(name: String, screenW: Int, screenH: Int) -> Data {
        message(.welcome, "{\"name\":\(json(name)),\"screenW\":\(screenW),\"screenH\":\(screenH),\"version\":\(PadProtocol.version)}")
    }

    /// CHALLENGE: this Mac's own public key (65 bytes), the salt for this connection's keys, its name.
    public static func challenge(key: Data, salt: Data, name: String) -> Data {
        message(.challenge, "{\"key\":\(json(key.base64EncodedString())),\"salt\":\(json(salt.base64EncodedString())),\"name\":\(json(name))}")
    }

    /// STATE: the tool, colour, width, opacity and fading the tablet's toolbar shows (the PC is where they live).
    public static func state(tool: Tool, color: Int, width: Int, opacity: Double, fading: Bool, canUndo: Bool) -> Data {
        let o = (min(max(opacity.isFinite ? opacity : 1, Settings.minOpacity), 1) * 100).rounded() / 100
        return message(.state, "{\"tool\":\"\(tool.rawValue)\",\"color\":\(color),\"width\":\(width),\"opacity\":\(o),\"fading\":\(fading),\"canUndo\":\(canUndo)}")
    }

    // MARK: reading

    /// A version-2 HELLO: the tablet's name and its fresh public key (65 bytes). Nil for anything else, including a
    /// version-1 HELLO (it carries the code in the clear: such a tablet must be updated).
    public static func hello(_ payload: Data) -> (device: String, key: Data)? {
        guard payload.count <= helloMax, let d = FlatJSON.read(payload),
              let v = d.int("version"), v >= 2,
              let k = d.strings["key"], let key = Data(base64Encoded: k), key.count == 65 else { return nil }
        let raw = d.strings["device"] ?? ""
        let device = String(String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(40))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (device.isEmpty ? "a tablet" : device, key)
    }

    /// STROKE_BEGIN: where (fractions of the screen) and whether the pen's eraser end touched.
    public static func begin(_ p: Data) -> (x: Double, y: Double, eraserEnd: Bool)? {
        let b = [UInt8](p)
        return b.count < 9 ? nil : (f32(b, 0), f32(b, 4), b[8] == 1)
    }

    /// STROKE_POINTS: the points (fractions of the screen), each kept on the screen.
    public static func points(_ p: Data) -> [Pt] {
        let b = [UInt8](p)
        guard b.count >= 2 else { return [] }
        let n = Int(b[0]) << 8 | Int(b[1])
        var out: [Pt] = []
        var i = 0
        while i < n, 2 + i * 8 + 8 <= b.count {
            out.append(Pt(f32(b, 2 + i * 8), f32(b, 6 + i * 8)))
            i += 1
        }
        return out
    }

    /// HOVER: where the pen is above the glass.
    public static func hover(_ p: Data) -> Pt? {
        let b = [UInt8](p)
        return b.count < 8 ? nil : Pt(f32(b, 0), f32(b, 4))
    }

    /// A COMMAND, as what the app should do. Nil for one it doesn't know (a newer tablet).
    public static func command(_ p: Data) -> PadCommand? {
        let s = String(decoding: p, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch s {
        case "undo": return .undo
        case "clear": return .clear
        case "next": return .next
        case "previous": return .previous
        case "fade:on": return .fade(true)
        case "fade:off": return .fade(false)
        default: break
        }
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let key = s[..<colon], value = String(s[s.index(after: colon)...])
        switch key {
        case "tool": return Tool(rawValue: value.lowercased()).map { .tool($0) }
        case "color": return Int(value).flatMap { (0..<Settings.colors.count).contains($0) ? .color($0) : nil }
        case "width": return Int(value).flatMap { (0..<Settings.widths.count).contains($0) ? .width($0) : nil }
        case "opacity":
            guard let o = Double(value), o.isFinite else { return nil }
            return .opacity(min(max(o, Settings.minOpacity), 1))
        default: return nil
        }
    }

    /// A new 6-digit code for this run of the app (what a tablet must type to draw on this Mac).
    public static func newCode() -> String {
        var g = SystemRandomNumberGenerator()
        let n = Int.random(in: 0..<1_000_000, using: &g)
        return String(format: "%06d", n)
    }

    /// The Mac's addresses a tablet can be given by hand, from interface names and addresses (IPv4, not loopback,
    /// not self-assigned 169.254).
    public static func usableAddresses(_ all: [(interface: String, address: String)]) -> [String] {
        var seen = Set<String>()
        return all.compactMap { a in
            let s = a.address
            guard s.contains("."), !s.hasPrefix("127."), !s.hasPrefix("169.254."), !a.interface.hasPrefix("lo"),
                  seen.insert(s).inserted else { return nil }
            return s
        }
    }

    // MARK: bytes

    static func f32(_ b: [UInt8], _ at: Int) -> Double {
        let bits = UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
        let v = Double(Float(bitPattern: bits))
        return v.isFinite ? min(max(v, 0), 1) : 0
    }

    /// A JSON string with the characters JSON needs escaped.
    public static func json(_ s: String) -> String {
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

/// What a tablet's toolbar asks for.
public enum PadCommand: Equatable, Sendable {
    case undo, clear, next, previous
    case fade(Bool)
    case tool(Tool)
    case color(Int)
    case width(Int)
    case opacity(Double)
}

/// Splits a byte stream into messages, however it arrives (a message across reads, several in one).
public struct PadFrames {
    private var buffer = Data()
    /// The longest message accepted now (lowered to PadPC.helloMax before a tablet is let in).
    public var maxLength: Int
    public init(maxLength: Int = PadProtocol.maxPayload) { self.maxLength = maxLength }

    public enum Failure: Error, Equatable { case tooLong(UInt32) }

    /// Adds what arrived; returns every message now complete. Throws when a length is past the limit.
    public mutating func feed(_ data: Data) throws -> [(type: UInt8, payload: Data)] {
        buffer.append(data)
        var out: [(UInt8, Data)] = []
        var at = buffer.startIndex
        while buffer.endIndex - at >= 5 {
            let len = UInt32(buffer[at + 1]) << 24 | UInt32(buffer[at + 2]) << 16 | UInt32(buffer[at + 3]) << 8 | UInt32(buffer[at + 4])
            guard len <= UInt32(maxLength) else { buffer = Data(); throw Failure.tooLong(len) }
            let end = at + 5 + Int(len)
            guard end <= buffer.endIndex else { break }
            out.append((buffer[at], Data(buffer[(at + 5)..<end])))
            at = end
        }
        buffer = Data(buffer[at...])
        return out
    }

    /// Every whole message in one block of bytes (what a SEALED message carries). Nil when it isn't only whole messages.
    public static func all(_ data: Data) -> [(type: UInt8, payload: Data)]? {
        var f = PadFrames()
        guard let m = try? f.feed(data), f.buffer.isEmpty else { return nil }
        return m
    }
}

/// Wrong codes: a 6-digit code must not be guessable by a script on the same Wi-Fi. Five wrong in a row lock
/// everyone out for 30 s; twenty wrong in all make a new code (the presenter sees it change).
public struct PadGuard: Sendable {
    public static let inARow = 5, beforeNewCode = 20
    public static let lockout: TimeInterval = 30
    private var wrongInARow = 0, wrongForThisCode = 0
    private var lockedUntil = Date.distantPast
    public init() {}

    /// Whether codes may be tried at all right now.
    public func locked(_ now: Date) -> Bool { now < lockedUntil }

    /// A wrong code was given. True: time for a new code.
    public mutating func wrong(_ now: Date) -> Bool {
        wrongForThisCode += 1
        wrongInARow += 1
        if wrongInARow >= Self.inARow { wrongInARow = 0; lockedUntil = now.addingTimeInterval(Self.lockout) }
        guard wrongForThisCode >= Self.beforeNewCode else { return false }
        wrongForThisCode = 0
        return true
    }

    /// The right code: the count of guesses in a row starts again.
    public mutating func right() { wrongInARow = 0 }
}

/// A flat JSON object read key by key, each value a string, a number or a true/false (a number is never read as
/// true/false, nor the other way round).
struct FlatJSON: Decodable {
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

    func int(_ key: String) -> Int? {
        guard let d = numbers[key], d.isFinite, d.rounded() == d, abs(d) < 1e9 else { return nil }
        return Int(d)
    }
}

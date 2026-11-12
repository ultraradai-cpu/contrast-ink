#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// The parts of talking to OBS (obs-websocket 5, built into OBS 28 and later) that can be tested without OBS: the
/// password answer, where OBS keeps its remote-control settings on the Mac, and what the replies mean. The same rules
/// as the Windows app's Obs.cs.
public enum Obs {
    /// OBS's remote-control settings. `password` is nil when OBS asks for none.
    public struct Connection: Equatable, Sendable {
        public var enabled: Bool
        public var port: Int
        public var password: String?
        public init(enabled: Bool, port: Int, password: String?) { self.enabled = enabled; self.port = port; self.password = password }
    }

    #if canImport(CryptoKit)
    /// protocol.md, "Creating an authentication string": base64(sha256(password + salt)) is the secret; the answer
    /// is base64(sha256(secret + challenge)).
    public static func auth(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }
    #endif

    /// OBS's settings folder on the Mac: ~/Library/Application Support/obs-studio.
    public static func folder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/obs-studio", isDirectory: true)
    }

    /// Reads OBS's own remote-control settings, so nothing has to be typed into Contrast Ink. OBS 30 and later:
    /// plugin_config/obs-websocket/config.json; OBS 28 and 29: section [OBSWebSocket] of global.ini (or user.ini).
    /// Defaults are OBS's own: off, port 4455, password required. Nil when OBS has never saved them.
    public static func readConfig(folder: URL) -> Connection? {
        let json = folder.appendingPathComponent("plugin_config/obs-websocket/config.json")
        if let data = try? Data(contentsOf: json) {
            guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            let enabled = (r["server_enabled"] as? Bool) == true
            let port = (r["server_port"] as? Int) ?? 4455
            let auth = (r["auth_required"] as? Bool) != false
            let pass = r["server_password"] as? String
            return Connection(enabled: enabled, port: port, password: auth ? pass ?? "" : nil)
        }
        for ini in ["user.ini", "global.ini"] {
            guard let text = try? String(contentsOf: folder.appendingPathComponent(ini), encoding: .utf8) else { continue }
            let v = iniSection(text, "OBSWebSocket")
            if v.isEmpty { continue }
            let enabled = v["ServerEnabled"]?.lowercased() == "true"
            let port = v["ServerPort"].flatMap { Int($0) } ?? 4455
            let auth = v["AuthRequired"]?.lowercased() != "false"
            return Connection(enabled: enabled, port: port, password: auth ? v["ServerPassword"] ?? "" : nil)
        }
        return nil
    }

    static func iniSection(_ text: String, _ section: String) -> [String: String] {
        var d: [String: String] = [:]
        var inside = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inside = line == "[\(section)]"; continue }
            if inside, let eq = line.firstIndex(of: "="), eq != line.startIndex {
                d[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        return d
    }

    /// The kinds of OBS source that capture a whole screen (macOS, Windows, Linux): without one in the scene, the
    /// marks wouldn't be in the video.
    public static let screenKinds: Set<String> = ["screen_capture", "display_capture", "monitor_capture", "xshm_input",
                                                  "pipewire-desktop-capture-source"]

    /// Below this much free space on the recording disk (MB, as OBS reports it), the toolbar warns.
    public static let lowDiskMB = 2048.0

    /// OBS's EventSubscription::Outputs: the recording's start, pause and stop.
    public static let outputsEvents = 1 << 6

    /// The Identify message (op 1) for OBS's Hello (op 0): with the password's answer when OBS asks for one.
    public static func identify(hello: [String: Any], password: String?) -> [String: Any] {
        var d: [String: Any] = ["rpcVersion": 1, "eventSubscriptions": outputsEvents]
        #if canImport(CryptoKit)
        if let a = (hello["d"] as? [String: Any])?["authentication"] as? [String: Any],
           let salt = a["salt"] as? String, let challenge = a["challenge"] as? String {
            d["authentication"] = auth(password: password ?? "", salt: salt, challenge: challenge)
        }
        #endif
        return ["op": 1, "d": d]
    }

    /// The time on the toolbar's timer: "4:05", or "1:04:05" past an hour.
    public static func timer(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0))
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return s >= 3600 ? "\(s / 3600):\(two(s / 60 % 60)):\(two(s % 60))" : "\(s / 60):\(two(s % 60))"
    }
}

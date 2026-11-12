import Foundation

/// iPads over the cable, through Apple's USB service usbmuxd (on the Mac: the unix socket /var/run/usbmuxd). The
/// same plist messages as the Windows app's PadUsb.cs: ListDevices, then Connect with DeviceID and the port with its
/// two bytes swapped. Every packet: a 16-byte header (length, version 1, type 8 = plist, tag), little-endian.
public enum UsbMux {
    public static let socketPath = "/var/run/usbmuxd"
    public static let plistType: UInt32 = 8

    public static func packet(_ dict: [String: Any], tag: UInt32 = 1) -> Data {
        let body = (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)) ?? Data()
        var d = Data()
        for v in [UInt32(16 + body.count), 1, plistType, tag] { d.append(contentsOf: le(v)) }
        d.append(body)
        return d
    }

    public static func listDevices() -> Data {
        packet(["MessageType": "ListDevices", "ClientVersionString": "Contrast Ink", "ProgName": "Contrast Ink"])
    }

    /// Connect to `port` on the device: usbmuxd wants the port's two bytes swapped.
    public static func connect(device: Int, port: UInt16) -> Data {
        packet(["MessageType": "Connect", "ClientVersionString": "Contrast Ink", "ProgName": "Contrast Ink",
                "DeviceID": device, "PortNumber": Int(swapped(port))])
    }

    public static func swapped(_ port: UInt16) -> UInt16 { (port & 0xFF) << 8 | (port >> 8) }

    /// The length of the body that follows a 16-byte header; nil when it isn't one usbmuxd would send (or is huge).
    public static func bodyLength(header: Data) -> Int? {
        let h = [UInt8](header)
        guard h.count >= 16 else { return nil }
        let total = Int(UInt32(h[0]) | UInt32(h[1]) << 8 | UInt32(h[2]) << 16 | UInt32(h[3]) << 24)
        let n = total - 16
        return n >= 0 && n <= 1 << 20 ? n : nil
    }

    /// The iPhones and iPads plugged in by cable (not ones paired over the network), from a ListDevices answer.
    public static func devices(_ body: Data) -> [Int] {
        guard let p = (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any],
              let list = p["DeviceList"] as? [[String: Any]] else { return [] }
        var out: [Int] = []
        for item in list {
            let props = item["Properties"] as? [String: Any] ?? item
            guard props["ConnectionType"] as? String == "USB" else { continue }
            if let id = (props["DeviceID"] as? Int) ?? (item["DeviceID"] as? Int), id >= 0, !out.contains(id) { out.append(id) }
        }
        return out
    }

    /// The answer to Connect: 0 means the socket is now a pipe to the device's port.
    public static func result(_ body: Data) -> Int? {
        guard let p = (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any] else { return nil }
        return p["Number"] as? Int
    }

    static func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
}

/// Android tablets over the cable, through USB debugging: `adb reverse tcp:47830 tcp:47830` for each tablet newly
/// plugged in, so the tablet's 127.0.0.1:47830 reaches the Mac's USB door. Only when adb is found.
public enum Adb {
    /// Where adb may be: on the PATH, in Android Studio's SDK, or from Homebrew.
    public static func candidates(path: String?, home: String) -> [String] {
        var dirs = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        dirs += [home + "/Library/Android/sdk/platform-tools", "/opt/homebrew/bin", "/usr/local/bin"]
        var seen = Set<String>()
        return dirs.map { ($0.hasSuffix("/") ? String($0.dropLast()) : $0) + "/adb" }.filter { seen.insert($0).inserted }
    }

    /// The serials of the devices `adb devices` lists as ready ("device"; not "unauthorized" or "offline").
    public static func devices(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let p = line.trimmingCharacters(in: .whitespaces).split(separator: "\t")
            return p.count == 2 && p[1] == "device" ? String(p[0]) : nil
        }
    }

    public static func reverseArguments(serial: String, port: UInt16 = PadPC.usbPort) -> [String] {
        ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"]
    }
}

/// Which Android tablets `adb reverse` has been set up for, and so whether the USB door (127.0.0.1:47830) should be
/// open: only while adb is found and at least one tablet is reversed. Any program on this Mac can reach a loopback
/// port, so the door is not left open when no tablet needs it.
public struct AdbReversals: Equatable, Sendable {
    public private(set) var reversed = Set<String>()
    public init() {}

    /// The devices `adb devices` lists now: those unplugged are forgotten (set up again when they come back), and the
    /// ones returned still need `adb reverse`.
    public mutating func seen(_ devices: [String]) -> [String] {
        reversed.formIntersection(devices)
        var out: [String] = []
        for d in devices where !reversed.contains(d) && !out.contains(d) { out.append(d) }
        return out
    }

    /// `adb reverse` worked for this device.
    public mutating func didReverse(_ serial: String) { reversed.insert(serial) }

    /// adb isn't found (any more): nothing is reversed.
    public mutating func adbMissing() { reversed = [] }

    /// Whether the USB door should be open now.
    public var doorOpen: Bool { !reversed.isEmpty }
}

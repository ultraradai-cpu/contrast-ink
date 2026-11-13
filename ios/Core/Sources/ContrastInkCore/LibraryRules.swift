import Foundation

/// Names of files in the library: a second "Lecture.pdf" becomes "Lecture (2).pdf" rather than replacing the first.
public enum FileNames {
    /// `name` as it is when nothing has it, else "base (2).ext", "base (3).ext"...
    public static func unique(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        let base = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        var n = 2
        while exists("\(base) (\(n))\(ext)") { n += 1 }
        return "\(base) (\(n))\(ext)"
    }

    /// A title made safe as a file name.
    public static func safe(_ title: String) -> String {
        let s = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Untitled" : s
    }

    /// The copy of the n-th picture in an image deck's folder: numbered, so the folder keeps the order picked.
    public static func numbered(_ index: Int, _ name: String) -> String {
        let n = String(index + 1)
        return String(repeating: "0", count: max(0, 3 - n.count)) + n + " " + safe(name)
    }
}

/// Slide pictures in memory. A decoded picture costs 4 bytes a pixel; the cache keeps at most `costLimit` of them,
/// and pictures are decoded at the size they are shown (never more than `maxSide`), not at the camera's.
public enum SlideImages {
    public static let maxSide = 2560

    public static func cost(width: Int, height: Int) -> Int { max(0, width) * max(0, height) * 4 }

    /// The cache's limit for a device with `memory` bytes: a sixteenth of it, between 64 MB and 256 MB.
    public static func costLimit(memory: UInt64) -> Int {
        let share = Int(min(memory / 16, UInt64(Int.max)))
        return min(max(share, 64 << 20), 256 << 20)
    }

    /// The long side to decode a picture of `natural` size at, to show it `pixelWidth` pixels wide.
    public static func decodeSide(natural: Size, pixelWidth: Double) -> Int {
        guard natural.width > 0, natural.height > 0, pixelWidth > 0 else { return maxSide }
        let height = pixelWidth * natural.height / natural.width
        let long = max(pixelWidth, height).rounded(.up)
        let naturalLong = max(natural.width, natural.height)
        return Int(min(long, naturalLong, Double(maxSide)))
    }

    /// What to say after picking pictures, when some couldn't be read. Nil when all were read.
    public static func unreadable(_ failed: Int, of total: Int) -> String? {
        guard failed > 0 else { return nil }
        if failed >= total { return total == 1 ? "That file couldn't be read as a picture." : "None of those \(total) files could be read as pictures." }
        return "\(failed) of \(total) pictures couldn't be read and were left out."
    }
}

/// A sideloaded app stops opening when its provisioning profile expires (7 days with a free Apple ID). The profile
/// (embedded.mobileprovision) is a signed property list; its ExpirationDate is read here.
public enum Provision {
    /// Warn this long before.
    public static let warnAhead: TimeInterval = 48 * 3600

    /// The ExpirationDate in an embedded.mobileprovision (the XML property list inside the signature). Nil if none.
    public static func expiration(_ data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let xml = data[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(xml), options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    /// What the home screen says: nil until 48 hours before the expiry.
    public static func warning(expires: Date?, now: Date = Date()) -> String? {
        guard let expires else { return nil }
        let left = expires.timeIntervalSince(now)
        guard left < warnAhead else { return nil }
        if left <= 0 { return "This copy of Contrast Ink has expired: install it again with Sideloadly or AltStore (your decks and recordings stay)." }
        let hours = Int((left / 3600).rounded(.up))
        let when = hours <= 1 ? "within the hour" : "in \(hours) hours"
        return "This copy of Contrast Ink stops opening \(when): install it again with Sideloadly or AltStore before your next lecture (your decks and recordings stay)."
    }
}

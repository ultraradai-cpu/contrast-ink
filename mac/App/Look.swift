import AppKit
import ContrastInkPC

/// Contrast's colours, as on the Windows toolbar: dark ink bar, light grey text, logo blue for what is switched on.
enum Look {
    static let bar = NSColor(hex: "#141A22")
    static let ink = NSColor(hex: "#E3E8F0")
    static let blue = NSColor(hex: "#2563EB")
    static let grey = NSColor(hex: "#8A95A6")
    static let hover = NSColor(hex: "#E3E8F0", alpha: 0.2)
    static let separator = NSColor(hex: "#8A95A6", alpha: 0.25)
    static let recRed = NSColor(hex: "#FF3B30")
    static let amber = NSColor(hex: "#FFB020")
    static let warning = NSColor(hex: "#FA8072")
    static let laser = NSColor(hex: "#FF2D2D")
}

extension NSColor {
    convenience init(hex: String, alpha: CGFloat = 1) {
        let c = Ink.rgb(hex) ?? (1, 1, 1)
        self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }
}

/// Where the app writes what went wrong: ~/Library/Logs/Contrast Ink.log (send it along with what you were doing).
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Contrast Ink.log")
    private static let lock = NSLock()

    static func write(_ text: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        lock.lock(); defer { lock.unlock() }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") { FileHandle.standardError.write(Data(line.utf8)) }
    }
}

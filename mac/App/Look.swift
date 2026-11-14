import AppKit
import ContrastInkPC

/// Contrast's colours, as on the Windows toolbar: dark ink bar, light grey text, logo blue for what is switched on.
/// The values are ContrastInkPC's MacPalette, whose tests hold them to WCAG AA on the bar and under the pointer.
enum Look {
    static let bar = NSColor(hex: MacPalette.bar)
    static let ink = NSColor(hex: MacPalette.ink)
    static let blue = NSColor(hex: MacPalette.blue)
    static let blueText = NSColor(hex: MacPalette.blueText)
    static let grey = NSColor(hex: MacPalette.grey)
    static let hover = NSColor(hex: MacPalette.ink, alpha: CGFloat(MacPalette.hoverAlpha))
    static let separator = NSColor(hex: MacPalette.grey, alpha: 0.25)
    static let recRed = NSColor(hex: MacPalette.recRed)
    static let amber = NSColor(hex: MacPalette.amber)
    static let warning = NSColor(hex: MacPalette.warning)
    static let laser = NSColor(hex: MacPalette.laserGlyph)
}

extension NSColor {
    convenience init(hex: String, alpha: CGFloat = 1) {
        let c = Ink.rgb(hex) ?? (1, 1, 1)
        self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }
}

/// Where the app writes what went wrong: ~/Library/Logs/Contrast Ink.log (send it along with what you were doing).
/// Kept under 1 MB: past that it becomes "Contrast Ink.old.log" (one old file).
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Contrast Ink.log")
    private static let lock = NSLock()

    static func write(_ text: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        lock.lock(); defer { lock.unlock() }
        LogFile.append(line, to: url)
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") { FileHandle.standardError.write(Data(line.utf8)) }
    }
}

import ContrastInkCore
import Foundation

/// What the Mac app remembers between lectures. The tools, colours and widths are Core's (the same as Windows).
public struct MacSettings: Codable, Equatable, Sendable {
    public var tool: Tool = .pen
    public var color = 0
    public var width = 1
    public var fadingInk = false
    /// How solid new pen, arrow and circle marks are: 1 = solid, down to 0.1 (the highlighter keeps its own look).
    public var opacity: Double = 1
    /// Which screen the drawing layer covers (index into the Mac's screens).
    public var screen = 0
    /// Where the toolbar was left (its top-left corner, in screen coordinates); nil until it is first dragged.
    public var toolbarX: Double?
    public var toolbarY: Double?
    public var toolbarCollapsed = false
    /// Resting the pointer on a toolbar button shows its name under the buttons.
    public var showButtonNames = true
    /// Holding Control (on its own) switches drawing on while it is held.
    public var holdControlToDraw = true
    /// While drawing, Z alone undoes (⌘Z always does).
    public var undoWithZ = true
    /// While drawing, a right-click undoes the last mark.
    public var undoWithRightClick = true
    /// A pen tablet's eraser end removes marks, whatever tool is chosen.
    public var penEraserEnd = true
    /// A tablet (Android or iPad) may connect and be used as a pad that draws here.
    public var tabletPad = false

    public init() {}

    private enum K: String, CodingKey {
        case tool, color, width, fadingInk, opacity, screen, toolbarX, toolbarY, toolbarCollapsed, showButtonNames
        case holdControlToDraw, undoWithZ, undoWithRightClick, penEraserEnd, tabletPad
    }

    /// Anything missing or unreadable keeps its default (an older or newer saved copy still loads).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func v<T: Decodable>(_ k: K, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 } ?? d }
        let d = MacSettings()
        tool = (try? c.decodeIfPresent(String.self, forKey: .tool)).flatMap { $0 }.flatMap(Tool.init(rawValue:)) ?? d.tool
        color = v(.color, d.color); width = v(.width, d.width); fadingInk = v(.fadingInk, d.fadingInk)
        opacity = v(.opacity, d.opacity); screen = v(.screen, d.screen)
        toolbarX = (try? c.decodeIfPresent(Double.self, forKey: .toolbarX)).flatMap { $0 }
        toolbarY = (try? c.decodeIfPresent(Double.self, forKey: .toolbarY)).flatMap { $0 }
        toolbarCollapsed = v(.toolbarCollapsed, d.toolbarCollapsed); showButtonNames = v(.showButtonNames, d.showButtonNames)
        holdControlToDraw = v(.holdControlToDraw, d.holdControlToDraw); undoWithZ = v(.undoWithZ, d.undoWithZ)
        undoWithRightClick = v(.undoWithRightClick, d.undoWithRightClick); penEraserEnd = v(.penEraserEnd, d.penEraserEnd)
        tabletPad = v(.tabletPad, d.tabletPad)
    }

    /// Keeps every value in range, so a damaged saved copy can't break the app.
    public func cleaned(screens: Int) -> MacSettings {
        var s = self
        s.color = min(max(s.color, 0), Settings.colors.count - 1)
        s.width = min(max(s.width, 0), Settings.widths.count - 1)
        s.opacity = s.opacity.isFinite ? min(max(s.opacity, Settings.minOpacity), 1) : 1
        s.screen = screens <= 0 ? 0 : min(max(s.screen, 0), screens - 1)
        if let x = s.toolbarX, !x.isFinite { s.toolbarX = nil }
        if let y = s.toolbarY, !y.isFinite { s.toolbarY = nil }
        return s
    }

    public static func decode(_ data: Data?, screens: Int) -> MacSettings {
        guard let data, let s = try? JSONDecoder().decode(MacSettings.self, from: data) else { return MacSettings().cleaned(screens: screens) }
        return s.cleaned(screens: screens)
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(cleaned(screens: Int.max)) }

    /// The line width in points for the chosen width.
    public var lineWidth: Double { Settings.widths[min(max(width, 0), Settings.widths.count - 1)] }
}

/// What a key does on the Mac while drawing (the drawing layer has the keyboard then). Core's Keys table, plus the
/// Mac's own: ⌘Z undoes, Esc stops drawing, and slide keys are passed on to the app in front.
public enum MacKey: Equatable, Sendable {
    case action(KeyAction)
    /// A slide key (→, ←, Space, Page Down...): passed on to the app in front, so the slide still turns.
    case pass(KeyAction)
    case stopDrawing
}

public enum MacKeys {
    /// macOS virtual key codes of the keys that aren't letters.
    public static let escape: UInt16 = 53, right: UInt16 = 124, left: UInt16 = 123, down: UInt16 = 125, up: UInt16 = 126
    public static let space: UInt16 = 49, pageDown: UInt16 = 121, pageUp: UInt16 = 116, returnKey: UInt16 = 36, enter: UInt16 = 76
    public static let f9: UInt16 = 101

    /// - Parameters:
    ///   - keyCode: the virtual key code.
    ///   - characters: the key's characters ignoring modifiers (lowercased here).
    ///   - command, control, option: modifiers held.
    ///   - undoWithZ: whether Z alone undoes.
    public static func resolve(keyCode: UInt16, characters: String, command: Bool, control: Bool = false, option: Bool = false,
                               undoWithZ: Bool = true) -> MacKey? {
        if keyCode == escape { return .stopDrawing }
        let names: [UInt16: String] = [right: "right", left: "left", down: "down", up: "up", space: "space",
                                       pageDown: "pageDown", pageUp: "pageUp", returnKey: "return", enter: "return"]
        if let n = names[keyCode], let a = Keys.action(for: n), !command { return .pass(a) }
        let c = characters.lowercased()
        if command { return c == "z" && !control && !option ? .action(.undo) : nil }
        if control || option { return nil }
        guard let a = Keys.action(for: c) else { return nil }
        if a == .undo && !undoWithZ { return nil }
        return .action(a)
    }
}

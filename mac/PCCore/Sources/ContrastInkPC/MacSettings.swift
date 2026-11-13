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
    /// Which screen the drawing layer covers (index into the Mac's screens): used only until a screen is chosen by
    /// its ID (an older saved copy), and kept in range as screens come and go.
    public var screen = 0
    /// The chosen screen's ID (its display UUID): the layer covers it whenever it is connected, and goes back to it
    /// when it returns after a dropout (a projector's cable). Nil until a screen is chosen.
    public var screenID: String?
    /// Where the toolbar was left (its top-left corner, in screen coordinates); nil until it is first dragged.
    public var toolbarX: Double?
    public var toolbarY: Double?
    public var toolbarCollapsed = false
    /// Resting the pointer on a toolbar button shows its name under the buttons.
    public var showButtonNames = true
    /// Holding Control (on its own, ~300 ms with no click) switches drawing on while it is held. Off by default on
    /// the Mac: Control-click is the Mac's right-click, and Control-drag pans or windows in Horos and OsiriX.
    public var holdControlToDraw = false
    /// While drawing, Z alone undoes (⌘Z always does).
    public var undoWithZ = true
    /// While drawing, a right-click undoes the last mark.
    public var undoWithRightClick = true
    /// A pen tablet's eraser end removes marks, whatever tool is chosen.
    public var penEraserEnd = true
    /// A tablet (Android or iPad) may connect and be used as a pad that draws here.
    public var tabletPad = false

    /// The saved copy's version: 2 since Hold Control became off by default (a version-1 copy saved it on without the
    /// presenter choosing it, so it is read as off).
    public static let version = 2

    public init() {}

    private enum K: String, CodingKey {
        case tool, color, width, fadingInk, opacity, screen, screenID, toolbarX, toolbarY, toolbarCollapsed, showButtonNames
        case holdControlToDraw, undoWithZ, undoWithRightClick, penEraserEnd, tabletPad, version
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(tool.rawValue, forKey: .tool); try c.encode(color, forKey: .color); try c.encode(width, forKey: .width)
        try c.encode(fadingInk, forKey: .fadingInk); try c.encode(opacity, forKey: .opacity); try c.encode(screen, forKey: .screen)
        try c.encodeIfPresent(screenID, forKey: .screenID)
        try c.encodeIfPresent(toolbarX, forKey: .toolbarX); try c.encodeIfPresent(toolbarY, forKey: .toolbarY)
        try c.encode(toolbarCollapsed, forKey: .toolbarCollapsed); try c.encode(showButtonNames, forKey: .showButtonNames)
        try c.encode(holdControlToDraw, forKey: .holdControlToDraw); try c.encode(undoWithZ, forKey: .undoWithZ)
        try c.encode(undoWithRightClick, forKey: .undoWithRightClick); try c.encode(penEraserEnd, forKey: .penEraserEnd)
        try c.encode(tabletPad, forKey: .tabletPad); try c.encode(Self.version, forKey: .version)
    }

    /// Anything missing or unreadable keeps its default (an older or newer saved copy still loads).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func v<T: Decodable>(_ k: K, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 } ?? d }
        let d = MacSettings()
        tool = (try? c.decodeIfPresent(String.self, forKey: .tool)).flatMap { $0 }.flatMap(Tool.init(rawValue:)) ?? d.tool
        color = v(.color, d.color); width = v(.width, d.width); fadingInk = v(.fadingInk, d.fadingInk)
        opacity = v(.opacity, d.opacity); screen = v(.screen, d.screen)
        screenID = (try? c.decodeIfPresent(String.self, forKey: .screenID)).flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
        toolbarX = (try? c.decodeIfPresent(Double.self, forKey: .toolbarX)).flatMap { $0 }
        toolbarY = (try? c.decodeIfPresent(Double.self, forKey: .toolbarY)).flatMap { $0 }
        toolbarCollapsed = v(.toolbarCollapsed, d.toolbarCollapsed); showButtonNames = v(.showButtonNames, d.showButtonNames)
        // a version-1 copy has Hold Control on because it was the default then, not because it was chosen
        holdControlToDraw = v(.version, 1) >= 2 ? v(.holdControlToDraw, d.holdControlToDraw) : d.holdControlToDraw
        undoWithZ = v(.undoWithZ, d.undoWithZ)
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

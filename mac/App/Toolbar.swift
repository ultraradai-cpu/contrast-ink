import AppKit
import ContrastInkCore
import ContrastInkPC

/// A floating panel that never activates the app: tapping its buttons leaves the keyboard with PowerPoint.
/// Hidden from screen capture where macOS still honours it (see mac/README.md: OBS on recent macOS may show it).
class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)   // above the drawing layer
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        sharingType = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The dark rounded bar behind the buttons.
final class BarBackground: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Look.bar.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(hex: "#2563EB", alpha: 0.33).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A toolbar button: a symbol (or a drawn dot), blue when switched on, a light film under the pointer. Takes the
/// first click even though the panel is never active, and says its name to the toolbar's hint line.
final class BarButton: NSView {
    var title: String { didSet { needsDisplay = true } }
    var titleColor: NSColor? { didSet { needsDisplay = true } }
    var fontSize: CGFloat
    var selected = false { didSet { needsDisplay = true } }
    /// A blue ring (the chosen colour).
    var ringed = false { didSet { needsDisplay = true } }
    var hint: String { didSet { setAccessibilityLabel(hint) } }
    var enabled = true
    var action: (() -> Void)?
    var hovered: ((BarButton, Bool) -> Void)?
    /// Draws what the button shows instead of its title (a colour, a width).
    var content: ((NSRect, BarButton) -> Void)?
    private let width: CGFloat
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressing = false

    init(_ title: String, width: CGFloat = 32, fontSize: CGFloat = 17, hint: String, action: (() -> Void)? = nil) {
        self.title = title; self.width = width; self.fontSize = fontSize; self.hint = hint; self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 38))
        setAccessibilityRole(.button)
        setAccessibilityLabel(hint)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: width, height: 38) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { action?(); return true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; hovered?(self, true) }
    override func mouseExited(with event: NSEvent) { hovering = false; hovered?(self, false) }
    override func mouseDown(with event: NSEvent) { pressing = enabled }
    override func mouseUp(with event: NSEvent) {
        defer { pressing = false }
        guard pressing, enabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard alphaValue > 0 else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        if selected { Look.blue.setFill(); shape.fill() } else if hovering && enabled { Look.hover.setFill(); shape.fill() }
        if ringed {
            Look.blue.setStroke()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            ring.lineWidth = 2
            ring.stroke()
        }
        if let content { content(r, self); return }
        let color = titleColor ?? (selected ? .white : Look.ink)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: color]
        let s = NSAttributedString(string: title, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
    }

    /// The colour the button's text has now (white on blue).
    var textColor: NSColor { selected ? .white : Look.ink }
}

final class FirstMouseSlider: NSSlider {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstMouseCheckbox: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    convenience init(_ title: String, action: @escaping (Bool) -> Void) {
        self.init(frame: .zero)
        setButtonType(.switch)
        attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: Look.ink, .font: NSFont.systemFont(ofSize: 12)])
        onChange = action
        target = self
        self.action = #selector(changed)
    }
    var onChange: ((Bool) -> Void)?
    @objc private func changed() { onChange?(state == .on) }
}

final class FirstMouseTextButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var run: (() -> Void)?
    convenience init(_ title: String, run: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        self.run = run
        target = self
        action = #selector(go)
    }
    @objc private func go() { run?() }
}

/// A line of text that can be clicked (the toolbar's hint and warning line).
final class HintLabel: NSTextField {
    var clicked: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { clicked?() }
}

func label(_ text: String, size: CGFloat = 12, color: NSColor = Look.ink) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: text)
    l.font = NSFont.systemFont(ofSize: size)
    l.textColor = color
    l.isSelectable = false
    return l
}

func separator() -> NSView {
    let v = NSView()
    v.wantsLayer = true
    v.layer?.backgroundColor = Look.separator.cgColor
    v.translatesAutoresizingMaskIntoConstraints = false
    v.widthAnchor.constraint(equalToConstant: 1).isActive = true
    v.heightAnchor.constraint(equalToConstant: 22).isActive = true
    return v
}

/// The toolbar: the same buttons and look as the Windows toolbar. The Contrast mark drags it; ‹ makes it small.
final class Toolbar {
    let panel = FloatingPanel(size: NSSize(width: 900, height: 46))
    let settingsPanel = FloatingPanel(size: NSSize(width: 420, height: 300))
    unowned let controller: AppController

    private let row = NSStackView()
    private let full = NSStackView()
    private let column = NSStackView()
    private let hint = HintLabel(labelWithString: "")
    private var drawBtn: BarButton!, recBtn: BarButton!, pauseBtn: BarButton!, foldBtn: BarButton!, settingsBtn: BarButton!
    private var screenBtn: BarButton!, fadeBtn: BarButton!, undoBtn: BarButton!
    private var gripDots: NSTextField!
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private var toolButtons: [Tool: BarButton] = [:]
    private var colorButtons: [BarButton] = [], widthButtons: [BarButton] = []
    private let opacity = FirstMouseSlider(value: 1, minValue: Settings.minOpacity, maxValue: 1, target: nil, action: nil)
    private var noticeText: String?, warningText: String?
    private var showNames = true
    // a question for the presenter, with Allow / Deny
    private let askRow = NSStackView()
    private let askLabel = NSTextField(labelWithString: "")
    private var askAnswer: ((Bool) -> Void)?

    // settings
    private let settingsStack = NSStackView()
    private var optNames: FirstMouseCheckbox!, optControl: FirstMouseCheckbox!, optZ: FirstMouseCheckbox!
    private var optRight: FirstMouseCheckbox!, optEraser: FirstMouseCheckbox!, optPad: FirstMouseCheckbox!
    private let settingsOpacity = FirstMouseSlider(value: 1, minValue: Settings.minOpacity, maxValue: 1, target: nil, action: nil)
    private let padText = label("", size: 11)
    private let permissionText = label("", size: 11, color: Look.grey)

    init(controller: AppController) {
        self.controller = controller
        build()
        buildSettings()
    }

    // MARK: building

    private func button(_ title: String, width: CGFloat = 32, size: CGFloat = 17, _ hint: String, _ action: @escaping () -> Void) -> BarButton {
        let b = BarButton(title, width: width, fontSize: size, hint: hint, action: action)
        b.hovered = { [weak self] b, inside in self?.hover(b, inside) }
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        b.heightAnchor.constraint(equalToConstant: 38).isActive = true
        return b
    }

    private func build() {
        let back = BarBackground(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = back
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        column.translatesAutoresizingMaskIntoConstraints = false
        back.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: back.leadingAnchor), column.trailingAnchor.constraint(equalTo: back.trailingAnchor),
            column.topAnchor.constraint(equalTo: back.topAnchor), column.bottomAnchor.constraint(equalTo: back.bottomAnchor),
        ])
        row.orientation = .horizontal
        row.spacing = 2
        row.alignment = .centerY
        full.orientation = .horizontal
        full.spacing = 2
        full.alignment = .centerY
        column.addArrangedSubview(row)
        hint.font = NSFont.systemFont(ofSize: 12)
        hint.textColor = Look.ink
        hint.isHidden = true
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 0
        hint.preferredMaxLayoutWidth = 620
        hint.clicked = { [weak self] in self?.hintClicked() }
        column.addArrangedSubview(hint)
        column.setCustomSpacing(2, after: row)
        askRow.orientation = .horizontal
        askRow.spacing = 6
        askRow.alignment = .centerY
        askRow.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        askLabel.font = NSFont.systemFont(ofSize: 12)
        askLabel.textColor = Look.warning
        askRow.addArrangedSubview(askLabel)
        askRow.addArrangedSubview(FirstMouseTextButton("Allow") { [weak self] in self?.answerAsk(true) })
        askRow.addArrangedSubview(FirstMouseTextButton("Deny") { [weak self] in self?.answerAsk(false) })
        askRow.isHidden = true
        column.addArrangedSubview(askRow)

        let c = controller
        row.addArrangedSubview(Grip(toolbar: self).also { g in
            gripDots = g.dots
        })
        drawBtn = button("✏ Off", width: 62, size: 15, "Draw on / off (F9). Or hold Control to draw.") { c.toggleDrawing() }
        row.addArrangedSubview(drawBtn)
        row.addArrangedSubview(separator())
        recBtn = button("⏺", "Record with OBS (start / stop)") { c.recorder.recordClicked() }
        recBtn.titleColor = Look.grey
        pauseBtn = button("⏸", "Pause recording") { c.recorder.pauseClicked() }
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = Look.ink
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        row.addArrangedSubview(recBtn)
        row.addArrangedSubview(pauseBtn)
        row.addArrangedSubview(timeLabel)
        row.addArrangedSubview(full)

        full.addArrangedSubview(separator())
        let tools: [(Tool, String, String)] = [
            (.pen, "🖊", "Pen (P)"), (.highlighter, "🖍", "Highlighter (H)"),
            (.arrow, "➚", "Arrow (A): drag from the tail to the tip"),
            (.oval, "◯", "Circle a finding (O). Hold Shift for a perfect circle."),
            (.eraser, "⌫", "Eraser (E): touch a mark to remove it"),
            (.laser, "●", "Laser pointer (L): a red dot follows the pen or mouse; dragging draws a glowing line that fades in a second. Never a mark."),
        ]
        for (t, symbol, name) in tools {
            let b = button(symbol, name) { c.setTool(t) }
            if t == .laser { b.titleColor = Look.laser; b.fontSize = 15 }
            toolButtons[t] = b
            full.addArrangedSubview(b)
        }
        full.addArrangedSubview(separator())
        for i in 0..<Settings.colors.count {
            let b = button("", width: 28, "\(Settings.colorNames[i]) (\(i + 1))") { c.setColor(i) }
            let fill = NSColor(hex: Settings.colors[i])
            b.content = { r, _ in
                let d = NSBezierPath(ovalIn: NSRect(x: r.midX - 9, y: r.midY - 9, width: 18, height: 18))
                fill.setFill(); d.fill()
                (i == Settings.colors.count - 1 ? Look.ink : NSColor.black).setStroke()   // black stays visible on the dark bar
                d.lineWidth = 0.75; d.stroke()
            }
            colorButtons.append(b)
            full.addArrangedSubview(b)
        }
        full.addArrangedSubview(separator())
        for i in 0..<Settings.widths.count {
            let b = button("", width: 28, "\(Settings.widthNames[i]) ([ thinner, ] thicker)") { c.setWidth(i) }
            let w = CGFloat(Settings.widths[i]) + 2
            b.content = { r, b in
                b.textColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: r.midX - w / 2, y: r.midY - w / 2, width: w, height: w)).fill()
            }
            widthButtons.append(b)
            full.addArrangedSubview(b)
        }
        opacity.controlSize = .small
        opacity.translatesAutoresizingMaskIntoConstraints = false
        opacity.widthAnchor.constraint(equalToConstant: 56).isActive = true
        opacity.isContinuous = true
        opacity.target = self
        opacity.action = #selector(opacityMoved(_:))
        full.addArrangedSubview(opacity)
        full.addArrangedSubview(separator())
        fadeBtn = button("⏳", "Fading ink (F): marks disappear after 3 seconds. Hold Shift while drawing to keep one.") { c.toggleFade() }
        undoBtn = button("↶", "Undo (⌘Z or Z)") { c.undo() }
        full.addArrangedSubview(fadeBtn)
        full.addArrangedSubview(undoBtn)
        full.addArrangedSubview(button("🗑", "Clear all marks (C). Undo brings them back.") { c.clear() })
        full.addArrangedSubview(separator())
        screenBtn = button("🖥1", width: 46, size: 15, "Move the drawing layer to the other screen") { c.nextScreen() }
        full.addArrangedSubview(screenBtn)
        settingsBtn = button("⚙", "Settings: button names, opacity, the tablet link, permissions") { [weak self] in self?.toggleSettings() }
        full.addArrangedSubview(settingsBtn)
        foldBtn = button("‹", width: 26, "Make the toolbar small / big") { c.toggleFold() }
        row.addArrangedSubview(foldBtn)
        row.addArrangedSubview(button("✕", width: 28, size: 13, "Quit Contrast Ink") { NSApp.terminate(nil) })
    }

    private func buildSettings() {
        let back = BarBackground(frame: settingsPanel.contentRect(forFrameRect: settingsPanel.frame))
        settingsPanel.contentView = back
        settingsStack.orientation = .vertical
        settingsStack.alignment = .leading
        settingsStack.spacing = 5
        settingsStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        settingsStack.translatesAutoresizingMaskIntoConstraints = false
        back.addSubview(settingsStack)
        NSLayoutConstraint.activate([
            settingsStack.leadingAnchor.constraint(equalTo: back.leadingAnchor), settingsStack.trailingAnchor.constraint(equalTo: back.trailingAnchor),
            settingsStack.topAnchor.constraint(equalTo: back.topAnchor), settingsStack.bottomAnchor.constraint(equalTo: back.bottomAnchor),
            settingsStack.widthAnchor.constraint(equalToConstant: 420),
        ])
        let c = controller
        func heading(_ t: String) { settingsStack.addArrangedSubview(label(t, color: Look.grey)) }
        heading("Toolbar")
        optNames = FirstMouseCheckbox("Show Button Names When the Pointer Rests on One") { on in c.change { $0.showButtonNames = on } }
        settingsStack.addArrangedSubview(optNames)
        heading("Drawing")
        optControl = FirstMouseCheckbox("Hold Control to Draw") { on in c.change { $0.holdControlToDraw = on } }
        optZ = FirstMouseCheckbox("Z Key Undoes (⌘Z Always Works)") { on in c.change { $0.undoWithZ = on } }
        optRight = FirstMouseCheckbox("Right-Click Undoes") { on in c.change { $0.undoWithRightClick = on } }
        optEraser = FirstMouseCheckbox("Pen Tablet's Eraser End Erases") { on in c.change { $0.penEraserEnd = on } }
        [optControl, optZ, optRight, optEraser].forEach { settingsStack.addArrangedSubview($0!) }
        let op = NSStackView()
        op.orientation = .horizontal
        op.addArrangedSubview(label("Opacity of the Pen, Arrow and Circle"))
        settingsOpacity.controlSize = .small
        settingsOpacity.target = self
        settingsOpacity.action = #selector(opacityMoved(_:))
        settingsOpacity.isContinuous = true
        settingsOpacity.widthAnchor.constraint(equalToConstant: 120).isActive = true
        op.addArrangedSubview(settingsOpacity)
        settingsStack.addArrangedSubview(op)
        heading("Android Tablet or iPad as a Pad")
        optPad = FirstMouseCheckbox("Let a Tablet Draw Here (Over Wi-Fi, and by USB Cable)") { on in c.setTabletPad(on) }
        settingsStack.addArrangedSubview(optPad)
        padText.preferredMaxLayoutWidth = 396
        settingsStack.addArrangedSubview(padText)
        heading("Permissions (System Settings → Privacy & Security)")
        permissionText.preferredMaxLayoutWidth = 396
        settingsStack.addArrangedSubview(permissionText)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.addArrangedSubview(FirstMouseTextButton("Screen Recording…") { Permissions.openScreenRecording() })
        buttons.addArrangedSubview(FirstMouseTextButton("Accessibility…") { Permissions.openAccessibility() })
        settingsStack.addArrangedSubview(buttons)
    }

    @objc private func opacityMoved(_ s: NSSlider) {
        let v = (s.doubleValue * 100).rounded() / 100
        controller.setOpacity(v)
        if showNames { show(hint: "Opacity \(Int(v * 100))%: of the pen, arrow and circle (new marks). The highlighter keeps its own see-through look.", warning: false) }
    }

    // MARK: showing

    /// Shows the current state: which tool, colour, width, and whether drawing is on.
    func refresh(drawing: Bool, settings s: MacSettings, screens: Int) {
        drawBtn.selected = drawing
        drawBtn.title = drawing ? "✏ On" : "✏ Off"
        for (t, b) in toolButtons { b.selected = s.tool == t }
        for (i, b) in colorButtons.enumerated() { b.ringed = i == s.color }
        for (i, b) in widthButtons.enumerated() { b.selected = i == s.width }
        fadeBtn.selected = s.fadingInk
        if abs(opacity.doubleValue - s.opacity) > 0.001 { opacity.doubleValue = s.opacity }
        if abs(settingsOpacity.doubleValue - s.opacity) > 0.001 { settingsOpacity.doubleValue = s.opacity }
        screenBtn.isHidden = screens < 2
        screenBtn.title = "🖥\(s.screen + 1)"
        full.isHidden = s.toolbarCollapsed
        foldBtn.title = s.toolbarCollapsed ? "›" : "‹"
        if s.toolbarCollapsed && settingsPanel.isVisible { hideSettings() }
        showNames = s.showButtonNames
        optNames.state = s.showButtonNames ? .on : .off
        optControl.state = s.holdControlToDraw ? .on : .off
        optZ.state = s.undoWithZ ? .on : .off
        optRight.state = s.undoWithRightClick ? .on : .off
        optEraser.state = s.penEraserEnd ? .on : .off
        optPad.state = s.tabletPad ? .on : .off
        fit()
    }

    func setCanUndo(_ can: Bool) { undoBtn.titleColor = can ? nil : Look.grey }

    enum RecState { case idle, starting, recording, paused, stopping }

    /// The recording buttons: grey ⏺ when OBS isn't connected, red when ready, ⏹ and a timer while recording.
    func showRecording(_ state: RecState, connected: Bool, elapsed: Double) {
        let on = state == .recording || state == .paused || state == .stopping
        recBtn.title = on ? "⏹" : "⏺"
        recBtn.titleColor = state == .paused ? Look.amber : (on || connected) ? Look.recRed : Look.grey
        recBtn.hint = on ? "Stop recording (OBS)" : state == .starting ? "Starting OBS recording"
            : connected ? "Record with OBS (start / stop)" : "Record with OBS (OBS not connected yet: press to connect)"
        // ⏸ and the timer keep their room when hidden, so pressing ⏺ never changes the toolbar's width
        pauseBtn.alphaValue = on ? 1 : 0
        pauseBtn.enabled = on
        pauseBtn.title = state == .paused ? "▶" : "⏸"
        pauseBtn.hint = state == .paused ? "Resume recording" : "Pause recording"
        timeLabel.alphaValue = on ? 1 : 0
        timeLabel.stringValue = Obs.timer(elapsed)
    }

    /// Something the presenter should know about recording or the tablet, shown under the buttons until replaced or
    /// cleared with nil (or clicked). A standing warning stays under it.
    func notice(_ text: String?) {
        noticeText = text
        standing()
    }

    /// A question under the buttons with Allow and Deny; `answer` gets the choice once. A new question (or
    /// cancelAsk) answers the one before it with Deny.
    func ask(_ text: String, answer: @escaping (Bool) -> Void) {
        let old = askAnswer
        askAnswer = answer
        askLabel.stringValue = text
        askRow.isHidden = false
        fit()
        old?(false)
    }

    /// Takes the question away, answering Deny if it is still open.
    func cancelAsk() {
        guard !askRow.isHidden || askAnswer != nil else { return }
        answerAsk(false)
    }

    var asking: Bool { !askRow.isHidden }

    private func answerAsk(_ yes: Bool) {
        let a = askAnswer
        askAnswer = nil
        askRow.isHidden = true
        fit()
        a?(yes)
    }

    /// A problem about this Mac that stays: the dots beside the mark turn red and the line stays under the buttons.
    func warn(_ text: String) {
        warningText = warningText == nil || warningText == text ? text : warningText! + "\n" + text
        gripDots.textColor = .systemRed
        standing()
    }

    private func standingText() -> String? {
        switch (noticeText, warningText) {
        case let (n?, w?): return n + "\n" + w
        case let (n, w): return n ?? w
        }
    }

    private func standing() {
        if let t = standingText() { show(hint: t, warning: true) } else { hint.isHidden = true; fit() }
    }

    private func show(hint text: String, warning: Bool) {
        hint.stringValue = text
        hint.textColor = warning ? Look.warning : Look.ink
        hint.isHidden = false
        fit()
    }

    private func hover(_ b: BarButton, _ inside: Bool) {
        if inside && showNames { show(hint: b.hint, warning: false) } else if !inside { standing() }
    }

    private func hintClicked() {
        if noticeText != nil && hint.stringValue == standingText() { notice(nil) }
    }

    /// The panel takes the size of its buttons, keeping its top-left corner where it is.
    func fit() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = column.fittingSize
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        if settingsPanel.isVisible { placeSettings() }
    }

    // MARK: settings

    func showPad(_ text: String?) {
        padText.stringValue = text ?? ""
        padText.isHidden = text == nil
        fitSettings()
    }

    func showPermissions(_ text: String) {
        permissionText.stringValue = text
        fitSettings()
    }

    private func toggleSettings() {
        if settingsPanel.isVisible { hideSettings(); return }
        controller.refreshPermissions()
        fitSettings()
        placeSettings()
        settingsPanel.orderFrontRegardless()
        settingsBtn.selected = true
    }

    private func hideSettings() {
        settingsPanel.orderOut(nil)
        settingsBtn.selected = false
    }

    private func fitSettings() {
        guard let content = settingsPanel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = settingsStack.fittingSize
        settingsPanel.setContentSize(size)
        if settingsPanel.isVisible { placeSettings() }
    }

    /// Under the toolbar, or above it when there is no room below; kept on the toolbar's screen.
    private func placeSettings() {
        let f = panel.frame, s = settingsPanel.frame.size
        let screen = (panel.screen ?? NSScreen.main)?.visibleFrame ?? f
        var x = min(max(f.minX, screen.minX), screen.maxX - s.width)
        x = max(x, screen.minX)
        let below = f.minY - 6 - s.height
        let y = below >= screen.minY ? below : min(f.maxY + 6, screen.maxY - s.height)
        settingsPanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// The window numbers of the toolbar and its settings, to leave out of the tablet's picture.
    var windowNumbers: [Int] { [panel.windowNumber, settingsPanel.windowNumber] }

    /// Places the toolbar: where it was left, else the top right of the main screen (a corner, out of the way).
    func place(x: Double?, y: Double?) {
        fit()
        let size = panel.frame.size
        let screens = NSScreen.screens
        if let x, let y, screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(NSPoint(x: x + 20, y: y - 10)) }) {
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        } else if let main = NSScreen.main ?? screens.first {
            let v = main.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: v.maxX - size.width - 16, y: v.maxY - 8))
        }
        panel.orderFrontRegardless()
    }

    fileprivate func dragged() {
        let f = panel.frame
        controller.toolbarMoved(x: Double(f.minX), y: Double(f.maxY))
        if settingsPanel.isVisible { placeSettings() }
    }
}

/// The Contrast mark: drag the toolbar by it. The dots beside it turn red when something needs attention.
final class Grip: NSView {
    unowned let toolbar: Toolbar
    let dots = NSTextField(labelWithString: "⋮")
    private var start: NSPoint?, origin: NSPoint?

    init(toolbar: Toolbar) {
        self.toolbar = toolbar
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 38))
        let image = NSImageView(image: Bundle.main.image(forResource: "mark") ?? NSImage())
        image.imageScaling = .scaleProportionallyUpOrDown
        image.frame = NSRect(x: 4, y: 8, width: 22, height: 22)
        addSubview(image)
        dots.textColor = Look.blue
        dots.font = NSFont.systemFont(ofSize: 14)
        dots.frame = NSRect(x: 27, y: 9, width: 10, height: 20)
        addSubview(dots)
        setAccessibilityLabel("Contrast Ink. Drag to move.")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 38).isActive = true
        heightAnchor.constraint(equalToConstant: 38).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        origin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let origin, let w = window else { return }
        let now = NSEvent.mouseLocation
        w.setFrameOrigin(NSPoint(x: origin.x + now.x - start.x, y: origin.y + now.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        if start != nil { toolbar.dragged() }   // the place is saved once, when the mouse is let go
        start = nil
    }
}

extension NSObjectProtocol {
    /// Configures an object in place: `Grip(...).also { ... }`.
    func also(_ f: (Self) -> Void) -> Self { f(self); return self }
}

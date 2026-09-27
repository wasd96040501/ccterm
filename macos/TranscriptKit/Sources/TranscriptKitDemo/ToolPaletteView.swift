import AppKit
import TranscriptKit

/// The demo's controls, floating in glass at the bottom centre of the window:
/// a round toggle, and beside it a capsule holding one section of tools at a time.
///
/// **Commands go up the responder chain, the way a menu's do.** Every control is
/// nil-targeted at the same selectors the menu bar uses, so a tool and its menu
/// item are one command with one implementation and one validation — the window
/// controller's `validateUserInterfaceItem(_:)`, asked for these buttons on every
/// window update exactly as a toolbar asks for its items. A command that carries
/// a value (a row, a count, a width) is sent with the palette as its sender and
/// reads the value off it: `NSColorPanel`'s `changeColor(_:)` shape.
///
/// **Folding is a stack view hiding an arranged view inside an animation group**,
/// AppKit's own way to animate a layout change. The two pieces of glass share an
/// `NSGlassEffectContainerView`, so as the capsule collapses toward the toggle the
/// glass flows into it rather than vanishing beside it. Reduce Motion makes it a
/// cut.
///
/// What is shown about the active editor comes down through `configure(with:)`;
/// the palette holds no state about editors of its own.
@MainActor
final class ToolPaletteView: NSView {

    /// What the palette's controls show about the active editor. Enabling is not
    /// here — that is validation's, the same answer the menu gets.
    struct Status {
        var isStreaming: Bool
        var coldLoad: String
        var maxContentWidth: CGFloat
        var isPinned: Bool
    }

    // MARK: - What a command reads off its sender

    /// The row and position the Scroll section is set to.
    var scrollTarget: (row: Int, position: TranscriptView.ScrollPosition) {
        let positions: [TranscriptView.ScrollPosition] = [.top, .center, .bottom, .nearestEdge]
        return (rowField.integerValue, positions[max(0, scrollPositions.selectedSegment)])
    }

    /// The row the Stream section streams into.
    var streamRow: Int { streamField.integerValue }

    /// How many rows the Cold Load section loads.
    var coldLoadRowCount: Int { coldLoadField.integerValue }

    /// The width the Width section's slider is at.
    var maxContentWidth: CGFloat { widthSlider.doubleValue.rounded() }

    // MARK: - Folding

    /// Folded to the toggle alone. Animated unless Reduce Motion is on.
    var isCollapsed = false {
        didSet {
            guard isCollapsed != oldValue else { return }
            toggle.state = isCollapsed ? .off : .on
            let apply = { self.capsule.isHidden = self.isCollapsed }
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, window != nil else {
                return apply()
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                apply()
                layoutSubtreeIfNeeded()
            }
        }
    }

    // MARK: - Sections

    private enum Section: Int, CaseIterable {
        case editors, scroll, mutate, stream, load, width

        var title: String {
            switch self {
            case .editors: "Editors"
            case .scroll: "Scroll"
            case .mutate: "Mutate"
            case .stream: "Stream"
            case .load: "Cold Load"
            case .width: "Content Width"
            }
        }

        var symbol: String {
            switch self {
            case .editors: "rectangle.split.2x1"
            case .scroll: "arrow.up.and.down.text.horizontal"
            case .mutate: "plus.forwardslash.minus"
            case .stream: "text.append"
            case .load: "tray.and.arrow.down"
            case .width: "arrow.left.and.right.text.vertical"
            }
        }
    }

    // MARK: - Controls

    private lazy var toggle: NSButton = {
        let button = NSButton(
            image: Self.symbol("slider.horizontal.3", "Tools"), target: nil,
            action: #selector(DemoWindowController.toggleTools(_:)))
        button.setButtonType(.pushOnPushOff)
        button.state = .on
        button.isBordered = false
        button.toolTip = "Hide Tools (⌥⌘T)"
        return button
    }()

    private lazy var sections: NSSegmentedControl = {
        let control = NSSegmentedControl(
            images: Section.allCases.map { Self.symbol($0.symbol, $0.title) },
            trackingMode: .selectOne, target: self, action: #selector(sectionChanged))
        for section in Section.allCases {
            control.setToolTip(section.title, forSegment: section.rawValue)
        }
        control.selectedSegment = Section.editors.rawValue
        return control
    }()

    private lazy var pinButton = command("Pin Tab", #selector(DemoWindowController.togglePinnedTab(_:)))
    private lazy var streamButton = forwarded("Stream", #selector(DemoWindowController.toggleStreaming(_:)))
    private lazy var rowField = numberField("0", width: 52)
    /// Row 1: the first assistant turn, which is the row kind worth watching grow.
    private lazy var streamField = numberField("1", width: 52)
    /// Ten thousand, because that is where the two loads stop being a matter of taste.
    private lazy var coldLoadField = numberField("10000", width: 68)
    private lazy var coldLoadLabel = secondaryText()
    private lazy var widthLabel = secondaryText()

    private lazy var scrollPositions: NSSegmentedControl = {
        let control = NSSegmentedControl(
            labels: ["Top", "Center", "Bottom", "Nearest"], trackingMode: .selectOne,
            target: nil, action: nil)
        control.selectedSegment = 0
        return control
    }()

    private lazy var widthSlider: NSSlider = {
        let slider = NSSlider(
            value: 720, minValue: 320, maxValue: 1200, target: self,
            action: #selector(widthChanged))
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        return slider
    }()

    /// One per `Section`, in its order; only the selected one is shown.
    private lazy var sectionRows: [NSStackView] = [
        row([
            command("New Tab", #selector(DemoWindowController.newTab(_:))),
            command("Close Tab", #selector(DemoWindowController.closeTab(_:))),
            pinButton,
            command("Split Right", #selector(DemoWindowController.addEditorOnRight(_:))),
            command("Close Editor", #selector(DemoWindowController.closeEditor(_:))),
        ]),
        row([
            label("Row"), rowField, scrollPositions,
            forwarded("Scroll", #selector(DemoWindowController.scrollToRow(_:))),
        ]),
        row([
            command("Prepend 5", #selector(DemoWindowController.prependRows(_:))),
            command("Append", #selector(DemoWindowController.appendRow(_:))),
            command("Remove 3", #selector(DemoWindowController.removeTopRows(_:))),
            command("Grow", #selector(DemoWindowController.growFirstRow(_:))),
            command("Re-measure", #selector(DemoWindowController.remeasureFirstRow(_:))),
            command("Batch", #selector(DemoWindowController.batchMutation(_:))),
        ]),
        row([label("Row"), streamField, streamButton]),
        row([
            coldLoadField,
            forwarded("Prepared", #selector(DemoWindowController.coldLoadPrepared(_:))),
            forwarded("Sync", #selector(DemoWindowController.coldLoadSync(_:))),
            command("Cancel", #selector(DemoWindowController.cancelColdLoad(_:))),
            coldLoadLabel,
        ]),
        row([widthSlider, widthLabel]),
    ]

    /// The capsule: the section switch, then the section.
    private lazy var capsule: NSView = {
        let divider = NSBox()
        divider.boxType = .separator
        let stack = NSStackView(views: [sections, divider] + sectionRows)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 16)
        stack.setCustomSpacing(10, after: sections)
        divider.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return Self.glass(around: stack, height: Self.height)
    }()

    private lazy var toggleGlass: NSView = {
        let glass = Self.glass(around: toggle, height: Self.height)
        toggle.widthAnchor.constraint(equalTo: toggle.heightAnchor).isActive = true
        return glass
    }()

    private static let height: CGFloat = 44

    // MARK: - Life cycle

    init() {
        super.init(frame: .zero)
        let row = NSStackView(views: [toggleGlass, capsule])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let container = Self.glassContainer(around: row)
        addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        sectionChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    /// Validated on every window update, as a toolbar validates its items — so a
    /// tool is enabled exactly when its menu item is.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidUpdate), name: NSWindow.didUpdateNotification,
            object: window)
    }

    @objc private func windowDidUpdate(_ notification: Notification) {
        guard !capsule.isHidden else { return }
        for control in sectionRows[sections.selectedSegment].arrangedSubviews {
            guard let button = control as? CommandButton,
                let action = button.target === self ? forwardedActions[button.tag] : button.action
            else { continue }
            let target = receiver(of: action)
            button.isEnabled =
                (target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(button) ?? (target != nil)
        }
    }

    // MARK: - Showing

    func configure(with status: Status) {
        streamButton.title = status.isStreaming ? "Stop" : "Stream"
        coldLoadLabel.stringValue = status.coldLoad
        widthSlider.doubleValue = status.maxContentWidth
        widthLabel.stringValue = "\(Int(status.maxContentWidth)) pt"
        pinButton.title = status.isPinned ? "Unpin Tab" : "Pin Tab"
        toggle.toolTip = isCollapsed ? "Show Tools (⌥⌘T)" : "Hide Tools (⌥⌘T)"
    }

    // MARK: - Building

    private static func symbol(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description)!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
    }

    /// A capsule of glass around `content`; the HUD material before macOS 26.
    private static func glass(around content: NSView, height: CGFloat) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let glass: NSView
        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView()
            effect.cornerRadius = height / 2
            // `#available` is a run-time check and the symbol still has to be in
            // the SDK being compiled against: Swift 6.4 is the first to ship with
            // one that has it (Xcode 27), and CI builds with Xcode 26.
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) { effect.effectIsInteractive = true }
            #endif
            effect.contentView = content
            glass = effect
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = height / 2
            effect.layer?.masksToBounds = true
            effect.addSubview(content)
            pin(content, to: effect)
            glass = effect
        }
        glass.heightAnchor.constraint(equalToConstant: height).isActive = true
        return glass
    }

    /// What lets the two pieces of glass flow into each other as the capsule
    /// folds; a plain view before macOS 26, where there is nothing to merge.
    private static func glassContainer(around content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let container: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectContainerView()
            glass.spacing = 8
            glass.contentView = content
            container = glass
        } else {
            container = NSView()
            container.addSubview(content)
            pin(content, to: container)
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        return container
    }

    private static func pin(_ content: NSView, to container: NSView) {
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// An accessory bar's button: the title alone, with the bezel appearing under
    /// the pointer — the glass is already the bar's background.
    private static func style(_ button: NSButton) {
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    /// A command with no value: nil-targeted, straight up the chain.
    private func command(_ title: String, _ action: Selector) -> NSButton {
        let button = CommandButton(title: title, target: nil, action: action)
        Self.style(button)
        return button
    }

    /// A command that carries a value: sent by the palette, which the receiver
    /// reads the value off.
    private func forwarded(_ title: String, _ action: Selector) -> NSButton {
        let button = CommandButton(title: title, target: self, action: #selector(forward(_:)))
        Self.style(button)
        button.tag = forwardedActions.count
        forwardedActions.append(action)
        return button
    }

    private var forwardedActions: [Selector] = []

    @objc private func forward(_ sender: NSButton) {
        NSApp.sendAction(forwardedActions[sender.tag], to: nil, from: self)
    }

    /// Who a command sent from here would reach: the first object up this
    /// window's responder chain that implements it. This window's and not the key
    /// window's, which `NSApp.target(forAction:)` would ask — a click here makes
    /// this window key first, so this is the chain the command travels.
    private func receiver(of action: Selector) -> NSResponder? {
        var responder = window?.firstResponder
        while let current = responder, !current.responds(to: action) {
            responder = current.nextResponder
        }
        return responder
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func numberField(_ value: String, width: CGFloat) -> NSTextField {
        let field = NSTextField(string: value)
        field.bezelStyle = .roundedBezel
        field.alignment = .right
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        field.formatter = formatter
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func secondaryText() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: - Local actions

    @objc private func sectionChanged() {
        for (index, row) in sectionRows.enumerated() {
            row.isHidden = index != sections.selectedSegment
        }
    }

    @objc private func widthChanged() {
        widthLabel.stringValue = "\(Int(maxContentWidth)) pt"
        NSApp.sendAction(#selector(DemoWindowController.changeMaxContentWidth(_:)), to: nil, from: self)
    }
}

/// A palette button, declared validatable. It already has the `action` and `tag`
/// validation asks about — every `NSControl` does — and lacks only the
/// declaration, which is what lets the window controller's one
/// `validateUserInterfaceItem(_:)` answer for it as it does for the menu item.
private final class CommandButton: NSButton, NSValidatedUserInterfaceItem {}

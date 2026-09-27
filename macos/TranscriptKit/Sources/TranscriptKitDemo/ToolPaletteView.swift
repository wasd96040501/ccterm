import AppKit
import TranscriptKit

/// The demo's controls, floating at the bottom centre of the window over
/// whichever editor is under them, and folded away to one small button when
/// they are not wanted.
///
/// **One section at a time.** The controls fall into six groups — the editor
/// area's tabs and splits, scrolling, mutations, streaming, cold load, content
/// width — and only the one picked in the palette's own switcher is shown, so the
/// palette is two short rows however many controls there are. What it used to be
/// was a bar two hundred points tall across the whole window: every control at
/// once, and a fifth of the transcript gone for them.
///
/// **It acts on the active editor**, and says which one in its status line. It
/// never touches an editor: every control reports intent through a closure, the
/// window controller decides what it means, and what is shown comes back
/// through `configure(with:)`.
@MainActor
final class ToolPaletteView: NSView {

    /// What the palette shows about the active editor. Handed over whole, so a
    /// configuration never depends on the one before it.
    struct Status {
        var title: String
        var rows: Int
        var isStreaming: Bool
        var coldLoad: String
        var maxContentWidth: CGFloat
        var isPinned: Bool
        var canAddEditor: Bool
        var hasEditor: Bool
    }

    var onNewTab: (() -> Void)?
    var onCloseTab: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onAddEditor: (() -> Void)?
    var onCloseEditor: (() -> Void)?
    var onScrollToRow: ((Int, TranscriptView.ScrollPosition) -> Void)?
    var onPrepend: (() -> Void)?
    var onAppend: (() -> Void)?
    var onRemoveTop: (() -> Void)?
    var onGrowFirst: (() -> Void)?
    var onRemeasureFirst: (() -> Void)?
    var onBatch: (() -> Void)?
    /// Start streaming into this row, or stop whatever is streaming.
    var onStream: ((Int) -> Void)?
    /// Load this many rows, measured off the main actor first (`true`) or inside
    /// the insert.
    var onColdLoad: ((Int, Bool) -> Void)?
    var onCancelColdLoad: (() -> Void)?
    var onMaxContentWidth: ((CGFloat) -> Void)?

    /// Folded to the show button. View-private state: nothing outside needs to
    /// know, beyond the menu item that flips it.
    var isCollapsed = false {
        didSet {
            panel.isHidden = isCollapsed
            showButton.isHidden = !isCollapsed
        }
    }

    private enum Section: Int, CaseIterable {
        case workspace, scroll, mutate, stream, load, width

        var title: String {
            switch self {
            case .workspace: "Editors"
            case .scroll: "Scroll"
            case .mutate: "Mutate"
            case .stream: "Stream"
            case .load: "Cold Load"
            case .width: "Width"
            }
        }
    }

    // MARK: - Controls

    private lazy var sections: NSSegmentedControl = {
        let control = NSSegmentedControl(
            labels: Section.allCases.map(\.title), trackingMode: .selectOne, target: self,
            action: #selector(sectionChanged))
        control.controlSize = .small
        control.selectedSegment = Section.workspace.rawValue
        return control
    }()

    private lazy var statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        // Monospaced digits, or the count jitters sideways as rows arrive.
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private lazy var hideButton = symbolButton(
        "chevron.down", label: "Hide Tools", action: #selector(collapse))

    private lazy var pinButton = button("Pin Tab", #selector(togglePin))
    private lazy var addEditorButton = button("Add Editor on Right", #selector(addEditor))
    private lazy var streamButton = button("Stream", #selector(stream))
    private lazy var rowField = numberField("0", width: 56)
    /// Row 1: the first assistant turn, which is the row kind worth watching grow.
    private lazy var streamField = numberField("1", width: 56)
    /// Ten thousand, because that is where the two loads stop being a matter of taste.
    private lazy var coldLoadField = numberField("10000", width: 72)
    private lazy var coldLoadLabel = statusText()
    private lazy var widthLabel = statusText()

    private lazy var positions: NSSegmentedControl = {
        let control = NSSegmentedControl(
            labels: ["Top", "Center", "Bottom", "Nearest"], trackingMode: .selectOne,
            target: nil, action: nil)
        control.controlSize = .small
        control.selectedSegment = 0
        return control
    }()

    private lazy var widthSlider: NSSlider = {
        let slider = NSSlider(
            value: 720, minValue: 320, maxValue: 1200, target: self,
            action: #selector(widthChanged))
        slider.controlSize = .small
        return slider
    }()

    private lazy var sectionRows: [NSStackView] = [
        row([
            button("New Tab", #selector(newTab)), button("Close Tab", #selector(closeTab)),
            pinButton, addEditorButton, button("Close Editor", #selector(closeEditor)),
        ]),
        row([
            NSTextField(labelWithString: "Row"), rowField, positions,
            button("Scroll to Row", #selector(scrollToRow)),
        ]),
        row([
            button("Prepend 5", #selector(prepend)), button("Append 1", #selector(append)),
            button("Remove Top 3", #selector(removeTop)), button("Grow Row 0", #selector(growFirst)),
            button("Re-measure Row 0", #selector(remeasureFirst)),
            button("Batch", #selector(batch)),
        ]),
        row([NSTextField(labelWithString: "Row"), streamField, streamButton]),
        row([
            coldLoadField, button("Prepared", #selector(coldLoadPrepared)),
            button("Sync", #selector(coldLoadSync)), button("Cancel", #selector(cancelColdLoad)),
            coldLoadLabel,
        ]),
        row([NSTextField(labelWithString: "Max content width"), widthSlider, widthLabel]),
    ]

    private lazy var header = row([sections, statusLabel, hideButton])

    private lazy var content: NSStackView = {
        let stack = NSStackView(views: [header] + sectionRows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        return stack
    }()

    private lazy var panel: NSView = Self.material(around: content, cornerRadius: 16)

    private lazy var showButton: NSView = {
        let button = NSButton(
            title: "Tools",
            image: NSImage(
                systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)!,
            target: self, action: #selector(expand))
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.controlSize = .small
        let stack = NSStackView(views: [button])
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        let material = Self.material(around: stack, cornerRadius: 14)
        material.isHidden = true
        return material
    }()

    init() {
        super.init(frame: .zero)
        configureHierarchy()
        configureConstraints()
        sectionChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("code-only")
    }

    private func configureHierarchy() {
        for view in [panel, showButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
    }

    private func configureConstraints() {
        var constraints: [NSLayoutConstraint] = []
        for view in [panel, showButton] {
            constraints += [
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
                view.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            ]
        }
        // The header runs the width of the widest section, so the palette does not
        // change width as sections are switched only because the status did.
        constraints.append(statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 160))
        NSLayoutConstraint.activate(constraints)
    }

    /// Clicks pass through wherever the palette draws nothing — the palette's own
    /// view spans the larger of its two states.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// Glass where the system has it, the HUD material where it does not.
    private static func material(around content: NSView, cornerRadius: CGFloat) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    // MARK: - Showing

    func configure(with status: Status) {
        statusLabel.stringValue =
            status.hasEditor
            ? "\(status.title) · \(status.rows) rows\(status.isStreaming ? " · streaming" : "")"
            : "No editor"
        streamButton.title = status.isStreaming ? "Stop" : "Stream"
        coldLoadLabel.stringValue = status.coldLoad
        widthSlider.doubleValue = status.maxContentWidth
        widthLabel.stringValue = "\(Int(status.maxContentWidth)) pt"
        pinButton.title = status.isPinned ? "Unpin Tab" : "Pin Tab"
        addEditorButton.isEnabled = status.canAddEditor
        for row in sectionRows.dropFirst() {
            for case let control as NSControl in row.arrangedSubviews {
                control.isEnabled = status.hasEditor
            }
        }
    }

    // MARK: - Building

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private func symbolButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
            target: self, action: action)
        button.isBordered = false
        button.toolTip = label
        return button
    }

    private func numberField(_ value: String, width: CGFloat) -> NSTextField {
        let field = NSTextField(string: value)
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        field.formatter = formatter
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func statusText() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: - Actions

    @objc private func sectionChanged() {
        for (index, row) in sectionRows.enumerated() {
            row.isHidden = index != sections.selectedSegment
        }
    }

    @objc private func collapse() { isCollapsed = true }
    @objc private func expand() { isCollapsed = false }

    @objc private func newTab() { onNewTab?() }
    @objc private func closeTab() { onCloseTab?() }
    @objc private func togglePin() { onTogglePin?() }
    @objc private func addEditor() { onAddEditor?() }
    @objc private func closeEditor() { onCloseEditor?() }

    @objc private func scrollToRow() {
        let position: TranscriptView.ScrollPosition =
            switch positions.selectedSegment {
            case 0: .top
            case 1: .center
            case 2: .bottom
            default: .nearestEdge
            }
        onScrollToRow?(rowField.integerValue, position)
    }

    @objc private func prepend() { onPrepend?() }
    @objc private func append() { onAppend?() }
    @objc private func removeTop() { onRemoveTop?() }
    @objc private func growFirst() { onGrowFirst?() }
    @objc private func remeasureFirst() { onRemeasureFirst?() }
    @objc private func batch() { onBatch?() }
    @objc private func stream() { onStream?(streamField.integerValue) }
    @objc private func coldLoadPrepared() { onColdLoad?(coldLoadField.integerValue, true) }
    @objc private func coldLoadSync() { onColdLoad?(coldLoadField.integerValue, false) }
    @objc private func cancelColdLoad() { onCancelColdLoad?() }

    @objc private func widthChanged() {
        let width = widthSlider.doubleValue.rounded()
        widthLabel.stringValue = "\(Int(width)) pt"
        onMaxContentWidth?(width)
    }
}

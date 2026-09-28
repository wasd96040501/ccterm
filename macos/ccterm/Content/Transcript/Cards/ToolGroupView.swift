import AppKit

/// A stretch of tool calls as one card.
///
/// **One call** is the card: its row, pressed to open what it did.
///
/// **Several** fold behind a header that answers what a reader asks first —
/// what kind of work (`Read 3 files · Edited 2 files · Ran 1 command`), how
/// much changed (`+12 −3`), and whether anything failed — with a disclosure
/// chevron, closed by default. Open, the calls are listed one row each, in
/// order. The card never grows past ``maximumVisibleSteps`` rows; a longer
/// stretch scrolls inside it. Detail — a diff, a file, a command's output —
/// never unfolds here: it opens beside the transcript, in the other editor.
///
/// Heights come from ``height(for:expanded:)`` alone, never from the view: the
/// transcript asks for every row's height long before building any.
@MainActor
final class ToolGroupView: CardSurfaceView {
    static let maximumVisibleSteps = 8

    private static let padding: CGFloat = 4
    private static let rowHeight = ToolStepRowView.height

    weak var delegate: TranscriptCardDelegate?

    private let header = GroupHeaderView()
    private let separator = SeparatorView()
    private let list = StepListScrollView()
    private let listContent = FlippedView()
    private var rows: [ToolStepRowView] = []
    private var group: ToolGroup?
    private var isExpanded = false

    /// The card's height for `group`, open or closed. Width doesn't enter:
    /// every line truncates rather than wraps.
    static func height(for group: ToolGroup, expanded: Bool) -> CGFloat {
        guard group.steps.count > 1 else { return padding * 2 + rowHeight }
        let closed = padding * 2 + rowHeight
        guard expanded else { return closed }
        let visible = CGFloat(min(group.steps.count, maximumVisibleSteps))
        return closed + 1 + padding + visible * rowHeight
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        list.documentView = listContent
        addSubview(header)
        addSubview(separator)
        addSubview(list)
        header.onClick = { [weak self] _ in
            guard let self else { return }
            delegate?.cardDidToggle(self)
        }
    }

    func configure(with group: ToolGroup, expanded: Bool, animated: Bool = false) {
        let isSingle = group.steps.count == 1
        if group != self.group {
            self.group = group
            header.configure(summary: group.summary, stat: group.lineStat, failures: group.failures)
            configureRows(group.steps)
        }
        isExpanded = expanded || isSingle
        header.isHidden = isSingle
        separator.isHidden = isSingle
        header.setExpanded(expanded, animated: animated)
        list.scroll(.zero)
        needsLayout = true
    }

    private func configureRows(_ steps: [ToolStep]) {
        while rows.count < steps.count {
            let row = ToolStepRowView()
            listContent.addSubview(row)
            rows.append(row)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= steps.count
            guard index < steps.count else { continue }
            let step = steps[index]
            row.configure(with: step)
            row.onOpen = { [weak self] pinned in
                guard let self, let document = step.document else { return }
                delegate?.card(self, open: document, pinned: pinned)
            }
        }
    }

    // MARK: - Layout

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = bounds.width
        let count = group?.steps.count ?? 0
        if count <= 1 {
            list.frame = NSRect(x: 0, y: Self.padding, width: width, height: Self.rowHeight)
        } else {
            header.frame = NSRect(x: 0, y: Self.padding, width: width, height: Self.rowHeight)
            let below = Self.padding + Self.rowHeight
            separator.frame = NSRect(x: 12, y: below + Self.padding / 2, width: width - 24, height: 1)
            let visible = CGFloat(min(count, Self.maximumVisibleSteps))
            // Laid out at its open size even while closed: the card clips it,
            // so opening reveals it from the top as the row grows.
            list.frame = NSRect(x: 0, y: below + 1 + Self.padding, width: width, height: visible * Self.rowHeight)
        }
        let contentWidth = list.contentSize.width
        listContent.frame = NSRect(x: 0, y: 0, width: contentWidth, height: CGFloat(count) * Self.rowHeight)
        for (index, row) in rows.enumerated() where index < count {
            row.frame = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: contentWidth, height: Self.rowHeight)
        }
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { false }
}

// MARK: - Header

/// The group's header: a disclosure chevron, the summary, and what changed.
@MainActor
private final class GroupHeaderView: PressableRowView {
    private let chevron = DisclosureChevronView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let failureLabel = NSTextField(labelWithString: "")
    private let statLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        summaryLabel.font = .systemFont(ofSize: 13, weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        failureLabel.font = .systemFont(ofSize: 11, weight: .medium)
        failureLabel.textColor = .systemRed
        for label in [failureLabel, statLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [chevron, summaryLabel, spacer, failureLabel, statLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            chevron.widthAnchor.constraint(equalToConstant: 18),
            chevron.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(summary: String, stat: ToolStep.Stat?, failures: Int) {
        resetHighlight()
        summaryLabel.stringValue = summary
        toolTip = summary
        failureLabel.stringValue = failures == 0 ? "" : String(localized: "\(failures) failed")
        failureLabel.isHidden = failures == 0
        statLabel.attributedStringValue = ToolStepRowView.attributed(stat, outcome: .succeeded)
        statLabel.isHidden = stat == nil
        setAccessibilityLabel(summary)
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        chevron.setExpanded(expanded, animated: animated)
        setAccessibilityExpanded(expanded)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .disclosureTriangle }
}

/// A chevron that turns from pointing right to pointing down, about its own
/// centre, the way an outline's disclosure does. A sublayer, because a
/// layer-backed view's own layer turns about its corner.
@MainActor
private final class DisclosureChevronView: NSView {
    private let glyph = CALayer()
    private var isExpanded = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glyph.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        glyph.contentsGravity = .center
        layer?.addSublayer(glyph)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .secondaryLabelColor))
        let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        glyph.contentsScale = window?.backingScaleFactor ?? 2
        var rect = NSRect(origin: .zero, size: image?.size ?? .zero)
        glyph.contents = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.bounds = bounds
        glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        isExpanded = expanded
        let angle: CGFloat = expanded ? -.pi / 2 : 0
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || reduceMotion)
        CATransaction.setAnimationDuration(0.2)
        glyph.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        CATransaction.commit()
    }
}

// MARK: - List

/// The steps' scroll view. A list that fits never scrolls; one that doesn't
/// scrolls only while it can — at either end the wheel goes on to the
/// transcript, so reading past a card is never caught by it.
@MainActor
private final class StepListScrollView: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        contentView.drawsBackground = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func scrollWheel(with event: NSEvent) {
        let content = documentView?.frame.height ?? 0
        let visible = contentView.bounds
        let atTop = visible.minY <= 0
        let atBottom = visible.maxY >= content - 0.5
        let up = event.scrollingDeltaY > 0
        let passes =
            content <= visible.height || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            || (up && atTop) || (!up && atBottom)
        if passes {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

@MainActor
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SeparatorView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

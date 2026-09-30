import AppKit

/// What stands above a command's output and scrolls with it
/// (02-command.md "Layout"): what was meant, the status line, the command
/// card, the CLI's note on the exit code, and — where there is no output —
/// what stands there instead.
@MainActor
final class CommandHeaderView: NSView {
    /// Commands over this many lines fold behind *Show all N lines*.
    private static let foldedLines = 12

    private let summary: CommandSummary
    private var isExpanded = false

    private lazy var headingLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: summary.heading)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        label.isSelectable = true
        return label
    }()

    private lazy var statusRow: NSStackView = {
        var views: [NSView] = []
        if !summary.status.isEmpty {
            let label = NSTextField(labelWithString: "")
            label.attributedStringValue = summary.status.attributedString(
                font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)
            views.append(label)
        }
        if let warning = summary.warning {
            if !views.isEmpty { views.append(Self.separatorDot()) }
            views.append(Self.warningView(warning))
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.isHidden = views.isEmpty
        return stack
    }()

    private lazy var card: CommandCardView = {
        let card = CommandCardView()
        card.showAll = { [weak self] in
            self?.isExpanded = true
            self?.showCommand()
        }
        return card
    }()

    private lazy var stack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    init(summary: CommandSummary) {
        self.summary = summary
        super.init(frame: .zero)
        configureHierarchy()
        configureConstraints()
        showCommand()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureHierarchy() {
        addSubview(stack)
        stack.addArrangedSubview(headingLabel)
        stack.setCustomSpacing(2, after: headingLabel)
        stack.addArrangedSubview(statusRow)
        stack.setCustomSpacing(14, after: statusRow)
        stack.addArrangedSubview(card)
        stack.setCustomSpacing(16, after: card)
        for view in trailingViews() {
            stack.addArrangedSubview(view)
            stack.setCustomSpacing(10, after: view)
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomPadding),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
            headingLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        for view in stack.arrangedSubviews.dropFirst(3) {
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
    }

    /// Lines follow closely; a header with nothing after it leaves the
    /// page's own bottom margin.
    private var bottomPadding: CGFloat { summary.emptyNote == nil ? 6 : 28 }

    // MARK: - Command

    private func showCommand() {
        let (prefix, rest) = ShellHighlighter.splitDirectoryChange(summary.command)
        var lines = rest.components(separatedBy: "\n")
        var hidden = 0
        let total = lines.count + (prefix == nil ? 0 : 1)
        if !isExpanded, total > Self.foldedLines {
            hidden = total
            lines = Array(lines.prefix(Self.foldedLines - (prefix == nil ? 0 : 1)))
        }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let text = NSMutableAttributedString()
        if let prefix {
            text.append(
                NSAttributedString(
                    string: prefix + "\n", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        let body = lines.joined(separator: "\n")
        let start = text.length
        text.append(NSAttributedString(string: body, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        text.apply(ShellHighlighter.spans(in: body), at: start, size: 12)
        card.set(text, command: summary.command, hiddenTotal: hidden)
        invalidateIntrinsicContentSize()
    }

    // MARK: - Below the card

    /// The CLI's note, and what stands where the output would be.
    private func trailingViews() -> [NSView] {
        var views: [NSView] = []
        if let note = summary.note { views.append(Self.noteRow(note, symbol: "info.circle")) }
        if let path = summary.persistedPath, let note = summary.persistedNote {
            views.append(persistedRow(path, note: note))
        }
        if let empty = summary.emptyNote { views.append(emptyRow(empty)) }
        return views
    }

    private func emptyRow(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabelColor
        guard summary.isRunning else { return label }
        let tile = TileView()
        tile.tile = Tile(glyph: .tool(.command), state: .running)
        let row = NSStackView(views: [tile, label])
        row.spacing = 8
        return row
    }

    private func persistedRow(_ path: String, note: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: "")
        let text = NSMutableAttributedString(
            string: note + " ",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        text.append(
            NSAttributedString(
                string: path,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]))
        label.attributedStringValue = text
        label.isSelectable = true
        // A click hands the text to the field editor, which keeps these fonts only then.
        label.allowsEditingTextAttributes = true
        let open = PillButton(title: String(localized: "Open"))
        open.target = self
        open.action = #selector(openPersisted)
        let row = NSStackView(views: [Self.icon("info.circle"), label, open])
        row.spacing = 6
        row.alignment = .firstBaseline
        return row
    }

    @objc private func openPersisted() {
        guard let path = summary.persistedPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private static func icon(_ symbol: String) -> NSImageView {
        let image = NSImageView(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) ?? NSImage())
        image.contentTintColor = .secondaryLabelColor
        return image
    }

    private static func noteRow(_ text: String, symbol: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.isSelectable = true
        let row = NSStackView(views: [icon(symbol), label])
        row.spacing = 6
        row.alignment = .firstBaseline
        return row
    }

    private static func warningView(_ text: String) -> NSView {
        let image = NSImageView(
            image: NSImage(systemSymbolName: "exclamationmark.shield", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) ?? NSImage())
        image.contentTintColor = .systemOrange
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .systemOrange
        let row = NSStackView(views: [image, label])
        row.spacing = 3
        return row
    }

    private static func separatorDot() -> NSView {
        let label = NSTextField(labelWithString: "·")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        return label
    }
}

// MARK: - The card

/// The command in the code-card shape of the transcript: 6-pt radius, quiet
/// fill, `$` hanging in the left padding, copy on hover.
private final class CommandCardView: NSView {
    var showAll: (() -> Void)?

    private var command = ""

    private lazy var dollar: NSTextField = {
        let label = NSTextField(labelWithString: "$")
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var text: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.isSelectable = true
        // A click hands the text to the field editor, which keeps the
        // highlighted monospaced runs only then.
        label.allowsEditingTextAttributes = true
        label.lineBreakMode = .byCharWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var moreButton: NSButton = {
        let button = NSButton(title: "", target: self, action: #selector(expand))
        button.isBordered = false
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .controlAccentColor
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private lazy var copyButton: NSButton = {
        let button = NSButton(
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: String(localized: "Copy"))
                ?? NSImage(), target: self, action: #selector(copyCommand))
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .tertiaryLabelColor
        button.toolTip = String(localized: "Copy")
        button.alphaValue = 0
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private var moreHeight: NSLayoutConstraint?
    private var moreGap: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(dollar)
        addSubview(text)
        addSubview(moreButton)
        addSubview(copyButton)
        let more = moreButton.heightAnchor.constraint(equalToConstant: 0)
        let gap = moreButton.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 0)
        moreHeight = more
        moreGap = gap
        NSLayoutConstraint.activate([
            dollar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dollar.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            gap,
            moreButton.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            moreButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            more,
            copyButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            copyButton.widthAnchor.constraint(equalToConstant: 14),
            copyButton.heightAnchor.constraint(equalToConstant: 14),
        ])
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.tertiarySystemFill.cgColor
        }
    }

    func set(_ attributed: NSAttributedString, command: String, hiddenTotal: Int) {
        self.command = command
        text.attributedStringValue = attributed
        moreButton.isHidden = hiddenTotal == 0
        moreButton.title = hiddenTotal == 0 ? "" : String(localized: "Show all \(hiddenTotal) lines")
        // With nothing folded the button takes no room, and neither does its gap.
        moreHeight?.constant = hiddenTotal == 0 ? 0 : 14
        moreGap?.constant = hiddenTotal == 0 ? 0 : 4
    }

    override func mouseEntered(with event: NSEvent) {
        copyButton.alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        copyButton.alphaValue = 0
    }

    @objc private func expand() {
        showAll?()
    }

    @objc private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}

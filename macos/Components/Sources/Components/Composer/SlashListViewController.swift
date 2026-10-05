import AppKit
import DisplayModels

/// The command completion list (design 08 *Slash commands*): over the card — or
/// under it, in a New tab — one row per command, 28 pt at least: the name in
/// SF Mono 12, its argument hint in tertiary mono, the description in
/// secondary, wrapping to a second line rather than cut. The row the keyboard is
/// on is the table's selection, drawn as the wash; ↑ ↓ move it
/// (`moveSelection`), the composer completes it. The table never takes the
/// keyboard from the field; a click on a row is its action.
@MainActor
package final class SlashListViewController: NSViewController {
    /// A row was clicked.
    var onChoose: ((ComposerPresentation.Command) -> Void)?

    static let inset: CGFloat = 5
    static let minRowHeight: CGFloat = 28
    /// How many rows the list shows before it scrolls — at their own heights,
    /// so a wrapped description is never what pushes the last of them out.
    static let visibleRows = 8

    private(set) var commands: [ComposerPresentation.Command] = []
    private var width: CGFloat = 640

    private let scrollView = NSScrollView()
    private let table = NSTableView()
    /// Lays a command out to measure its row.
    private let prototype = SlashRowView()
    private let container = SlashContainerView()
    private lazy var heightConstraint = container.heightAnchor.constraint(
        equalToConstant: Self.minRowHeight + 2 * Self.inset)
    private lazy var widthConstraint = container.widthAnchor.constraint(equalToConstant: width)

    package override func loadView() {
        view = container
    }

    package override func viewDidLoad() {
        super.viewDidLoad()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("slash.column"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.allowsEmptySelection = false
        table.style = .plain
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.inset),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.inset),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.inset),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.inset),
            widthConstraint,
            heightConstraint,
        ])
    }

    // MARK: - Showing

    /// Lists `commands` at `width`. Keeps the selection on the same command
    /// when it is still there, else the first.
    package func configure(commands: [ComposerPresentation.Command], width: CGFloat) {
        loadViewIfNeeded()
        let selected = selectedCommand
        self.commands = commands
        self.width = width
        widthConstraint.constant = width
        table.reloadData()
        heightConstraint.constant = shownHeight
        let row = selected.flatMap { name in commands.firstIndex { $0.name == name.name } } ?? 0
        if !commands.isEmpty { select(row: row) }
    }

    /// The size the list wants.
    package var preferredSize: NSSize {
        loadViewIfNeeded()
        return NSSize(width: width, height: shownHeight)
    }

    /// The first `visibleRows` rows and the inset around them.
    private var shownHeight: CGFloat {
        commands.indices.prefix(Self.visibleRows).map { rowHeight(of: $0) }.reduce(0, +) + 2 * Self.inset
    }

    // MARK: - Selection

    var selectedCommand: ComposerPresentation.Command? {
        table.selectedRow >= 0 && table.selectedRow < commands.count ? commands[table.selectedRow] : nil
    }

    /// Moves the selection one row, stopping at the ends.
    func moveSelection(_ delta: Int) {
        guard !commands.isEmpty else { return }
        select(row: min(max(table.selectedRow + delta, 0), commands.count - 1))
    }

    private func select(row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked() {
        guard commands.indices.contains(table.clickedRow) else { return }
        onChoose?(commands[table.clickedRow])
    }

    // MARK: - Geometry

    private var rowWidth: CGFloat { width - 2 * Self.inset }

    private func rowHeight(of row: Int) -> CGFloat {
        prototype.configure(commands[row])
        return max(Self.minRowHeight, prototype.fittedHeight(rowWidth: rowWidth))
    }
}

extension SlashListViewController: NSTableViewDataSource, NSTableViewDelegate {
    package func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

    package func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight(of: row) }

    package func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("slash.row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SlashRowView ?? SlashRowView()
        cell.identifier = identifier
        cell.configure(commands[row])
        return cell
    }

    package func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SlashSelectionRowView()
    }
}

// MARK: - Views

/// The list's surface: the window's background with the popover radius.
private final class SlashContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CornerRadius.popover
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A row whose selection is the composer's wash with the row's corners.
private final class SlashSelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.composerSelection.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: CornerRadius.row, yRadius: CornerRadius.row).fill()
    }
}

/// One command: `/name`, its hint, its description.
private final class SlashRowView: NSTableCellView {
    private static let nameFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let hintFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let descriptionFont = NSFont.systemFont(ofSize: 12)
    private static let gap: CGFloat = 8
    static let rowPadding: CGFloat = 10
    /// The sheet's line: 12 pt on the page's 1.45.
    static let lineHeight: CGFloat = 17.4

    /// Half the line's height beyond the font's own.
    private static var halfLeading: CGFloat {
        (lineHeight - (descriptionFont.ascender - descriptionFont.descender + descriptionFont.leading)) / 2
    }

    private static var descriptionAttributes: [NSAttributedString.Key: Any] {
        let line = NSMutableParagraphStyle()
        line.minimumLineHeight = lineHeight
        line.maximumLineHeight = lineHeight
        return [.font: descriptionFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: line]
    }

    private let nameLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hintLabel.font = Self.hintFont
        hintLabel.textColor = .tertiaryLabelColor
        descriptionLabel.font = Self.descriptionFont
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.isSelectable = false
        for label in [nameLabel, hintLabel] {
            label.lineBreakMode = .byClipping
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        for view in [nameLabel, hintLabel, descriptionLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SlashRowView.rowPadding),
            nameLabel.firstBaselineAnchor.constraint(equalTo: descriptionLabel.firstBaselineAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: Self.gap),
            hintLabel.firstBaselineAnchor.constraint(equalTo: descriptionLabel.firstBaselineAnchor),
            descriptionLabel.leadingAnchor.constraint(equalTo: hintLabel.trailingAnchor, constant: Self.gap),
            descriptionLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -SlashRowView.rowPadding),
            // `.sl { padding: 6px 10px }` — less the half of the line's extra
            // height CSS puts above the words, which TextKit puts there whole.
            descriptionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6 - Self.halfLeading),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ command: ComposerPresentation.Command) {
        let name = NSMutableAttributedString(
            string: "/", attributes: [.font: Self.nameFont, .foregroundColor: NSColor.tertiaryLabelColor])
        name.append(
            NSAttributedString(
                string: command.name, attributes: [.font: Self.nameFont, .foregroundColor: NSColor.labelColor]))
        nameLabel.attributedStringValue = name
        hintLabel.stringValue = command.argumentHint
        hintLabel.isHidden = command.argumentHint.isEmpty
        descriptionLabel.attributedStringValue = NSAttributedString(
            string: command.description, attributes: Self.descriptionAttributes)
        setAccessibilityLabel("/\(command.name) \(command.argumentHint) \(command.description)")
    }

    /// The description wraps at the width the name and the hint leave it.
    override func layout() {
        super.layout()
        let width = descriptionLabel.frame.width
        if width > 0, descriptionLabel.preferredMaxLayoutWidth != width {
            descriptionLabel.preferredMaxLayoutWidth = width
            super.layout()
        }
    }

    /// The row's height at `rowWidth`: laid out, its description measured by
    /// its own cell at the width it gets, and the padding around it.
    func fittedHeight(rowWidth: CGFloat) -> CGFloat {
        frame = NSRect(x: 0, y: 0, width: rowWidth, height: 100)
        layoutSubtreeIfNeeded()
        let width = descriptionLabel.frame.width
        let text =
            descriptionLabel.cell?.cellSize(
                forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
            ).height ?? Self.lineHeight
        return ceil(text) + 12
    }
}

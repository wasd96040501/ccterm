import AppKit
import DisplayModels

/// The command completion list (design 08 *Slash commands*): over the card — or
/// under it, in a New tab — one row per command, 28 pt at least: the name in
/// SF Mono 12, its argument hint in tertiary mono, the description in
/// secondary, wrapping to a second line rather than cut. The row the keyboard is
/// on has the selection wash; ↑ ↓ move it (`moveSelection`), the composer
/// completes it. It draws what it is handed and reports a click.
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
    private let table = SlashTableView()
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
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = false
        table.style = .plain
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.onClick = { [weak self] row in self?.choose(row: row) }
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
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
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<commands.count), columnIndexes: IndexSet(integer: 0))
    }

    private func choose(row: Int) {
        guard commands.indices.contains(row) else { return }
        onChoose?(commands[row])
    }

    // MARK: - Geometry

    private var rowWidth: CGFloat { width - 2 * Self.inset }

    private func rowHeight(of row: Int) -> CGFloat {
        let command = commands[row]
        let lines = SlashRowView.descriptionHeight(of: command, rowWidth: rowWidth)
        return max(Self.minRowHeight, lines + 12)
    }
}

extension SlashListViewController: NSTableViewDataSource, NSTableViewDelegate {
    package func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

    package func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight(of: row) }

    package func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("slash.row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SlashRowView ?? SlashRowView()
        cell.identifier = identifier
        cell.configure(commands[row], rowWidth: rowWidth, isSelected: row == tableView.selectedRow)
        return cell
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

/// Sends a click on a row up; the keyboard stays with the field.
private final class SlashTableView: NSTableView {
    var onClick: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onClick?(row) }
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
    private var isSelected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CornerRadius.row
        layer?.cornerCurve = .continuous
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

    func configure(_ command: ComposerPresentation.Command, rowWidth: CGFloat, isSelected: Bool) {
        self.isSelected = isSelected
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
        descriptionLabel.preferredMaxLayoutWidth = Self.descriptionWidth(of: command, rowWidth: rowWidth)
        needsDisplay = true
        setAccessibilityLabel("/\(command.name) \(command.argumentHint) \(command.description)")
        setAccessibilitySelected(isSelected)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isSelected ? NSColor.composerSelection : .clear).cgColor
        }
    }

    /// The width the description has in its row: what the name and the hint leave.
    private static func descriptionWidth(of command: ComposerPresentation.Command, rowWidth: CGFloat) -> CGFloat {
        let name = ("/" + command.name as NSString).size(withAttributes: [.font: nameFont]).width
        var taken = SlashRowView.rowPadding * 2 + ceil(name) + gap + gap
        if !command.argumentHint.isEmpty {
            taken += ceil((command.argumentHint as NSString).size(withAttributes: [.font: hintFont]).width)
        }
        return max(80, rowWidth - taken)
    }

    /// How tall the description is at `rowWidth`.
    static func descriptionHeight(of command: ComposerPresentation.Command, rowWidth: CGFloat) -> CGFloat {
        let width = descriptionWidth(of: command, rowWidth: rowWidth)
        let rect = (command.description as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: descriptionAttributes)
        return ceil(rect.height)
    }
}

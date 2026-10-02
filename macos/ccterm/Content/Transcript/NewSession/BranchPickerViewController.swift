import AppKit

/// The branch popover (design 08 *The New view*), as Xcode's toolbar branch
/// picker: a filter field, focused, over the list — sections *Local* and
/// *Remote* under floating headers, 360 pt at most and then it scrolls. Typing
/// filters; ↩ takes the highlighted row, else the first match; typing `#327`
/// adds *Pull Request · #327*. A greyed row says why it can't be had.
///
/// It draws `BranchPickerModel`'s rows and reports a choice; the owner closes
/// the popover.
@MainActor
final class BranchPickerViewController: NSViewController {
    /// The choice, from a click or ↩.
    var onChoose: ((NewSessionDraft.Branch) -> Void)?

    private static let width: CGFloat = 300
    private static let maxListHeight: CGFloat = 360
    private static let filterHeight: CGFloat = 26
    /// The rows' insets inside the popover (the design's `.mscroll` padding).
    private static let inset: CGFloat = 5

    private let model: BranchPickerModel
    private var rows: [BranchPickerModel.Row] = []

    private lazy var searchField: NSSearchField = {
        let field = NSSearchField()
        field.placeholderString = String(localized: "Filter")
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .default
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(filterChanged(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    private lazy var tableView: BranchTableView = {
        let table = BranchTableView()
        let column = NSTableColumn(identifier: .branchColumn)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.floatsGroupRows = true
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        return table
    }()

    private lazy var scrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: Self.inset, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()

    private var scrollHeight: NSLayoutConstraint?

    init(model: BranchPickerModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = NSView()
        view.addSubview(searchField)
        view.addSubview(scrollView)
        let height = scrollView.heightAnchor.constraint(equalToConstant: 0)
        scrollHeight = height
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.width),
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.inset),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.inset),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.inset),
            searchField.heightAnchor.constraint(equalToConstant: Self.filterHeight),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Rows

    /// The text typed in the filter.
    var query: String {
        get { searchField.stringValue }
        set {
            searchField.stringValue = newValue
            reload()
        }
    }

    private func reload() {
        rows = model.rows(matching: query)
        tableView.reloadData()
        tableView.deselectAll(nil)
        scrollView.contentView.scroll(to: .zero)
        let content = rows.indices.reduce(CGFloat(0)) { $0 + rowHeight(at: $1) }
        let height = min(content + Self.inset, Self.maxListHeight)
        scrollHeight?.constant = height
        preferredContentSize = NSSize(width: Self.width, height: Self.inset + Self.filterHeight + 4 + height)
    }

    private func rowHeight(at row: Int) -> CGFloat {
        switch rows[row] {
        case .header: 20
        case .branch(let item): item.subtitle == nil ? 22 : 36
        case .pullRequest: 36
        case .empty: 22
        }
    }

    private func isSelectable(_ row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].choice != nil
    }

    private func choose(row: Int) {
        guard isSelectable(row), let choice = rows[row].choice else { return }
        onChoose?(choice)
    }

    @objc private func filterChanged(_ sender: NSSearchField) {
        reload()
    }

    @objc private func rowClicked(_ sender: NSTableView) {
        choose(row: sender.clickedRow)
    }

    /// ↑ / ↓: the next row that can be chosen.
    private func moveSelection(by step: Int) {
        var row = tableView.selectedRow
        repeat {
            row = row < 0 ? (step > 0 ? 0 : rows.count - 1) : row + step
            if !rows.indices.contains(row) { return }
        } while !isSelectable(row)
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// ↩: the highlighted row, else the first match.
    private func commit() {
        if tableView.selectedRow >= 0 {
            choose(row: tableView.selectedRow)
        } else if let choice = model.firstChoice(matching: query) {
            onChoose?(choice)
        }
    }
}

// MARK: - Table

extension BranchPickerViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight(at: row) }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { isSelectable(row) }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if case .header = rows[row] { return BranchHeaderRowView() }
        return BranchRowView(inset: Self.inset)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell =
            tableView.makeView(withIdentifier: .branchCell, owner: self) as? BranchCellView
            ?? BranchCellView(identifier: .branchCell)
        cell.configure(with: rows[row], inset: Self.inset)
        return cell
    }
}

extension BranchPickerViewController: NSSearchFieldDelegate, NSControlTextEditingDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)): commit()
        default: return false
        }
        return true
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let branchColumn = NSUserInterfaceItemIdentifier("branchColumn")
    fileprivate static let branchCell = NSUserInterfaceItemIdentifier("branchCell")
}

// MARK: - Views

/// A table whose rows highlight under the pointer, as a menu's do.
@MainActor
private final class BranchTableView: NSTableView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, delegate?.tableView?(self, shouldSelectRow: row) ?? true else {
            deselectAll(nil)
            return
        }
        if selectedRow != row { selectRowIndexes([row], byExtendingSelection: false) }
    }

    override func mouseExited(with event: NSEvent) {
        deselectAll(nil)
    }

    override var acceptsFirstResponder: Bool { false }
}

/// A choosable row: the accent highlight a menu draws, inset 5 pt.
@MainActor
private final class BranchRowView: NSTableRowView {
    private let inset: CGFloat

    init(inset: CGFloat) {
        self.inset = inset
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: 0), xRadius: 5, yRadius: 5).fill()
    }
}

/// A section header; floating, it covers what scrolls under it.
@MainActor
private final class BranchHeaderRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        guard isFloating else { return }
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

/// A row's content: the check, the name, the line under it.
@MainActor
private final class BranchCellView: NSTableCellView {
    private let check = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private var isHeader = false
    private var isDisabled = false

    /// Text turns white on the accent highlight.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyInk() }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.lineBreakMode = .byTruncatingTail
        for view in [check, label, subtitle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            check.widthAnchor.constraint(equalToConstant: 14),
            check.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 29),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            subtitle.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: label.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(with row: BranchPickerModel.Row, inset: CGFloat) {
        isHeader = false
        isDisabled = false
        check.isHidden = true
        subtitle.isHidden = true
        label.font = .systemFont(ofSize: 13)
        switch row {
        case .header(let title):
            isHeader = true
            label.stringValue = title
            label.font = .systemFont(ofSize: 11, weight: .semibold)
        case .branch(let item):
            label.stringValue = item.name
            check.isHidden = !item.isChosen
            subtitle.stringValue = item.subtitle ?? ""
            subtitle.isHidden = item.subtitle == nil
            isDisabled = !item.isEnabled
        case .pullRequest(let number, let text, let isChosen):
            label.stringValue = "#\(number)"
            check.isHidden = !isChosen
            subtitle.stringValue = text
            subtitle.isHidden = false
        case .empty(let text):
            label.stringValue = text
            isDisabled = true
        }
        applyInk()
        setAccessibilityLabel(label.stringValue)
    }

    private func applyInk() {
        let emphasized = backgroundStyle == .emphasized
        if isHeader {
            label.textColor = .tertiaryLabelColor
        } else if isDisabled {
            label.textColor = .tertiaryLabelColor
        } else {
            label.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        }
        subtitle.textColor =
            isDisabled
            ? .tertiaryLabelColor : (emphasized ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor)
        check.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
    }
}

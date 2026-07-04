import AppKit

extension NSUserInterfaceItemIdentifier {
    /// Reuse identifier for the folder-filter picker's single-column
    /// `NSTableView` row. Centralized so registration and dequeue
    /// reference the same constant — a typo becomes a compile error
    /// instead of a silent `nil` view.
    static let folderFilterRow = NSUserInterfaceItemIdentifier("ccterm.folderFilterRow")
}

/// AppKit popover content for `ArchiveFilterButton`. One row per
/// `ArchivedFolder`, plus a leading "All Folders" row that clears the
/// filter. Selection reports a `String?` up (`nil` for "All Folders",
/// otherwise `ArchivedFolder.path`) via the `onSelect` closure the
/// button injects.
///
/// The picker owns none of the state — options + selection come in
/// through the initializer, and the callback delivers the user's pick
/// to the button. Clicking a row commits and the button dismisses the
/// popover.
@MainActor
final class FolderFilterPickerViewController: NSViewController {

    private let options: [SessionManager.ArchivedFolder]
    private let selectedPath: String?
    private let onSelect: (String?) -> Void

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ccterm.folderFilterCol"))

    private static let rowHeight: CGFloat = 32
    private static let popoverWidth: CGFloat = 260
    private static let popoverMaxHeight: CGFloat = 320

    init(
        options: [SessionManager.ArchivedFolder],
        selectedPath: String?,
        onSelect: @escaping (String?) -> Void
    ) {
        self.options = options
        self.selectedPath = selectedPath
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false

        column.isEditable = false
        column.resizingMask = [.autoresizingMask]

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.style = .plain
        tableView.backgroundColor = .clear

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true

        host.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: host.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.dataSource = self
        tableView.delegate = self
        // Highlight the currently-selected row (if any) at first display
        // so the user sees the current filter without any interaction.
        if let index = indexForSelectedPath() {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    override var preferredContentSize: NSSize {
        get {
            let rows = options.count + 1  // +1 for "All Folders"
            let height = min(Self.popoverMaxHeight, CGFloat(rows) * Self.rowHeight)
            return NSSize(width: Self.popoverWidth, height: max(Self.rowHeight, height))
        }
        set { super.preferredContentSize = newValue }
    }

    /// Number of rows including the leading "All Folders" row.
    fileprivate var totalRowCount: Int { options.count + 1 }

    /// Convert a row index into its selection value (`nil` for the
    /// "All Folders" row, an `ArchivedFolder.path` otherwise).
    fileprivate func pathForRow(_ row: Int) -> String? {
        guard row > 0, row - 1 < options.count else { return nil }
        return options[row - 1].path
    }

    /// Display title for a row.
    fileprivate func titleForRow(_ row: Int) -> String {
        row == 0 ? String(localized: "All Folders") : options[row - 1].name
    }

    /// Whether a row's path matches the current filter — drives the
    /// trailing checkmark. `nil` selection matches only the "All
    /// Folders" row.
    fileprivate func isSelectedRow(_ row: Int) -> Bool {
        pathForRow(row) == selectedPath
    }

    private func indexForSelectedPath() -> Int? {
        if selectedPath == nil { return 0 }
        return options.firstIndex(where: { $0.path == selectedPath }).map { $0 + 1 }
    }
}

extension FolderFilterPickerViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { totalRowCount }
}

extension FolderFilterPickerViewController: NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let cell: FolderFilterRowView
        if let recycled = tableView.makeView(withIdentifier: .folderFilterRow, owner: nil)
            as? FolderFilterRowView
        {
            cell = recycled
        } else {
            cell = FolderFilterRowView()
            cell.identifier = .folderFilterRow
        }
        cell.configure(title: titleForRow(row), isSelected: isSelectedRow(row))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        onSelect(pathForRow(row))
    }
}

/// One row in the folder-filter picker. Leading folder icon + title,
/// with an optional trailing checkmark reflecting the current filter.
/// Pure display — `configure(title:isSelected:)` is idempotent and
/// rewrites both fields on every reuse.
@MainActor
private final class FolderFilterRowView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
        configureConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configureHierarchy() {
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(
            systemSymbolName: "folder", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = NSFont.systemFont(ofSize: 13)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        title.cell?.wraps = false
        title.cell?.isScrollable = false

        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.image = NSImage(
            systemSymbolName: "checkmark", accessibilityDescription: nil)
        checkmark.contentTintColor = .controlAccentColor
        checkmark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)

        addSubview(icon)
        addSubview(title)
        addSubview(checkmark)
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: checkmark.leadingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),

            checkmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 14),
            checkmark.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    func configure(title: String, isSelected: Bool) {
        self.title.stringValue = title
        checkmark.isHidden = !isSelected
    }
}

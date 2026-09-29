import AppKit

/// The Settings window's pane list: a source list, one row per
/// ``SettingsPane`` — an icon and a title.
@MainActor
final class SettingsSidebarViewController: NSViewController {
    weak var delegate: SettingsSidebarViewControllerDelegate?

    /// Set while the selection follows the history, so it isn't reported back.
    private var isSelectingProgrammatically = false

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private lazy var tableView: NSTableView = {
        let table = NSTableView()
        table.style = .sourceList
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsEmptySelection = false
        let column = NSTableColumn(identifier: .settingsPaneColumn)
        column.isEditable = false
        table.addTableColumn(column)
        return table
    }()

    private lazy var scrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        return scroll
    }()

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureConstraints()
        tableView.dataSource = self
        tableView.delegate = self
    }

    private func configureHierarchy() {
        scrollView.documentView = tableView
        view.addSubview(scrollView)
    }

    private func configureConstraints() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// Selects `pane`'s row without reporting it.
    func select(_ pane: SettingsPane) {
        loadViewIfNeeded()
        isSelectingProgrammatically = true
        tableView.selectRowIndexes([pane.rawValue], byExtendingSelection: false)
        isSelectingProgrammatically = false
    }
}

extension SettingsSidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        SettingsPane.allCases.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let pane = SettingsPane.allCases[row]
        let cell =
            tableView.makeView(withIdentifier: .settingsPaneCell, owner: nil) as? NSTableCellView
            ?? Self.makeCell()
        cell.textField?.stringValue = pane.title
        cell.imageView?.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingProgrammatically, let pane = SettingsPane(rawValue: tableView.selectedRow) else { return }
        delegate?.settingsSidebar(self, didSelect: pane)
    }

    private static func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = .settingsPaneCell
        let image = NSImageView()
        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        for view in [image, title] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = image
        cell.textField = title
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 9),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let settingsPaneColumn = NSUserInterfaceItemIdentifier("ccterm.settings.pane")
    fileprivate static let settingsPaneCell = NSUserInterfaceItemIdentifier("ccterm.settings.paneCell")
}

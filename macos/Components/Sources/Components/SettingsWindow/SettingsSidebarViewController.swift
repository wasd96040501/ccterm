import AppKit

/// The Settings window's pane list: a source list, one row per pane — an
/// icon and a title.
@MainActor
final class SettingsSidebarViewController: NSViewController {
    weak var delegate: SettingsSidebarViewControllerDelegate?

    private let panes: [SettingsSplitViewController.Pane]
    /// Set while the selection follows the history, so it isn't reported back.
    private var isSelectingProgrammatically = false

    init(panes: [SettingsSplitViewController.Pane]) {
        self.panes = panes
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

    /// Selects the row of the pane at `index` without reporting it.
    func select(_ index: Int) {
        loadViewIfNeeded()
        isSelectingProgrammatically = true
        tableView.selectRowIndexes([index], byExtendingSelection: false)
        isSelectingProgrammatically = false
    }
}

extension SettingsSidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        panes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell =
            tableView.makeView(withIdentifier: .settingsPaneCell, owner: nil) as? Cell
            ?? Cell()
        cell.configure(with: panes[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingProgrammatically, panes.indices.contains(tableView.selectedRow) else { return }
        delegate?.settingsSidebar(self, didSelect: tableView.selectedRow)
    }

    /// A pane's row as Xcode's Settings draws it: a 17-point glyph in the
    /// accent colour 10.5 into the selection, the title 36.5 in; on the
    /// selection the glyph turns white and the title semibold.
    private final class Cell: NSTableCellView {
        private let glyph = NSImageView()
        private let title = NSTextField(labelWithString: "")

        init() {
            super.init(frame: .zero)
            identifier = .settingsPaneCell
            title.lineBreakMode = .byTruncatingTail
            title.font = .systemFont(ofSize: 13)
            glyph.imageScaling = .scaleProportionallyDown
            for view in [glyph, title] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            imageView = glyph
            textField = title
            // The cell sits 6 into the row's selection.
            NSLayoutConstraint.activate([
                glyph.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 13),
                glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
                title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30.5),
                title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                title.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        func configure(with pane: SettingsSplitViewController.Pane) {
            title.stringValue = pane.title
            glyph.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            updateEmphasis()
        }

        override var backgroundStyle: NSView.BackgroundStyle {
            didSet { updateEmphasis() }
        }

        private func updateEmphasis() {
            let selected = backgroundStyle == .emphasized
            glyph.contentTintColor = selected ? .white : .controlAccentColor
            title.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let settingsPaneColumn = NSUserInterfaceItemIdentifier("ccterm.settings.pane")
    fileprivate static let settingsPaneCell = NSUserInterfaceItemIdentifier("ccterm.settings.paneCell")
}

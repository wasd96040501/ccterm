import AppKit

/// An account's environment variables as a list inside its form group: a
/// checkbox, the name and the value per row, + and − underneath as System
/// Settings' lists have. Click selects, a second click edits, Tab moves from
/// name to value, Space toggles, Delete removes.
@MainActor
final class EnvironmentVariablesViewController: NSViewController {
    weak var delegate: EnvironmentVariablesViewControllerDelegate?

    private var rows: [EnvironmentRow] = []

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private lazy var tableView: NSTableView = {
        let table = NSTableView()
        table.style = .plain
        table.rowSizeStyle = .custom
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = false
        for column in [NSUserInterfaceItemIdentifier.envEnabled, .envName, .envValue, .envWarning] {
            table.addTableColumn(NSTableColumn(identifier: column))
        }
        return table
    }()

    private lazy var scrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }()

    private lazy var addRemove: NSSegmentedControl = {
        let control = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "Add Variable"))!,
                NSImage(systemSymbolName: "minus", accessibilityDescription: String(localized: "Remove Variable"))!,
            ],
            trackingMode: .momentary, target: self, action: #selector(addOrRemove(_:)))
        control.segmentStyle = .smallSquare
        return control
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
        for subview in [scrollView, addRemove] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 156),
            addRemove.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 4),
            addRemove.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            addRemove.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
        ])
    }

    /// Shows `rows`, keeping the selection where it was.
    func configure(with rows: [EnvironmentRow]) {
        self.rows = rows
        tableView.reloadData()
    }

    @objc private func addOrRemove(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            guard let index = delegate?.environmentVariablesDidAdd(self) else { return }
            tableView.selectRowIndexes([index], byExtendingSelection: false)
            tableView.editColumn(1, row: index, with: nil, select: true)
        } else if tableView.selectedRow >= 0 {
            delegate?.environmentVariables(self, didRemoveAt: tableView.selectedRow)
        }
    }
}

extension EnvironmentVariablesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Skeleton cells; the measured list lands with the sheet.
        let label = NSTextField(labelWithString: "")
        switch tableColumn?.identifier {
        case .envName?: label.stringValue = rows[row].name
        case .envValue?: label.stringValue = rows[row].displayValue
        default: break
        }
        return label
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let envEnabled = NSUserInterfaceItemIdentifier("ccterm.env.enabled")
    fileprivate static let envName = NSUserInterfaceItemIdentifier("ccterm.env.name")
    fileprivate static let envValue = NSUserInterfaceItemIdentifier("ccterm.env.value")
    fileprivate static let envWarning = NSUserInterfaceItemIdentifier("ccterm.env.warning")
}

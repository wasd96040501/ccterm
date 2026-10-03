import AppKit
import Components

/// An account's environment variables as a list inside its form group: a
/// header, a checkbox, the name and the value per row, and + and −
/// underneath as System Settings' lists have. Click selects, a second click
/// or a double click edits, Tab moves from name to value, Return commits,
/// Escape reverts, Space toggles, Delete removes. A row left with neither a
/// name nor a value goes away.
///
/// Shows the rows it is configured with; every edit goes to the delegate,
/// and the next rows show its outcome.
@MainActor
final class EnvironmentVariablesViewController: NSViewController {
    weak var delegate: EnvironmentVariablesViewControllerDelegate?

    private var rows: [EnvironmentRow] = []
    /// What to select, and which field to edit, once the rows it waits for
    /// arrive — after + or −.
    private var pending: (row: Int, edit: Bool)?

    /// The list's height: header 28, rows 128, bar 28.
    static let height: CGFloat = 184

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private lazy var header = HeaderView()

    private lazy var tableView: TableView = {
        let table = TableView()
        table.style = .plain
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.rowHeight = 24
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.gridStyleMask = []
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: .environmentVariable)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        return table
    }()

    private lazy var scrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        return scroll
    }()

    private lazy var emptyLabel: NSTextField = {
        let text = NSMutableAttributedString(
            string: String(localized: "No Variables") + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        text.append(
            NSAttributedString(
                string: String(localized: "Click + or paste to add."),
                attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = 18
        paragraph.maximumLineHeight = 18
        text.addAttributes(
            [.paragraphStyle: paragraph, .foregroundColor: NSColor.tertiaryLabelColor],
            range: NSRange(location: 0, length: text.length))
        let label = NSTextField(labelWithAttributedString: text)
        label.maximumNumberOfLines = 2
        return label
    }()

    private lazy var bar = BarView()

    private lazy var addButton = ListBarButton(
        symbol: "plus", label: String(localized: "Add Variable"), target: self, action: #selector(add(_:)))
    private lazy var removeButton = ListBarButton(
        symbol: "minus", label: String(localized: "Remove Variable"), target: self, action: #selector(remove(_:)))
    private let divider = ListBarDividerView()

    private lazy var hintLabel: NSTextField = {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let template = String(localized: "Paste %@ lines or a command")
        let parts = template.components(separatedBy: "%@")
        let text = NSMutableAttributedString(string: parts.first ?? "", attributes: base)
        var code = base
        code[.font] = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        text.append(NSAttributedString(string: "KEY=value", attributes: code))
        text.append(NSAttributedString(string: parts.dropFirst().joined(), attributes: base))
        return NSTextField(labelWithAttributedString: text)
    }()

    override func loadView() {
        view = NSView()
        configureHierarchy()
        configureConstraints()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.onToggle = { [weak self] in self?.toggleSelected() }
        tableView.onDelete = { [weak self] in self?.remove(nil) }
        tableView.onEdit = { [weak self] in self?.editSelected() }
        updateChrome()
    }

    private func configureHierarchy() {
        scrollView.documentView = tableView
        for subview in [header, scrollView, emptyLabel, bar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        for subview in [addButton, divider, removeButton, hintLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(subview)
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: Self.height),
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            scrollView.heightAnchor.constraint(equalToConstant: 128),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            bar.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            addButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 4),
            divider.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 3),
            removeButton.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 3),
            divider.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            addButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: 0.5),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -4),
            hintLabel.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
        ])
    }

    /// The list itself, for a sheet to open focused on without a field.
    var initialFirstResponder: NSView { tableView }

    /// Shows `rows`. The same number of rows updates the rows in place, so
    /// a field being edited keeps its caret; otherwise the list reloads and
    /// selects what + or − left pending.
    func configure(with rows: [EnvironmentRow]) {
        let reload = rows.count != self.rows.count
        self.rows = rows
        if reload {
            let selected = tableView.selectedRow
            tableView.reloadData()
            let target = pending?.row ?? min(selected, rows.count - 1)
            if target >= 0, target < rows.count {
                tableView.selectRowIndexes([target], byExtendingSelection: false)
                tableView.scrollRowToVisible(target)
                if pending?.edit == true { edit(row: target, value: false) }
            }
            pending = nil
        } else {
            tableView.enumerateAvailableRowViews { rowView, row in
                guard row < rows.count, let cell = rowView.view(atColumn: 0) as? EnvironmentVariableCellView else {
                    return
                }
                cell.configure(with: rows[row])
            }
        }
        updateChrome()
    }

    private func updateChrome() {
        emptyLabel.isHidden = !rows.isEmpty
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    // MARK: - Editing

    private func edit(row: Int, value: Bool) {
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? EnvironmentVariableCellView
        else { return }
        view.window?.makeFirstResponder(value ? cell.valueField : cell.nameField)
    }

    private func editSelected() {
        guard tableView.selectedRow >= 0 else { return }
        edit(row: tableView.selectedRow, value: true)
    }

    private func toggleSelected() {
        guard tableView.selectedRow >= 0 else { return }
        delegate?.environmentVariables(self, didToggleAt: tableView.selectedRow)
    }

    @objc private func add(_ sender: Any?) {
        view.window?.makeFirstResponder(tableView)
        guard let index = delegate?.environmentVariablesDidAdd(self) else { return }
        pending = (index, true)
    }

    @objc private func remove(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        pending = (min(row, rows.count - 2), false)
        delegate?.environmentVariables(self, didRemoveAt: row)
    }

    @objc private func toggle(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0 else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        view.window?.makeFirstResponder(tableView)
        delegate?.environmentVariables(self, didToggleAt: row)
    }

    /// A double click edits the field under the pointer.
    @objc private func doubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, let event = NSApp.currentEvent,
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? EnvironmentVariableCellView
        else { return }
        let point = cell.convert(event.locationInWindow, from: nil)
        guard point.x > 30 else { return }
        edit(row: row, value: point.x >= cell.valueField.frame.minX - 2)
    }

}

extension EnvironmentVariablesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell =
            tableView.makeView(withIdentifier: .environmentVariable, owner: nil) as? EnvironmentVariableCellView
            ?? makeCell()
        cell.configure(with: rows[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateChrome()
    }

    private func makeCell() -> EnvironmentVariableCellView {
        let cell = EnvironmentVariableCellView()
        cell.identifier = .environmentVariable
        cell.checkbox.target = self
        cell.checkbox.action = #selector(toggle(_:))
        for field in [cell.nameField, cell.valueField] {
            field.delegate = self
        }
        cell.valueField.editingValue = { [weak self, weak cell] in
            guard let self, let cell else { return nil }
            let row = tableView.row(for: cell)
            return row >= 0 ? delegate?.environmentVariables(self, valueAt: row) : nil
        }
        return cell
    }
}

extension EnvironmentVariablesViewController: NSTextFieldDelegate {
    /// Return commits and hands focus back to the list; Tab from the name
    /// moves on to the value; Escape puts the field back as it was.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let field = control as? EnvironmentVariableCellView.Field else { return false }
        let row = tableView.row(for: field)
        switch commandSelector {
        // A field editor binds Escape to `complete:`.
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            _ = field.abortEditing()
            if row >= 0, row < rows.count {
                (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? EnvironmentVariableCellView)?
                    .configure(with: rows[row])
            }
            view.window?.makeFirstResponder(tableView)
            removeIfBlank(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            view.window?.makeFirstResponder(tableView)
            return true
        case #selector(NSResponder.insertTab(_:)):
            guard let cell = field.superview as? EnvironmentVariableCellView, field === cell.nameField else {
                return false
            }
            view.window?.makeFirstResponder(cell.valueField)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? EnvironmentVariableCellView.Field,
            let cell = field.superview as? EnvironmentVariableCellView
        else { return }
        let row = tableView.row(for: cell)
        guard row >= 0 else { return }
        if field === cell.nameField {
            delegate?.environmentVariables(self, didSetName: field.stringValue, at: row)
        } else {
            delegate?.environmentVariables(self, didSetValue: field.stringValue, at: row)
        }
        // Not while focus moves on to the row's other field.
        if cell.nameField.currentEditor() == nil, cell.valueField.currentEditor() == nil {
            removeIfBlank(
                row, name: cell.nameField.stringValue, value: field === cell.valueField ? field.stringValue : nil)
        }
    }

    /// A row with neither a name nor a value is dropped when editing ends.
    private func removeIfBlank(_ row: Int, name: String? = nil, value: String? = nil) {
        guard row >= 0, row < rows.count else { return }
        let name = name ?? rows[row].name
        let value = value ?? delegate?.environmentVariables(self, valueAt: row) ?? ""
        guard name.isEmpty, value.isEmpty else { return }
        pending = (min(row, rows.count - 2), false)
        delegate?.environmentVariables(self, didRemoveAt: row)
    }
}

extension EnvironmentVariablesViewController {
    /// The list's table: Space toggles the selected row, Delete removes it,
    /// Return edits its value.
    private final class TableView: NSTableView {
        var onToggle: (() -> Void)?
        var onDelete: (() -> Void)?
        var onEdit: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            switch event.charactersIgnoringModifiers {
            case " ": onToggle?()
            case "\u{7f}", String(UnicodeScalar(NSDeleteFunctionKey)!): onDelete?()
            case "\r", "\u{3}": onEdit?()
            // The table would swallow Escape; the sheet around it cancels.
            case "\u{1b}": _ = nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: self)
            default: super.keyDown(with: event)
            }
        }
    }

    /// A row's selection: rounded 6, the accent while the list has focus,
    /// a grey fill otherwise; none while one of its fields is edited.
    private final class RowView: NSTableRowView {
        override func drawSelection(in dirtyRect: NSRect) {
            if let editor = window?.firstResponder as? NSView, editor.isDescendant(of: self) { return }
            let color: NSColor = isEmphasized ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.12)
            color.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }

    /// “Name” and “Value” over their columns, with a hairline under them.
    private final class HeaderView: NSView {
        private let nameLabel = NSTextField(labelWithString: String(localized: "Name"))
        private let valueLabel = NSTextField(labelWithString: String(localized: "Value"))
        private let hairline = FormHairlineView()

        override init(frame: NSRect) {
            super.init(frame: frame)
            let columns = [NSLayoutGuide(), NSLayoutGuide()]
            for guide in columns { addLayoutGuide(guide) }
            for label in [nameLabel, valueLabel] {
                label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
            }
            for view in [nameLabel, valueLabel, hairline] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                columns[0].leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
                columns[1].leadingAnchor.constraint(equalTo: columns[0].trailingAnchor),
                columns[1].trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(22 + 10)),
                columns[0].widthAnchor.constraint(equalTo: columns[1].widthAnchor, multiplier: 1.6),
                nameLabel.leadingAnchor.constraint(equalTo: columns[0].leadingAnchor, constant: 6),
                valueLabel.leadingAnchor.constraint(equalTo: columns[1].leadingAnchor, constant: 6),
                nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
                valueLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
                hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
                hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
                hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    }

    /// The bar under the rows, with a hairline over it.
    private final class BarView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            let hairline = FormHairlineView()
            hairline.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hairline)
            NSLayoutConstraint.activate([
                hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
                hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
                hairline.topAnchor.constraint(equalTo: topAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let environmentVariable = NSUserInterfaceItemIdentifier("ccterm.environmentVariable")
}

import AppKit

/// The one menu every pop-up of the composer and the New view is — Model,
/// Effort, Mode, the folder and the branch — drawn to the design's menu
/// (design 08 *Menus are popovers*, preview-live.css *Menus and the model
/// panel*) inside the system popover `MenuPanel` opens: rows 10 in from the
/// popover's edges and 10 round, concentric with its 20; a section head in
/// 11-pt semibold tertiary; items with a check, a 16-pt glyph, a title, a
/// subtitle under it and a trailing key, glyph or switch; the accent under the
/// pointer; greyed items with their reason; hairlines between groups; a
/// capsule filter field over a list that keeps one height while it is open,
/// each account's head sticking to its top and a line in its middle when
/// nothing matches; what follows under the scroll, always in view.
///
/// Manners as `NSMenu`'s: the pointer selects, a release over an item chooses
/// it, ↑ ↓ move over what can be chosen, ↩ chooses, ⎋ closes, typing selects
/// by title — or, with a filter field, types into it. `MenuPanel` puts it on
/// screen; the owner hands it a `MenuContent` and hears choices through the
/// delegate.
@MainActor
public final class MenuPanelViewController: NSViewController {
    weak var delegate: MenuPanelViewControllerDelegate?

    private(set) var content = MenuContent(rows: [])
    private var width: CGFloat { content.width }

    private let filterField = MenuFilterField()
    private let scrollView = OverlayScrollView()
    private let table = MenuTableView()
    /// The head of the account section the list's top is in, over the list.
    private let stickyHeader = MenuAccountCell()
    private let footerSeparator = MenuHairline()
    private let footer = NSStackView()
    private var footerItems: [MenuContent.Item] = []
    /// What the list says in its middle when it has no rows.
    private let emptyLabel = NSTextField(labelWithString: "")

    private lazy var filterHeight = filterField.heightAnchor.constraint(equalToConstant: 0)
    private lazy var listTop = scrollView.topAnchor.constraint(equalTo: view.topAnchor)
    private lazy var listHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
    private lazy var viewWidth = view.widthAnchor.constraint(equalToConstant: 240)

    public override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// A plain view: the popover around it draws the material and the shape.
    public override func loadView() {
        view = NSView()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureConstraints()
        apply()
    }

    private func configureHierarchy() {
        let column = NSTableColumn(identifier: .menuColumn)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        // The row view draws the highlight itself: inset, at the row radius.
        table.selectionHighlightStyle = .none
        table.floatsGroupRows = false
        table.allowsTypeSelect = true
        table.allowsEmptySelection = true
        table.style = .plain
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.onActivate = { [weak self] row in self?.activate(row: row) }
        table.onCancel = { [weak self] in self?.cancel() }
        table.isSelectable = { [weak self] row in self?.isSelectable(row: row) ?? false }
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(listDidScroll), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        stickyHeader.setAccessibilityElement(false)
        stickyHeader.isHidden = true
        filterField.field.delegate = self
        footer.orientation = .vertical
        footer.spacing = 0
        footer.alignment = .width
        footer.edgeInsets = NSEdgeInsets(
            top: MenuMetrics.footerTop, left: 0, bottom: MenuMetrics.inset, right: 0)
        emptyLabel.font = MenuMetrics.titleFont
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        for subview in [filterField, scrollView, footerSeparator, footer, emptyLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // Placed by frame on every scroll, over the list.
        view.addSubview(stickyHeader, positioned: .above, relativeTo: scrollView)
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            viewWidth,
            filterField.topAnchor.constraint(equalTo: view.topAnchor, constant: MenuMetrics.filterInset),
            filterField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: MenuMetrics.filterInset),
            filterField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -MenuMetrics.filterInset),
            listTop,
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            listHeight,
            footerSeparator.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerSeparator.heightAnchor.constraint(equalToConstant: 0.5),
            footer.topAnchor.constraint(equalTo: footerSeparator.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            // In the middle of the list's padded box (`.mempty`).
            emptyLabel.centerYAnchor.constraint(
                equalTo: scrollView.centerYAnchor, constant: (MenuMetrics.filterGap - MenuMetrics.inset) / 2),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: MenuMetrics.inset),
        ])
    }

    // MARK: - Showing

    /// Shows `content`. What is selected (by item id) and where the list is
    /// scrolled stay.
    public func configure(with content: MenuContent) {
        self.content = content
        guard isViewLoaded else { return }
        apply()
    }

    private func apply() {
        let selected = selectedItemID
        let offset = scrollView.contentView.bounds.origin
        viewWidth.constant = width
        let hasFilter = content.filter != nil
        filterField.isHidden = !hasFilter
        if let filter = content.filter {
            filterField.placeholder = filter.placeholder
            if filterField.text != filter.text { filterField.text = filter.text }
        }
        // Under the filter, its rows 3 down and scrolling up to it; a list of
        // accounts at the top, its heads sticking there; any other 10 in.
        listTop.constant =
            hasFilter
            ? MenuMetrics.filterInset + MenuFilterField.height
            : (content.hasAccountHeads ? 0 : MenuMetrics.inset)
        scrollView.contentInsets = NSEdgeInsets(
            top: listPaddingTop, left: 0, bottom: MenuMetrics.inset, right: 0)
        emptyLabel.stringValue = content.emptyText ?? ""
        emptyLabel.isHidden = !content.rows.isEmpty || content.emptyText == nil
        table.reloadData()
        configureFooter()
        resize()
        scrollView.contentView.scroll(to: offset)
        placeStickyHeader()
        // A menu at rest highlights nothing; ↩ in the filter takes the first match.
        if let selected, let row = rowIndex(ofItem: selected) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    private func configureFooter() {
        footer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        footerItems = []
        let hasFooter = !content.footer.isEmpty
        footer.isHidden = !hasFooter
        footerSeparator.isHidden = !hasFooter
        for row in content.footer {
            let cell = MenuFooterRow(row: row, glyphColumn: content.hasGlyphColumn)
            cell.onChoose = { [weak self] item in
                guard let self else { return }
                delegate?.menuPanelViewController(self, didChoose: item)
            }
            cell.heightAnchor.constraint(equalToConstant: MenuMetrics.height(of: row, width: width, content: content))
                .isActive = true
            footer.addArrangedSubview(cell)
        }
    }

    /// The popover's one size: the filter, the list at its one height, the
    /// footer. The same for every content a menu shows while it is open.
    public var preferredSize: NSSize {
        loadViewIfNeeded()
        return NSSize(width: width, height: chromeHeight + listHeightShown)
    }

    /// Over the rows, inside the scroll: the gap under the filter.
    private var listPaddingTop: CGFloat { content.filter == nil ? 0 : MenuMetrics.filterGap }

    /// `rows` unscrolled, with the list's padding over and under them.
    private func height(of rows: [MenuContent.Row]) -> CGFloat {
        listPaddingTop + rows.reduce(0) { $0 + MenuMetrics.height(of: $1, width: width, content: content) }
            + MenuMetrics.inset
    }

    /// Everything but the list: the filter above it, the footer under it.
    private var chromeHeight: CGFloat {
        listTop.constant
            + (content.footer.isEmpty
                ? 0
                : 0.5 + MenuMetrics.footerTop + MenuMetrics.inset
                    + content.footer.reduce(0) { $0 + MenuMetrics.height(of: $1, width: width, content: content) })
    }

    private var listHeightShown: CGFloat {
        switch content.listHeight {
        case .rows: height(of: content.rows)
        case .fixed(let height): height
        case .expanded(let rows): min(height(of: rows), MenuMetrics.maxListHeight)
        }
    }

    private func resize() {
        guard isViewLoaded else { return }
        listHeight.constant = listHeightShown
    }

    /// Scrolls the checked item into view under its head: a menu opens on
    /// what is chosen, with nothing highlighted until the pointer or a key moves.
    func revealChecked() {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        guard
            let row = content.rows.firstIndex(where: {
                if case .item(let item) = $0 { item.isChecked } else { false }
            })
        else {
            scrollView.contentView.scroll(to: .zero)
            return
        }
        let rect = table.rect(ofRow: row)
        if rect.maxY > listHeight.constant - MenuMetrics.inset {
            // Under the sticky head of its section, which covers the list's top.
            let head = MenuMetrics.accountHeight(note: nil)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - head - 4)))
        } else {
            scrollView.contentView.scroll(to: .zero)
        }
        placeStickyHeader()
    }

    /// What should have the keyboard when the menu opens.
    var initialFirstResponder: NSView { content.filter == nil ? table : filterField.field }

    // MARK: - Choosing

    private var selectedItemID: AnyHashable? {
        guard table.selectedRow >= 0, table.selectedRow < content.rows.count,
            case .item(let item) = content.rows[table.selectedRow]
        else { return nil }
        return item.id
    }

    private func rowIndex(ofItem id: AnyHashable) -> Int? {
        content.rows.firstIndex { if case .item(let item) = $0 { item.id == id } else { false } }
    }

    private func isSelectable(row: Int) -> Bool {
        guard content.rows.indices.contains(row), case .item(let item) = content.rows[row] else { return false }
        return item.isEnabled
    }

    private func selectFirstChoosable() {
        if let row = content.rows.indices.first(where: isSelectable) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
    }

    /// Moves the selection to the next choosable row up or down, as ↑ ↓ do.
    private func moveSelection(by step: Int) {
        let rows = content.rows.indices
        var row = table.selectedRow < 0 ? (step > 0 ? -1 : rows.count) : table.selectedRow
        repeat { row += step } while rows.contains(row) && !isSelectable(row: row)
        guard rows.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func activate(row: Int) {
        guard isSelectable(row: row), case .item(let item) = content.rows[row] else { return }
        delegate?.menuPanelViewController(self, didChoose: item)
    }

    private func cancel() {
        delegate?.menuPanelViewControllerDidCancel(self)
    }

    // MARK: - The sticky head

    public override func viewDidLayout() {
        super.viewDidLayout()
        placeStickyHeader()
    }

    @objc private func listDidScroll() {
        placeStickyHeader()
    }

    /// The head of the account section the list's top is in, at the top —
    /// unless the section's own head is still in view there; the next head,
    /// arriving, pushes it up.
    private func placeStickyHeader() {
        let top = scrollView.contentView.bounds.minY
        let heads = content.rows.indices.filter {
            if case .header(.account) = content.rows[$0] { true } else { false }
        }
        guard let current = heads.last(where: { table.rect(ofRow: $0).minY < top }),
            case .header(let header) = content.rows[current]
        else {
            stickyHeader.isHidden = true
            return
        }
        let height = table.rect(ofRow: current).height
        var push: CGFloat = 0
        if let next = heads.first(where: { $0 > current }) {
            push = max(0, height - (table.rect(ofRow: next).minY - top))
        }
        stickyHeader.configure(header)
        stickyHeader.isHidden = false
        stickyHeader.frame = NSRect(
            x: scrollView.frame.minX, y: scrollView.frame.maxY - height + push, width: scrollView.frame.width,
            height: height)
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let menuColumn = NSUserInterfaceItemIdentifier("menu.column")
    fileprivate static let menuItem = NSUserInterfaceItemIdentifier("menu.item")
    fileprivate static let menuTitle = NSUserInterfaceItemIdentifier("menu.title")
    fileprivate static let menuAccount = NSUserInterfaceItemIdentifier("menu.account")
    fileprivate static let menuSeparator = NSUserInterfaceItemIdentifier("menu.separator")
}

extension MenuPanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { content.rows.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        MenuMetrics.height(of: content.rows[row], width: width, content: content)
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { isSelectable(row: row) }

    public func tableView(
        _ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int
    ) -> String? {
        if case .item(let item) = content.rows[row], item.isEnabled { return item.title }
        return nil
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = MenuRowView()
        if case .item(let item) = content.rows[row], case .toggle = item.trailing { rowView.isQuiet = true }
        return rowView
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch content.rows[row] {
        case .item(let item):
            let cell =
                tableView.makeView(withIdentifier: .menuItem, owner: nil) as? MenuItemCell ?? MenuItemCell()
            cell.identifier = .menuItem
            cell.configure(item, glyphColumn: content.hasGlyphColumn)
            cell.onToggle = { [weak self] _ in
                guard let self, item.isEnabled else { return }
                delegate?.menuPanelViewController(self, didChoose: item)
            }
            return cell
        case .header(.title(let title, let hint)):
            let cell =
                tableView.makeView(withIdentifier: .menuTitle, owner: nil) as? MenuTitleCell ?? MenuTitleCell()
            cell.identifier = .menuTitle
            cell.configure(title, hint: hint)
            return cell
        case .header(let header):
            let cell =
                tableView.makeView(withIdentifier: .menuAccount, owner: nil) as? MenuAccountCell
                ?? MenuAccountCell()
            cell.identifier = .menuAccount
            cell.configure(header)
            return cell
        case .separator:
            let cell =
                tableView.makeView(withIdentifier: .menuSeparator, owner: nil) as? MenuSeparatorCell
                ?? MenuSeparatorCell()
            cell.identifier = .menuSeparator
            return cell
        }
    }
}

extension MenuPanelViewController: NSTextFieldDelegate {
    public func controlTextDidBeginEditing(_ obj: Notification) {
        filterField.isFocused = true
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        filterField.isFocused = false
    }

    public func controlTextDidChange(_ obj: Notification) {
        filterField.isFocused = true
        delegate?.menuPanelViewController(self, didChangeFilter: filterField.text)
    }

    /// The field keeps the keyboard; ↑ ↓ move over the list under it, ↩ takes
    /// what is selected (the first match), ⎋ closes.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            if table.selectedRow < 0 { selectFirstChoosable() }
            if table.selectedRow >= 0 { activate(row: table.selectedRow) }
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
        default:
            return false
        }
        return true
    }
}

/// The list: the pointer selects what can be chosen, a release over the row
/// it was pressed on chooses it, ↩ chooses, ⎋ cancels.
private final class MenuTableView: NSTableView {
    var onActivate: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    var isSelectable: ((Int) -> Bool)?
    private var pressedRow = -1

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, isSelectable?(row) == true {
            if selectedRow != row { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        } else if selectedRow >= 0 {
            deselectAll(nil)
        }
    }

    override func mouseExited(with event: NSEvent) {
        deselectAll(nil)
    }

    override func mouseDown(with event: NSEvent) {
        pressedRow = row(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        defer { pressedRow = -1 }
        guard row >= 0, row == pressedRow else { return }
        onActivate?(row)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:  // return, enter
            if selectedRow >= 0 { onActivate?(selectedRow) }
        case 53:  // escape
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// A row: the accent under the selected item, inset 10 pt, 10 round,
/// accent even while the list isn't the first responder; a switch's row takes
/// the quiet hover fill instead — the switch is the control (`.mi.tg`).
private final class MenuRowView: NSTableRowView {
    var isQuiet = false

    override var isEmphasized: Bool {
        get { !isQuiet }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {}

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSeparator(in dirtyRect: NSRect) {}

    override var wantsUpdateLayer: Bool { true }

    private let highlight = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        highlight.cornerRadius = CornerRadius.menuRow
        highlight.cornerCurve = .continuous
        layer?.addSublayer(highlight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = bounds.insetBy(dx: MenuMetrics.inset, dy: 0)
        CATransaction.commit()
    }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.plain.performAsCurrentDrawingAppearance {
            highlight.backgroundColor =
                isSelected ? (isQuiet ? NSColor.quaternarySystemFill : NSColor.controlAccentColor).cgColor : nil
        }
        CATransaction.commit()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && !isQuiet ? .emphasized : .normal
    }
}

/// An account's head (`.mh.acct`): its 14-pt mark, its name in semibold
/// secondary, its detail in tertiary after it, and a note on a line under
/// (*Restarts the session*). The popover's material under it covers the
/// items that scroll past.
private final class MenuAccountCell: NSTableCellView {
    private let backdrop = NSVisualEffectView()
    private let mark = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        mark.imageScaling = .scaleProportionallyDown
        nameLabel.font = MenuMetrics.headerFont
        nameLabel.textColor = .secondaryLabelColor
        detailLabel.font = MenuMetrics.hintFont
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteLabel.font = MenuMetrics.hintFont
        noteLabel.textColor = .tertiaryLabelColor
        for view in [backdrop, mark, nameLabel, detailLabel, noteLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let line = MenuMetrics.headerLine
        let baseline = MenuMetrics.accountTop + MenuMetrics.baseline(of: MenuMetrics.headerFont, onLine: line)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.accountMarkX),
            mark.centerYAnchor.constraint(equalTo: topAnchor, constant: MenuMetrics.accountTop + line / 2),
            mark.widthAnchor.constraint(equalToConstant: MenuMetrics.accountMarkSize),
            mark.heightAnchor.constraint(equalToConstant: MenuMetrics.accountMarkSize),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.accountWordsX),
            nameLabel.firstBaselineAnchor.constraint(equalTo: topAnchor, constant: baseline),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            detailLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            noteLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            noteLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor, constant: line),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ header: MenuContent.Header) {
        guard case .account(let image, let name, let detail, let note) = header else { return }
        mark.image = image
        mark.contentTintColor = image.isTemplate ? .secondaryLabelColor : nil
        nameLabel.stringValue = name
        detailLabel.stringValue = detail
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = note == nil
        setAccessibilityLabel([name, detail, note].compactMap { $0 }.joined(separator: " "))
    }
}

/// A row under the scroll (`.mfoot`): an item that tracks the pointer itself —
/// the quiet fill for a switch, the accent for a choice — and is chosen by a
/// click or by its switch.
private final class MenuFooterRow: NSView {
    var onChoose: ((MenuContent.Item) -> Void)?

    private let row: MenuContent.Row
    private let cell = MenuItemCell()
    private let highlight = CALayer()
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(row: MenuContent.Row, glyphColumn: Bool) {
        self.row = row
        super.init(frame: .zero)
        wantsLayer = true
        highlight.cornerRadius = CornerRadius.menuRow
        highlight.cornerCurve = .continuous
        layer?.addSublayer(highlight)
        translatesAutoresizingMaskIntoConstraints = false
        cell.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cell)
        NSLayoutConstraint.activate([
            cell.topAnchor.constraint(equalTo: topAnchor),
            cell.bottomAnchor.constraint(equalTo: bottomAnchor),
            cell.leadingAnchor.constraint(equalTo: leadingAnchor),
            cell.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        if case .item(let item) = row {
            cell.configure(item, glyphColumn: glyphColumn)
            // The switch flipped itself; the owner flips the setting.
            cell.onToggle = { [weak self] _ in self?.onChoose?(item) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private var item: MenuContent.Item? {
        if case .item(let item) = row { item } else { nil }
    }

    private var isQuiet: Bool {
        if case .toggle = item?.trailing { true } else { false }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = item?.isEnabled == true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseUp(with event: NSEvent) {
        guard let item, item.isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onChoose?(item)
    }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = bounds.insetBy(dx: MenuMetrics.inset, dy: 0)
        CATransaction.commit()
    }

    override func updateLayer() {
        effectiveAppearance.plain.performAsCurrentDrawingAppearance {
            highlight.backgroundColor =
                isHovered ? (isQuiet ? NSColor.quaternarySystemFill : NSColor.controlAccentColor).cgColor : nil
        }
        cell.backgroundStyle = isHovered && !isQuiet ? .emphasized : .normal
    }
}

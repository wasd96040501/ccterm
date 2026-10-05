import AppKit

/// Every pop-up of the composer and the New view — Model, Effort, Permission
/// Mode, the folder, the branch (design 08 *Menus are popovers*): a system
/// popover, with the system's fade in and out, that closes on a click
/// outside, on ⎋ and on a choice. It holds the menu's list, an inset table — under a search field
/// when the menu has one, over the items that stay in view (Fast Mode).
///
/// It opens from a `MenuButton` and keeps the button on while it is open; a
/// press on the button, as anywhere outside it, closes it.
///
/// Its size is measured before it shows and kept until it closes — searching
/// or flipping a switch changes what the list shows, never the box:
/// - **Width:** its widest row's, from the menu's least width up to what
///   the screen holds, as a menu does; past that a title gives way at its
///   end and a path at its start.
/// - **Height:** every row's, measured at that width; the list scrolls only
///   past the room the screen leaves beside the button, as a menu does. A
///   menu whose rows change while it is open (a search) gives its list a
///   height of its own, and that list scrolls.
/// - The search field over the list and the footer under it never scroll.
///
/// The owner hands it a `MenuContent` and hears choices, searches and the
/// close through the callbacks; a choice closes it, a switch doesn't.
@MainActor
public final class MenuPopover: NSPopover {
    /// An enabled item was clicked, taken with ↩, or its switch flipped.
    public var onChoose: ((MenuContent.Item) -> Void)?
    /// The search field's words changed; the owner answers with `configure(with:)`.
    public var onSearch: ((String) -> Void)?
    public var onClose: (() -> Void)?

    private let list = MenuListViewController()
    /// The button it is open from.
    package private(set) weak var anchor: NSButton?

    public override init() {
        super.init()
        behavior = .transient
        contentViewController = list
        delegate = self
        list.popover = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Shows `content`. Closed, the popover takes its size (as if the screen
    /// had room for every row); open, it keeps the one it has.
    public func configure(with content: MenuContent) {
        list.configure(with: content)
        if !isShown { contentSize = list.size(room: Self.unbounded) }
    }

    /// The popover's frame beyond its content: the arrow and the margin the
    /// system keeps from the screen's edge.
    private static let frameAllowance: CGFloat = 24

    private static let unbounded = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)

    /// The most the popover's content can take beside `button`: the screen's
    /// width, and the height it leaves on the button's roomier side — each
    /// less the popover's frame.
    private static func room(beside button: NSButton) -> NSSize {
        guard let window = button.window, let screen = window.screen?.visibleFrame else { return unbounded }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        return NSSize(
            width: screen.width - 2 * frameAllowance,
            height: max(anchor.minY - screen.minY, screen.maxY - anchor.maxY) - frameAllowance)
    }

    /// Opens against `button` — over it when `above`, else under it, on the
    /// other side when there is no room — and turns the button on until it
    /// closes. Open from another button, it leaves that one first, at once,
    /// as a menu does moving along a menu bar: one menu replacing another
    /// doesn't fade, and a popover still fading out can't open again.
    public func show(from button: NSButton, above: Bool) {
        guard button.window != nil else { return }
        if isShown {
            let animated = animates
            animates = false
            close()
            animates = animated
        }
        contentSize = list.size(room: Self.room(beside: button))
        // A flipped view's maximum y is its bottom.
        let edge: NSRectEdge = above == button.isFlipped ? .minY : .maxY
        show(relativeTo: button.bounds, of: button, preferredEdge: edge)
        guard isShown else { return }
        anchor = button
        button.state = .on
        list.didOpen()
    }

    fileprivate func choose(_ item: MenuContent.Item) {
        if !item.isToggle { close() }
        onChoose?(item)
    }

    fileprivate func search(_ words: String) {
        onSearch?(words)
    }
}

extension MenuPopover: NSPopoverDelegate {
    /// The close starts here; the fade after it is only the popover leaving,
    /// and a show from another button can come before the fade ends — so the
    /// button goes off and the owner hears of it now, not when it has gone.
    public func popoverWillClose(_ notification: Notification) {
        anchor?.state = .off
        anchor = nil
        onClose?()
    }
}

/// The popover's content: the search field, the list, the footer.
private final class MenuListViewController: NSViewController {
    weak var popover: MenuPopover?

    private var content = MenuContent(rows: [], minWidth: 240)
    /// Each row's height at the list's width, measured before it shows —
    /// the table asks for them (`heightOfRow`) and never estimates.
    private var rowHeights: [CGFloat] = []
    /// The width the rows are laid out at: the column's.
    private var rowWidth: CGFloat = 0
    /// Rows laid out off screen to be measured.
    private let sizingItem = MenuItemView()
    private let sizingHeader = MenuHeaderView()
    private let search = NSSearchField()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "")
    private let footerLine = NSBox()
    private let footer = NSStackView()
    private lazy var width = view.widthAnchor.constraint(equalToConstant: 240)
    private lazy var listTop = scroll.topAnchor.constraint(equalTo: view.topAnchor)
    private lazy var listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
    private lazy var listBottom = scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    private lazy var footerBottom = footer.bottomAnchor.constraint(equalTo: view.bottomAnchor)

    /// Set while the owner answers a search: its rows start at the top.
    private var isSearching = false
    /// The pointer moved the selection last, not a key: rows the wheel
    /// scrolls under the pointer become the selection, as in a menu.
    private var selectionFollowsPointer = false

    override func loadView() {
        view = NSView()
        let column = NSTableColumn(identifier: .menuColumn)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.allowsTypeSelect = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
        scroll.documentView = table
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(listDidScroll), name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        search.delegate = self
        search.sendsSearchStringImmediately = true
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        footerLine.boxType = .separator
        footer.orientation = .vertical
        footer.alignment = .width
        footer.spacing = 0
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 10, right: 16)
        for subview in [scroll, search, empty, footerLine, footer] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            width,
            search.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            listTop,
            listHeight,
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            footerLine.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            footerLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.topAnchor.constraint(equalTo: footerLine.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: - Showing

    /// Shows `content`, keeping the selected item and the scroll — unless it
    /// answers a search, whose rows start at the top.
    func configure(with content: MenuContent) {
        loadViewIfNeeded()
        let selected = selectedItem?.id
        let offset = scroll.contentView.bounds.origin
        self.content = content
        let hasSearch = content.searchPlaceholder != nil
        search.isHidden = !hasSearch
        search.placeholderString = content.searchPlaceholder
        listTop.isActive = false
        // The inset table keeps 10 over its first row: the gap under the field.
        listTop =
            hasSearch
            ? scroll.topAnchor.constraint(equalTo: search.bottomAnchor)
            : scroll.topAnchor.constraint(equalTo: view.topAnchor)
        listTop.isActive = true
        let hasFooter = !content.footer.isEmpty
        footerLine.isHidden = !hasFooter
        footer.isHidden = !hasFooter
        listBottom.isActive = !hasFooter
        footerBottom.isActive = hasFooter
        empty.stringValue = content.emptyText ?? ""
        empty.isHidden = !content.rows.isEmpty || content.emptyText == nil
        // Open, the box keeps its width: the rows that came are measured at it.
        if popover?.isShown == true { measureRows() }
        table.reloadData()
        if isSearching {
            scroll.contentView.scroll(to: .zero)
        } else {
            scroll.contentView.scroll(to: offset)
            if let selected, let row = row(ofItem: selected) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Measures the content and answers the size the popover takes inside
    /// `room`: the width first, then each row's height at it, then the
    /// list's, under the search field and over the footer.
    func size(room: NSSize) -> NSSize {
        // How much narrower a row is than the popover: the inset table's
        // margins, read from the table laid out at the menu's least width.
        width.constant = content.minWidth
        listHeight.constant = 0
        view.layoutSubtreeIfNeeded()
        let rowMargin = content.minWidth - (table.tableColumns.first?.width ?? content.minWidth)
        let footerMargin = footer.edgeInsets.left + footer.edgeInsets.right
        let maxWidth = max(room.width, content.minWidth)
        let widest = max(
            content.rows.map { naturalWidth(of: $0, at: maxWidth - rowMargin) + rowMargin }.max() ?? 0,
            content.footer.map { naturalWidth(of: .item($0), at: maxWidth - footerMargin) + footerMargin }.max() ?? 0)
        width.constant = min(max(ceil(widest), content.minWidth), maxWidth)
        view.layoutSubtreeIfNeeded()
        rowWidth = table.tableColumns.first?.width ?? width.constant - rowMargin
        footer.setViews(
            content.footer.map { footerView($0, width: width.constant - footerMargin) }, in: .top)
        measureRows()
        table.reloadData()
        if let height = content.listHeight {
            listHeight.constant = height
        } else {
            // The inset table's margin over its first row, kept under its last.
            let rows =
                table.numberOfRows > 0 ? table.rect(ofRow: table.numberOfRows - 1).maxY + table.rect(ofRow: 0).minY : 0
            view.layoutSubtreeIfNeeded()
            let fixed = view.fittingSize.height
            listHeight.constant = min(ceil(rows), max(room.height - fixed, 0))
        }
        view.layoutSubtreeIfNeeded()
        return view.fittingSize
    }

    /// Each row's height at `rowWidth`, for `heightOfRow`.
    private func measureRows() {
        rowHeights = content.rows.map { height(of: $0, at: rowWidth) }
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<content.rows.count))
    }

    /// The width `row` takes with nothing squeezing it, its subtitle wrapping
    /// no wider than `limit`.
    private func naturalWidth(of row: MenuContent.Row, at limit: CGFloat) -> CGFloat {
        switch row {
        case .item(let item):
            sizingItem.configure(item, glyphColumn: content.hasGlyphColumn, width: limit)
            return sizingItem.fittingSize.width
        case .header, .account:
            sizingHeader.configure(row)
            return sizingHeader.fittingSize.width
        case .separator:
            return 0
        }
    }

    /// How tall `row` is laid out `width` wide.
    private func height(of row: MenuContent.Row, at width: CGFloat) -> CGFloat {
        switch row {
        case .item(let item):
            sizingItem.configure(item, glyphColumn: content.hasGlyphColumn, width: width)
            return ceil(sizingItem.fittingSize.height)
        case .header, .account:
            sizingHeader.configure(row)
            return ceil(sizingHeader.fittingSize.height)
        case .separator:
            return ceil(Self.separatorView().fittingSize.height)
        }
    }

    /// Opened: the keyboard goes to the search field or the list, nothing is
    /// selected, and the checked item is in view.
    func didOpen() {
        view.window?.makeFirstResponder(content.searchPlaceholder == nil ? table : search)
        search.stringValue = ""
        selectionFollowsPointer = false
        table.deselectAll(nil)
        if let checked = content.rows.firstIndex(where: {
            if case .item(let item) = $0 { item.isChecked } else { false }
        }) {
            table.scrollRowToVisible(checked)
        } else {
            table.scrollRowToVisible(0)
        }
    }

    private func footerView(_ item: MenuContent.Item, width: CGFloat) -> NSView {
        let view = MenuItemView()
        view.configure(item, glyphColumn: content.hasGlyphColumn, width: width)
        view.onToggle = { [weak self] in self?.popover?.choose(item) }
        return view
    }

    // MARK: - Choosing

    private var selectedItem: MenuContent.Item? {
        item(at: table.selectedRow)
    }

    private func item(at row: Int) -> MenuContent.Item? {
        guard content.rows.indices.contains(row), case .item(let item) = content.rows[row], item.isEnabled else {
            return nil
        }
        return item
    }

    private func row(ofItem id: AnyHashable) -> Int? {
        content.rows.firstIndex { if case .item(let item) = $0 { item.id == id } else { false } }
    }

    private func select(_ row: Int) {
        if item(at: row) != nil {
            if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        } else {
            table.deselectAll(nil)
        }
    }

    /// Moves the selection to the next item that can be chosen, up or down —
    /// for the search field, which keeps the keyboard; the table's own ↑ ↓
    /// do it when the list has it.
    private func moveSelection(by step: Int) {
        selectionFollowsPointer = false
        var row = table.selectedRow < 0 ? (step > 0 ? -1 : content.rows.count) : table.selectedRow
        repeat { row += step } while content.rows.indices.contains(row) && item(at: row) == nil
        guard content.rows.indices.contains(row) else { return }
        select(row)
        table.scrollRowToVisible(row)
    }

    /// ↩: the selected item, or the first that can be chosen.
    private func chooseSelected() {
        let row = table.selectedRow >= 0 ? table.selectedRow : content.rows.indices.first { item(at: $0) != nil }
        if let row, let item = item(at: row) { popover?.choose(item) }
    }

    @objc private func clicked() {
        if let item = item(at: table.clickedRow) { popover?.choose(item) }
    }

    // MARK: - Pointer and keys

    override func mouseMoved(with event: NSEvent) {
        selectionFollowsPointer = true
        selectRowUnderPointer()
    }

    override func mouseExited(with event: NSEvent) {
        selectionFollowsPointer = false
        table.deselectAll(nil)
    }

    @objc private func listDidScroll() {
        if selectionFollowsPointer { selectRowUnderPointer() }
    }

    private func selectRowUnderPointer() {
        guard let window = view.window else { return }
        select(table.row(at: table.convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    /// What the table passes up — ↩ and ⎋; it moves its selection itself.
    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func insertNewline(_ sender: Any?) {
        chooseSelected()
    }

    override func cancelOperation(_ sender: Any?) {
        popover?.close()
    }
}

extension MenuListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        content.rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeights.indices.contains(row) ? rowHeights[row] : height(of: content.rows[row], at: rowWidth)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        item(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        item(at: row)?.title
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch content.rows[row] {
        case .item(let item):
            let view = tableView.makeView(withIdentifier: .menuItem, owner: nil) as? MenuItemView ?? MenuItemView()
            view.identifier = .menuItem
            view.configure(item, glyphColumn: content.hasGlyphColumn, width: rowWidth)
            view.onToggle = { [weak self] in self?.popover?.choose(item) }
            return view
        case .header, .account:
            let view =
                tableView.makeView(withIdentifier: .menuHeader, owner: nil) as? MenuHeaderView ?? MenuHeaderView()
            view.identifier = .menuHeader
            view.configure(content.rows[row])
            return view
        case .separator:
            return tableView.makeView(withIdentifier: .menuSeparator, owner: nil) ?? Self.separatorView()
        }
    }

    /// A hairline with 5 over and under it.
    fileprivate static func separatorView() -> NSView {
        let view = NSTableCellView()
        view.identifier = .menuSeparator
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            line.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            line.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
        ])
        return view
    }
}

extension MenuListViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        isSearching = true
        popover?.search(search.stringValue)
        isSearching = false
    }

    /// The field keeps the keyboard: ↑ ↓ move over the list, ↩ takes the
    /// selected item or the first match, ⎋ clears the field, then closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            chooseSelected()
        case #selector(NSResponder.cancelOperation(_:)) where search.stringValue.isEmpty:
            popover?.close()
        default:
            return false
        }
        return true
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let menuColumn = NSUserInterfaceItemIdentifier("menu.column")
    fileprivate static let menuItem = NSUserInterfaceItemIdentifier("menu.item")
    fileprivate static let menuHeader = NSUserInterfaceItemIdentifier("menu.header")
    fileprivate static let menuSeparator = NSUserInterfaceItemIdentifier("menu.separator")
}

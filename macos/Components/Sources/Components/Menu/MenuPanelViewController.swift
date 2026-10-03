import AppKit

/// The one menu every pop-up of the composer and the New view is — Model,
/// Effort, Mode, the folder and the branch — drawn to the design's `.lv-menu`
/// (design 08, preview-live.css *Menus and the model panel*), so they share
/// one look and one set of manners: the menu material with the popover radius,
/// 5 pt around the rows; a section head in 11-pt semibold tertiary; items with
/// a check, a 16-pt glyph, a title, a subtitle under it and a trailing key,
/// glyph or switch; the accent under the pointer; greyed items with their
/// reason; hairlines between groups; a filter field over a list that scrolls
/// past 360 pt with each account's head sticking to its top; what follows
/// under the scroll, always in view.
///
/// 08-live names `NSMenu` for Effort and Mode. They are this instead, so the
/// five pop-ups are one component: `NSMenu` can't cap its height with sticky
/// heads, keep itself open for a switch, or hold a filter field, which the
/// model panel and the branch picker need.
///
/// Manners as `NSMenu`'s: the pointer selects, a release over an item chooses
/// it, ↑ ↓ move over what can be chosen, ↩ chooses, ⎋ closes, typing selects
/// by title — or, with a filter field, types into it. `MenuPanel` puts it on
/// screen; the owner hands it a `MenuContent` and hears choices through the
/// delegate.
@MainActor
public final class MenuPanelViewController: NSViewController {
    weak var delegate: MenuPanelViewControllerDelegate?

    /// A panel's width (`.lv-menu.panel`).
    static let panelWidth: CGFloat = 300
    /// A panel's list scrolls past this (`.mscroll`).
    static let maxListHeight: CGFloat = 360
    /// A menu's width, from its widest row (`.lv-menu`'s min- and max-width).
    static let menuWidths: ClosedRange<CGFloat> = 240...340

    private(set) var content = MenuContent(rows: [])
    /// The width the content asks for.
    private(set) var width: CGFloat = 240
    /// How tall the list may be; the presenter lowers it when the screen has
    /// less room (never under 120).
    private(set) var listHeightLimit: CGFloat = .greatestFiniteMagnitude {
        didSet { resize() }
    }

    /// Cuts the list to `height` (the presenter's call when the screen has no room).
    func limitList(to height: CGFloat) {
        listHeightLimit = height
    }

    private let material = NSVisualEffectView()
    private let filterField = MenuFilterField()
    private let scrollView = MenuScrollView()
    private let table = MenuTableView()
    /// The head of the account section the list's top is in, over the list.
    private let stickyHeader = MenuAccountCell()
    private let footerSeparator = MenuHairline()
    private let footer = NSStackView()
    private var footerItems: [MenuContent.Item] = []

    private lazy var filterHeight = filterField.heightAnchor.constraint(equalToConstant: 0)
    private lazy var listTop = scrollView.topAnchor.constraint(equalTo: view.topAnchor)
    private lazy var listHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
    private lazy var viewWidth = view.widthAnchor.constraint(equalToConstant: width)

    public override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override func loadView() {
        material.material = .menu
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = CornerRadius.popover
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        view = material
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
            top: MenuMetrics.inset, left: 0, bottom: MenuMetrics.inset, right: 0)
        for subview in [filterField, scrollView, footerSeparator, footer] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // Placed by frame on every scroll, over the list.
        view.addSubview(stickyHeader, positioned: .above, relativeTo: scrollView)
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            viewWidth,
            filterField.topAnchor.constraint(equalTo: view.topAnchor, constant: MenuMetrics.inset),
            filterField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: MenuMetrics.inset),
            filterField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -MenuMetrics.inset),
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
        width = Self.width(of: content)
        viewWidth.constant = width
        let hasFilter = content.filter != nil
        filterField.isHidden = !hasFilter
        if let filter = content.filter {
            filterField.placeholder = filter.placeholder
            if filterField.text != filter.text { filterField.text = filter.text }
        }
        // The filter's 5 above and 4 under; a panel's list starts at its top,
        // a menu's 5 in.
        listTop.constant =
            hasFilter
            ? MenuMetrics.inset + MenuFilterField.height + 4 : (content.isPanel ? 0 : MenuMetrics.inset)
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: MenuMetrics.inset, right: 0)
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

    /// The size the menu wants: the filter, the list up to its limit, the footer.
    public var preferredSize: NSSize {
        loadViewIfNeeded()
        return NSSize(width: width, height: chromeHeight + shownListHeight)
    }

    /// The list's whole height, unscrolled.
    var fullListHeight: CGFloat {
        content.rows.reduce(0) { $0 + MenuMetrics.height(of: $1, width: width, content: content) }
            + MenuMetrics.inset
    }

    /// Everything but the list: the filter above it, the footer under it.
    var chromeHeight: CGFloat {
        listTop.constant
            + (content.footer.isEmpty
                ? 0
                : 0.5 + 2 * MenuMetrics.inset
                    + content.footer.reduce(0) { $0 + MenuMetrics.height(of: $1, width: width, content: content) })
    }

    private var shownListHeight: CGFloat {
        let cap = content.isPanel ? Self.maxListHeight : .greatestFiniteMagnitude
        return min(fullListHeight, cap, listHeightLimit)
    }

    private func resize() {
        guard isViewLoaded else { return }
        let before = listHeight.constant
        listHeight.constant = shownListHeight
        if before != listHeight.constant { delegate?.menuPanelViewControllerDidChangeSize(self) }
    }

    /// The width `content` asks for: a panel's fixed width, or a menu's
    /// widest row within its range.
    static func width(of content: MenuContent) -> CGFloat {
        if content.isPanel { return panelWidth }
        let widest =
            (content.rows + content.footer).map { MenuMetrics.naturalWidth(of: $0, content: content) }.max() ?? 0
        return min(max(ceil(widest), menuWidths.lowerBound), menuWidths.upperBound)
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

// MARK: - Metrics

/// The design's numbers for a menu (`.lv-menu`, `.mi`, `.mh`, `.msep`), as
/// measured on the sheet: x is from the menu's leading edge.
enum MenuMetrics {
    /// The menu's padding, and a row's inset within it (`.lv-menu` 5).
    static let inset: CGFloat = 5
    /// A check's leading edge: the inset and the row's 6 (`.mi` padding).
    static let checkX: CGFloat = 11
    /// A 10-pt check in its 14-pt column.
    static let checkSize: CGFloat = 10
    /// The glyph column, after the check's 14 and a 4 gap; 20 wide, its glyph 16.
    static let glyphX: CGFloat = 29
    static let glyphSize: CGFloat = 16
    /// The words: after the glyph column's 20 and a 4 gap — or where the
    /// glyph column would start, when no item has a glyph (`.mi.nog`).
    static let wordsX: CGFloat = 53
    static let wordsXWithoutGlyphs: CGFloat = 29
    /// From the menu's trailing edge to a row's trailing words, glyph or switch:
    /// the inset and the row's 10.
    static let trailingInset: CGFloat = 15
    /// The grid's gap before the trailing column, there even when it is empty
    /// (`.mi` column-gap).
    static let columnGap: CGFloat = 4
    /// Before a key or a trailing glyph (`.mi .k` padding-left), and before a switch.
    static let keyGap: CGFloat = 16
    static let switchGap: CGFloat = 12
    /// A row's padding above and below its words.
    static let rowPadding: CGFloat = 3

    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let subtitleFont = NSFont.systemFont(ofSize: 11)
    static let keyFont = NSFont.systemFont(ofSize: 12)
    static let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let hintFont = NSFont.systemFont(ofSize: 11)

    /// The sheet's 1.45 line: 13-pt words on an 18.85-pt line.
    static let titleLine: CGFloat = 13 * 1.45
    /// A subtitle's 14-pt lines and the 1 under them.
    static let subtitleLine: CGFloat = 14
    static let subtitleBottom: CGFloat = 1
    /// An 11-pt head on its 15.95-pt line, 4 above and 2 under (`.mh`).
    static let headerLine: CGFloat = 11 * 1.45
    static let headerTop: CGFloat = 4
    static let headerBottom: CGFloat = 2
    /// An account's head: 8 above, 4 under, its mark 14 at 11, words at 31 (`.mh.acct`).
    static let accountTop: CGFloat = 8
    static let accountBottom: CGFloat = 4
    static let accountMarkX: CGFloat = 11
    static let accountMarkSize: CGFloat = 14
    static let accountWordsX: CGFloat = 31
    /// The hairline's 5 above and under, 15 in from either side (`.msep`).
    static let separatorHeight: CGFloat = 10.5

    /// Where `font`'s baseline sits on a line `height` tall, from its top:
    /// the half-leading above, then the ascent — the browser's placement.
    static func baseline(of font: NSFont, onLine height: CGFloat) -> CGFloat {
        (height - (font.ascender - font.descender)) / 2 + font.ascender
    }

    static func accountHeight(note: String?) -> CGFloat {
        accountTop + headerLine + (note == nil ? 0 : headerLine) + accountBottom
    }

    static func wordsX(glyphColumn: Bool) -> CGFloat { glyphColumn ? wordsX : wordsXWithoutGlyphs }

    /// The width the trailing column takes after the words, with the grid's
    /// gap before it and its own padding.
    static func trailingWidth(of trailing: MenuContent.Trailing) -> CGFloat {
        switch trailing {
        case .none: columnGap
        case .key(let words): columnGap + keyGap + ceil(width(of: words, font: keyFont))
        case .glyph: columnGap + keyGap + 14
        case .toggle: columnGap + switchGap + MenuSwitchMetrics.size.width
        }
    }

    /// Where an item's subtitle may run: from the words' column to its trailing accessory.
    static func subtitleWidth(of item: MenuContent.Item, menuWidth: CGFloat, glyphColumn: Bool) -> CGFloat {
        menuWidth - trailingInset - trailingWidth(of: item.trailing) - wordsX(glyphColumn: glyphColumn)
    }

    /// The subtitle in its 14-pt lines.
    static func subtitle(_ words: String, color: NSColor) -> NSAttributedString {
        let lines = NSMutableParagraphStyle()
        lines.minimumLineHeight = subtitleLine
        lines.maximumLineHeight = subtitleLine
        return NSAttributedString(
            string: words, attributes: [.font: subtitleFont, .foregroundColor: color, .paragraphStyle: lines])
    }

    static func subtitleLines(_ words: String, width: CGFloat) -> Int {
        let rect = subtitle(words, color: .labelColor).boundingRect(
            with: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(1, Int((rect.height / subtitleLine).rounded()))
    }

    static func height(of row: MenuContent.Row, width: CGFloat, content: MenuContent) -> CGFloat {
        switch row {
        case .separator:
            return separatorHeight
        case .header(.title):
            return headerTop + headerLine + headerBottom
        case .header(.account(_, _, _, let note)):
            return accountHeight(note: note)
        case .item(let item):
            var height = rowPadding + titleLine + rowPadding
            if let subtitle = item.subtitle {
                let lines = subtitleLines(
                    subtitle, width: subtitleWidth(of: item, menuWidth: width, glyphColumn: content.hasGlyphColumn))
                height += CGFloat(lines) * subtitleLine + subtitleBottom
            }
            return height
        }
    }

    /// The menu width a row needs to set its words on one line.
    static func naturalWidth(of row: MenuContent.Row, content: MenuContent) -> CGFloat {
        switch row {
        case .separator:
            return 0
        case .header(.title(let title, let hint)):
            let hinted = hint.map { 12 + width(of: $0, font: hintFont) } ?? 0
            return inset + 24 + width(of: title, font: headerFont) + hinted + 10 + inset
        case .header(.account(_, let name, let detail, let note)):
            let line = accountWordsX + width(of: name, font: headerFont) + 6 + width(of: detail, font: hintFont)
            let under = accountWordsX + (note.map { width(of: $0, font: hintFont) } ?? 0)
            return max(line, under) + 10
        case .item(let item):
            let words = max(
                width(of: item.title, font: titleFont), item.subtitle.map { width(of: $0, font: subtitleFont) } ?? 0)
            return wordsX(glyphColumn: content.hasGlyphColumn) + words + trailingWidth(of: item.trailing)
                + trailingInset
        }
    }

    static func width(of words: String, font: NSFont) -> CGFloat {
        (words as NSString).size(withAttributes: [.font: font]).width
    }
}

/// The small switch at a setting's trailing edge (`.nsw`: 26 × 15).
enum MenuSwitchMetrics {
    static var size: NSSize {
        let toggle = NSSwitch()
        toggle.controlSize = .mini
        return toggle.intrinsicContentSize
    }
}

// MARK: - The list

/// Overlay scrollers always, as a menu's: a legacy scroller would take 17 pt
/// from every row.
private final class MenuScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
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

/// A row: the accent under the selected item, inset 5 pt, at the row radius,
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
        highlight.cornerRadius = CornerRadius.row
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

/// An item (`.mi`): the check, the glyph, the title with its subtitle under,
/// and the trailing key, glyph or switch. White on the accent while selected,
/// its quieter parts at 85 %; all tertiary while disabled.
final class MenuItemCell: NSTableCellView {
    var onToggle: ((Bool) -> Void)?

    private let check = NSImageView()
    private let glyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let key = NSTextField(labelWithString: "")
    private let trailingGlyph = NSImageView()
    private let toggle = NSSwitch()

    private var item: MenuContent.Item?
    private var glyphColumn = true
    private lazy var titleLeading = titleLabel.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: MenuMetrics.wordsX)
    private lazy var subtitleWidth = subtitleLabel.widthAnchor.constraint(equalToConstant: 0)

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        check.imageScaling = .scaleNone
        glyph.imageScaling = .scaleProportionallyDown
        trailingGlyph.imageScaling = .scaleProportionallyDown
        titleLabel.font = MenuMetrics.titleFont
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.isSelectable = false
        subtitleLabel.maximumNumberOfLines = 0
        key.font = MenuMetrics.keyFont
        key.lineBreakMode = .byTruncatingHead
        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = #selector(toggled)
        for view in [check, glyph, titleLabel, subtitleLabel, key, trailingGlyph, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let titleLineMiddle = MenuMetrics.rowPadding + MenuMetrics.titleLine / 2
        NSLayoutConstraint.activate([
            check.centerXAnchor.constraint(
                equalTo: leadingAnchor, constant: MenuMetrics.checkX + MenuMetrics.checkSize / 2),
            check.centerYAnchor.constraint(equalTo: topAnchor, constant: titleLineMiddle),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.glyphX),
            glyph.widthAnchor.constraint(equalToConstant: MenuMetrics.glyphSize),
            glyph.heightAnchor.constraint(equalToConstant: MenuMetrics.glyphSize),
            glyph.centerYAnchor.constraint(equalTo: topAnchor, constant: titleLineMiddle),
            titleLeading,
            titleLabel.firstBaselineAnchor.constraint(
                equalTo: topAnchor,
                constant: MenuMetrics.rowPadding
                    + MenuMetrics.baseline(of: MenuMetrics.titleFont, onLine: MenuMetrics.titleLine)),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -MenuMetrics.trailingInset),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(
                equalTo: topAnchor, constant: MenuMetrics.rowPadding + MenuMetrics.titleLine),
            subtitleWidth,
            key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailingInset),
            key.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            key.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: MenuMetrics.keyGap),
            trailingGlyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailingInset),
            trailingGlyph.widthAnchor.constraint(equalToConstant: 14),
            trailingGlyph.heightAnchor.constraint(equalToConstant: 14),
            trailingGlyph.centerYAnchor.constraint(equalTo: topAnchor, constant: titleLineMiddle),
            // A switch spans the title and the subtitle (`.mi.tg .k`).
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailingInset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ item: MenuContent.Item, glyphColumn: Bool) {
        self.item = item
        self.glyphColumn = glyphColumn
        titleLabel.stringValue = item.title
        titleLeading.constant = MenuMetrics.wordsX(glyphColumn: glyphColumn)
        check.isHidden = !item.isChecked
        glyph.image = item.glyph
        glyph.isHidden = item.glyph == nil
        subtitleLabel.isHidden = item.subtitle == nil
        key.isHidden = true
        trailingGlyph.isHidden = true
        toggle.isHidden = true
        switch item.trailing {
        case .none: break
        case .key(let words):
            key.stringValue = words
            key.isHidden = false
        case .glyph(let image):
            trailingGlyph.image = image
            trailingGlyph.isHidden = false
        case .toggle(let isOn):
            toggle.state = isOn ? .on : .off
            toggle.isEnabled = item.isEnabled
            toggle.isHidden = false
        }
        toolTip = item.toolTip
        setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityValue(item.isChecked ? 1 : 0)
        needsLayout = true
        updateColors()
    }

    override func layout() {
        if let item {
            subtitleWidth.constant = max(
                0, MenuMetrics.subtitleWidth(of: item, menuWidth: bounds.width, glyphColumn: glyphColumn))
            subtitleLabel.preferredMaxLayoutWidth = subtitleWidth.constant
        }
        super.layout()
    }

    private func updateColors() {
        guard let item else { return }
        let selected = backgroundStyle == .emphasized
        let quiet = NSColor.white.withAlphaComponent(0.85)
        let title: NSColor
        let secondary: NSColor
        if !item.isEnabled {
            title = .tertiaryLabelColor
            secondary = .tertiaryLabelColor
        } else if selected {
            title = .white
            secondary = quiet
        } else {
            title = item.isDanger ? .failureText : item.isMore ? .controlAccentColor : .labelColor
            secondary = .secondaryLabelColor
        }
        titleLabel.textColor = title
        check.contentTintColor = title
        glyph.contentTintColor = item.isEnabled && item.isDanger && !selected ? .failureText : secondary
        subtitleLabel.attributedStringValue = MenuMetrics.subtitle(item.subtitle ?? "", color: secondary)
        key.textColor = selected && item.isEnabled ? quiet : .tertiaryLabelColor
        trailingGlyph.contentTintColor = selected && item.isEnabled ? quiet : .tertiaryLabelColor
    }

    @objc private func toggled() {
        onToggle?(toggle.state == .on)
    }
}

/// A section's head (`.mh`): 11-pt semibold tertiary words over the items'
/// glyph column, a key hint at the trailing edge.
private final class MenuTitleCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = MenuMetrics.headerFont
        title.textColor = .tertiaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.font = MenuMetrics.hintFont
        hint.textColor = .tertiaryLabelColor
        for view in [title, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let baseline =
            MenuMetrics.headerTop + MenuMetrics.baseline(of: MenuMetrics.headerFont, onLine: MenuMetrics.headerLine)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.inset + 24),
            title.firstBaselineAnchor.constraint(equalTo: topAnchor, constant: baseline),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailingInset),
            hint.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ words: String, hint: String?) {
        title.stringValue = words
        self.hint.stringValue = hint ?? ""
        self.hint.isHidden = hint == nil
        setAccessibilityLabel(words)
    }
}

/// An account's head (`.mh.acct`): its 14-pt mark, its name in semibold
/// secondary, its detail in tertiary after it, and a note on a line under
/// (*Restarts the session*). The menu's material under it covers the items
/// that scroll past.
private final class MenuAccountCell: NSTableCellView {
    private let backdrop = NSVisualEffectView()
    private let mark = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backdrop.material = .menu
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

/// A hairline between groups (`.msep`): 5 above and under, 15 in from either side.
private final class MenuSeparatorCell: NSTableCellView {
    private let line = MenuHairline()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.trailingInset),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.trailingInset),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
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
        highlight.cornerRadius = CornerRadius.row
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

/// A 0.5-pt line in the separator colour of plain Light or Dark (`plain`): the
/// material's vibrant appearance would hand it an opaque grey.
final class MenuHairline: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var allowsVibrancy: Bool { false }

    // Painted when it joins a window and when the appearance flips, not in
    // `updateLayer`: a line laid out after its first display pass never got one.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        effectiveAppearance.plain.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }
}

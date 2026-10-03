import AppKit

/// The model panel's content (design 08 *Model*): one list, a section per
/// account in Settings' order, each account's header sticking to the top as its
/// models pass under it; *N More Models* expanding in place; *Restarts the
/// session* and ↻ on the accounts another launch environment would restart;
/// and the Fast Mode switch under the scroll, always in view.
///
/// The account headers stick as a menu's section headers would — one header
/// over the list's top, pushed up by the next — drawn by the panel itself, not
/// as floating group rows, whose scroll pocket underlines them.
///
/// It is an `NSMenu`'s look — the menu material, the system menu's 24-pt rows
/// (36 with a subtitle) inside a 5-pt inset, 12-pt corners, accent highlight
/// under the pointer, and the design's columns: a check (14), a glyph (20),
/// then the words at 53 — and an `NSMenu`'s
/// manners: arrows move over the choosable rows, ↩ chooses, ⎋ closes, typing
/// selects by name. It is a panel's content, not a menu, because it has a
/// height limit (360 pt, then the list scrolls). `ModelPanelController` puts it
/// on screen. It draws a `ComposerModel` and reports intents.
@MainActor
final class ModelPanelViewController: NSViewController {
    /// A model was chosen: close and apply.
    var onChoose: ((ComposerModel.Item) -> Void)?
    var onSetFast: ((Bool) -> Void)?
    /// ⎋.
    var onCancel: (() -> Void)?
    /// The content's height changed (a section expanded, the model changed).
    var onHeightChange: (() -> Void)?

    static let width: CGFloat = 300
    static let maxScrollHeight: CGFloat = 360
    static let cornerRadius: CGFloat = 12

    /// What the list's rows are.
    enum Row: Equatable {
        /// *Applies after this turn* over every section.
        case note(String)
        case header(ComposerModel.ModelSection)
        case item(ComposerModel.Item)
        /// *N More Models*, expanding the section `id`.
        case more(id: UUID, count: Int)
    }

    private(set) var rows: [Row] = []
    private var model: ComposerModel?
    private var expanded: Set<UUID> = []

    private let material = NSVisualEffectView()
    private let scrollView = PanelScrollView()
    private let table = PanelTableView()
    /// The header of the section at the list's top, over the list.
    private let stickyHeader = PanelHeaderCell()
    private let footer = FastModeRow()
    private let separator = HairlineView()
    private lazy var scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: Self.maxScrollHeight)

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        material.material = .menu
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = Self.cornerRadius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        view = material
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureConstraints()
        if let model { configure(with: model) }
    }

    private func configureHierarchy() {
        let column = NSTableColumn(identifier: .modelPanelColumn)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.floatsGroupRows = false
        table.allowsTypeSelect = true
        table.allowsEmptySelection = true
        table.style = .plain
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.onActivate = { [weak self] row in self?.activate(row: row) }
        table.onCancel = { [weak self] in self?.onCancel?() }
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 5, right: 0)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(listDidScroll), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        stickyHeader.setAccessibilityElement(false)
        stickyHeader.isHidden = true
        footer.onToggle = { [weak self] isOn in self?.onSetFast?(isOn) }
        for subview in [scrollView, separator, footer] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // Placed by frame on every scroll, above the list.
        view.addSubview(stickyHeader, positioned: .above, relativeTo: scrollView)
    }

    private func configureConstraints() {
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.width),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollHeight,
            separator.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            footer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Showing

    /// Shows `model`. Idempotent: what is expanded and where the list is
    /// scrolled stay.
    func configure(with model: ComposerModel) {
        self.model = model
        guard isViewLoaded else { return }
        let selected = selectedItemChange()
        rows = Self.rows(for: model, expanded: expanded)
        table.reloadData()
        footer.configure(with: model.fastMode)
        resize()
        placeStickyHeader()
        if let selected, let row = rows.firstIndex(where: { $0.change == selected }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    /// The rows for `model`: the note, then per account its header, its models
    /// and — unless expanded — *N More Models*.
    static func rows(for model: ComposerModel, expanded: Set<UUID>) -> [Row] {
        var rows: [Row] = []
        if let header = model.modelPanelHeader { rows.append(.note(header)) }
        for section in model.modelSections {
            rows.append(.header(section))
            rows.append(contentsOf: section.items.map(Row.item))
            if expanded.contains(section.id) {
                rows.append(contentsOf: section.foldedItems.map(Row.item))
            } else if !section.foldedItems.isEmpty {
                rows.append(.more(id: section.id, count: section.foldedItems.count))
            }
        }
        return rows
    }

    /// The height the panel wants: the list up to 360 pt, then the switch.
    var preferredHeight: CGFloat {
        loadViewIfNeeded()
        return listHeight + 0.5 + footer.fittingSize.height
    }

    private var listHeight: CGFloat {
        min(rows.indices.map { height(of: $0) }.reduce(0, +) + 5, Self.maxScrollHeight)
    }

    private func resize() {
        let before = scrollHeight.constant
        scrollHeight.constant = listHeight
        if before != scrollHeight.constant { onHeightChange?() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        placeStickyHeader()
    }

    @objc private func listDidScroll() {
        placeStickyHeader()
    }

    /// The header of the section the list's top is in, at the top — unless
    /// the section's own header is still in view there; the next header,
    /// arriving, pushes it up.
    private func placeStickyHeader() {
        let top = scrollView.contentView.bounds.minY
        let headers = rows.indices.filter { if case .header = rows[$0] { true } else { false } }
        guard let current = headers.last(where: { table.rect(ofRow: $0).minY < top }),
            case .header(let section) = rows[current]
        else {
            stickyHeader.isHidden = true
            return
        }
        let height = table.rect(ofRow: current).height
        var push: CGFloat = 0
        if let next = headers.first(where: { $0 > current }) {
            push = max(0, height - (table.rect(ofRow: next).minY - top))
        }
        stickyHeader.configure(section)
        stickyHeader.isHidden = false
        stickyHeader.frame = NSRect(
            x: scrollView.frame.minX, y: scrollView.frame.maxY - height + push, width: scrollView.frame.width,
            height: height)
    }

    /// Puts the selection on the checked model, if any — a panel opens on it.
    func selectCurrent() {
        loadViewIfNeeded()
        let row = rows.firstIndex { if case .item(let item) = $0 { item.isChecked } else { false } }
        guard let row else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // The list opens at its top unless the current model is below the
        // first screen; then it comes to just under the account's sticky header.
        let rect = table.rect(ofRow: row)
        if rect.maxY > scrollHeight.constant - 5 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - 28 - 4)))
        } else {
            scrollView.contentView.scroll(to: .zero)
        }
    }

    /// The control that should have the keyboard when the panel opens.
    var initialFirstResponder: NSView { table }

    private func selectedItemChange() -> SessionSettings.Change? {
        guard table.selectedRow >= 0, table.selectedRow < rows.count, case .item(let item) = rows[table.selectedRow]
        else { return nil }
        return item.change
    }

    // MARK: - Choosing

    private func activate(row: Int) {
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .item(let item):
            guard item.isEnabled else { return }
            onChoose?(item)
        case .more(let id, _):
            // Expands in place: the panel stays open and the list stays put.
            expanded.insert(id)
            guard let model else { return }
            let offset = scrollView.contentView.bounds.origin
            rows = Self.rows(for: model, expanded: expanded)
            table.reloadData()
            resize()
            scrollView.contentView.scroll(to: offset)
            placeStickyHeader()
            // The first model that came out of the fold takes the row's place.
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        default:
            break
        }
    }

    // MARK: - Geometry

    private func height(of row: Int) -> CGFloat {
        switch rows[row] {
        case .note: 22
        // 8 above, a 16-pt line (two with the note), 4 below.
        case .header(let section): section.note == nil ? 28 : 44
        case .item(let item): item.subtitle == nil ? 24 : 36
        case .more: 24
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let modelPanelColumn = NSUserInterfaceItemIdentifier("modelPanel.column")
    fileprivate static let modelPanelNote = NSUserInterfaceItemIdentifier("modelPanel.note")
    fileprivate static let modelPanelHeader = NSUserInterfaceItemIdentifier("modelPanel.header")
    fileprivate static let modelPanelItem = NSUserInterfaceItemIdentifier("modelPanel.item")
}

extension ModelPanelViewController.Row {
    /// What choosing the row does, for the rows that are choices.
    fileprivate var change: SessionSettings.Change? {
        if case .item(let item) = self { return item.change }
        return nil
    }
}

extension ModelPanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { height(of: row) }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .item(let item): item.isEnabled
        case .more: true
        default: false
        }
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        if case .item(let item) = rows[row], item.isEnabled { return item.title }
        return nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PanelRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .note(let words):
            let cell =
                tableView.makeView(withIdentifier: .modelPanelNote, owner: nil) as? PanelNoteCell ?? PanelNoteCell()
            cell.identifier = .modelPanelNote
            cell.configure(words)
            return cell
        case .header(let section):
            let cell =
                tableView.makeView(withIdentifier: .modelPanelHeader, owner: nil) as? PanelHeaderCell
                ?? PanelHeaderCell()
            cell.identifier = .modelPanelHeader
            cell.configure(section)
            return cell
        case .item(let item):
            let cell =
                tableView.makeView(withIdentifier: .modelPanelItem, owner: nil) as? PanelItemCell ?? PanelItemCell()
            cell.identifier = .modelPanelItem
            cell.configure(item: item)
            return cell
        case .more(_, let count):
            let cell =
                tableView.makeView(withIdentifier: .modelPanelItem, owner: nil) as? PanelItemCell ?? PanelItemCell()
            cell.identifier = .modelPanelItem
            cell.configure(moreCount: count)
            return cell
        }
    }
}

// MARK: - The list

/// The design's menu columns (`.mi`: 5-pt menu inset, 6-pt row inset, a 14-pt
/// check, 4, a 20-pt glyph, 4, the words), as x in the panel.
private enum PanelColumns {
    static let check: CGFloat = 11
    static let glyph: CGFloat = 29
    /// A 16-pt glyph at the start of its 20-pt column.
    static let glyphWidth: CGFloat = 16
    static let words: CGFloat = 53
    /// From the panel's trailing edge to a row's trailing glyph or switch.
    static let trailing: CGFloat = 15
}

/// The list's scroll view: overlay scrollers always, as a menu's — a legacy
/// scroller would take 17 pt from every row.
private final class PanelScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

/// The list: hover selects, ↩ chooses, ⎋ closes, and a release over a row
/// chooses it, as a menu does.
private final class PanelTableView: NSTableView {
    var onActivate: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    private var pressedRow = -1

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, delegate?.tableView?(self, shouldSelectRow: row) == true {
            if selectedRow != row { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        } else if selectedRow >= 0 {
            deselectAll(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressedRow = row(at: convert(event.locationInWindow, from: nil))
        window?.makeFirstResponder(self)
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

/// A row: draws the menu's accent highlight, inset 5 pt, and keeps it accent
/// even when the list isn't the first responder.
private final class PanelRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 5, dy: 0)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    /// A floating account header is not underlined: the material under it is
    /// all that separates it from the models passing beneath.
    override func drawSeparator(in dirtyRect: NSRect) {}

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }
}

/// *Applies after this turn*: a quiet line over the sections.
private final class PanelNoteCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ words: String) {
        label.stringValue = words
    }
}

/// An account's header: its mark, its name, its detail in tertiary, and — on a
/// line under — what choosing one of its models does (*Restarts the session*).
/// The material under it covers the models that scroll past.
private final class PanelHeaderCell: NSTableCellView {
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
        mark.imageScaling = .scaleNone
        nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .tertiaryLabelColor
        for view in [backdrop, mark, nameLabel, detailLabel, noteLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            mark.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            mark.widthAnchor.constraint(equalToConstant: 14),
            mark.heightAnchor.constraint(equalToConstant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            detailLabel.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            noteLabel.leadingAnchor.constraint(equalTo: mark.leadingAnchor, constant: 20),
            noteLabel.topAnchor.constraint(equalTo: mark.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ section: ComposerModel.ModelSection) {
        mark.image = ComposerGlyph.image(section.glyph, size: 14)
        mark.contentTintColor = section.glyph == .subscription ? nil : .secondaryLabelColor
        nameLabel.stringValue = section.name
        detailLabel.stringValue = section.detail
        noteLabel.stringValue = section.note ?? ""
        noteLabel.isHidden = section.note == nil
        setAccessibilityLabel("\(section.name) \(section.detail) \(section.note ?? "")")
    }
}

/// A model's row: the check before it, its name, what it resolves to under, ↻ at
/// the end when choosing it restarts the session; or the accent *N More Models*.
private final class PanelItemCell: NSTableCellView {
    private let check = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let trailing = NSImageView()

    private var isEnabled = true
    private var isMore = false
    private var hasTrailing = false
    /// A single line sits in the middle of its 24 pt; a title with a subtitle
    /// under it starts 3 pt down.
    private lazy var titleTop = titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4)

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        check.imageScaling = .scaleNone
        // The check starts its column, as the sheet's 10-pt check does.
        check.imageAlignment = .alignLeft
        check.image = ComposerGlyph.image(.check)
        trailing.imageScaling = .scaleNone
        trailing.image = ComposerGlyph.image(.restart)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        for view in [check, titleLabel, subtitleLabel, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelColumns.check),
            check.widthAnchor.constraint(equalToConstant: 14),
            check.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelColumns.words),
            titleTop,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 0),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelColumns.trailing),
            trailing.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            trailing.widthAnchor.constraint(equalToConstant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(item: ComposerModel.Item) {
        isMore = false
        isEnabled = item.isEnabled
        titleLabel.stringValue = item.title
        subtitleLabel.stringValue = item.subtitle ?? ""
        subtitleLabel.isHidden = item.subtitle == nil
        titleTop.constant = item.subtitle == nil ? 4 : 3
        check.isHidden = !item.isChecked
        hasTrailing = item.restarts
        trailing.isHidden = !item.restarts
        setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityValue(item.isChecked ? 1 : 0)
        updateColors()
    }

    func configure(moreCount: Int) {
        isMore = true
        isEnabled = true
        titleLabel.stringValue = String(localized: "\(moreCount) More Models")
        subtitleLabel.isHidden = true
        titleTop.constant = 4
        check.isHidden = true
        trailing.isHidden = true
        hasTrailing = false
        setAccessibilityLabel(titleLabel.stringValue)
        updateColors()
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        let primary: NSColor =
            selected ? .white : (isEnabled ? (isMore ? .controlAccentColor : .labelColor) : .tertiaryLabelColor)
        let secondary: NSColor =
            selected ? NSColor.white.withAlphaComponent(0.85) : (isEnabled ? .secondaryLabelColor : .tertiaryLabelColor)
        titleLabel.textColor = primary
        subtitleLabel.textColor = secondary
        check.contentTintColor = primary
        trailing.contentTintColor = selected ? NSColor.white.withAlphaComponent(0.85) : .tertiaryLabelColor
    }
}

// MARK: - The Fast Mode switch

/// *Fast Mode*, outside the scroll: a bolt, the name, why it is off-limits (or
/// what it costs) under it, and a small switch. A setting, not a choice: toggling
/// it leaves the panel open so the chip's bolt can be seen to appear.
private final class FastModeRow: NSView {
    var onToggle: ((Bool) -> Void)?

    private let glyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: String(localized: "Fast Mode"))
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The chip's bolt, at the chip's size (the sheet's 10 × 12), in the glyph column.
        glyph.image = ComposerGlyph.image(.fast)
        glyph.contentTintColor = .secondaryLabelColor
        glyph.imageScaling = .scaleNone
        glyph.imageAlignment = .alignCenter
        titleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        toggle.controlSize = .mini
        // The words' column: from 53 to 12 pt before the switch, as wide as the system draws it.
        subtitleLabel.preferredMaxLayoutWidth =
            ModelPanelViewController.width - PanelColumns.words - 12 - toggle.intrinsicContentSize.width
            - PanelColumns.trailing
        toggle.target = self
        toggle.action = #selector(toggled)
        for view in [glyph, titleLabel, subtitleLabel, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            // The footer's 5-pt inset and the row's 3 — 4 under the subtitle's last line.
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelColumns.glyph),
            glyph.widthAnchor.constraint(equalToConstant: PanelColumns.glyphWidth),
            glyph.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelColumns.words),
            // 8, and the sheet's 19-pt line around the title's 16.
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9.5),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelColumns.trailing),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(with fast: ComposerModel.FastModeSwitch) {
        toggle.state = fast.isOn ? .on : .off
        toggle.isEnabled = fast.isEnabled
        titleLabel.textColor = fast.isEnabled ? .labelColor : .tertiaryLabelColor
        // The sheet's `.s`: 14-pt lines.
        let lines = NSMutableParagraphStyle()
        lines.minimumLineHeight = 14
        lines.maximumLineHeight = 14
        subtitleLabel.attributedStringValue = NSAttributedString(
            string: fast.subtitle ?? "",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: fast.isEnabled ? NSColor.secondaryLabelColor : .tertiaryLabelColor,
                .paragraphStyle: lines,
            ])
        toolTip = fast.subtitle
        setAccessibilityLabel(titleLabel.stringValue)
    }

    @objc private func toggled() {
        onToggle?(toggle.state == .on)
    }
}

/// A 0.5-pt separator.
private final class HairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }
}

import AppKit

/// Pure filter math for the branch picker, ported VERBATIM from
/// `BranchPickerView.swift:22-41` (migration plan §4.6 reused set). Lifted into
/// a SwiftUI-free struct so the sectioning logic is unit-testable independent of
/// the AppKit view tree.
struct BranchPickerModel {
    let branches: [String]
    let currentBranch: String?
    let remoteMainBranch: String?
    let currentBranchStatus: String?
    var searchText: String = ""

    /// `BranchPickerView.filteredBranches` — case-insensitive contains.
    var filteredBranches: [String] {
        if searchText.isEmpty { return branches }
        return branches.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    /// `BranchPickerView.filteredCurrentBranch`.
    var filteredCurrentBranch: String? {
        guard let currentBranch else { return nil }
        return filteredBranches.first { $0 == currentBranch }
    }

    /// `BranchPickerView.filteredOtherBranches`.
    var filteredOtherBranches: [String] {
        filteredBranches.filter { $0 != currentBranch }
    }

    /// `BranchPickerView.filteredRemoteMain`.
    var filteredRemoteMain: String? {
        guard let remoteMainBranch else { return nil }
        if searchText.isEmpty { return remoteMainBranch }
        return remoteMainBranch.localizedCaseInsensitiveContains(searchText) ? remoteMainBranch : nil
    }

    /// The "No Matching Branches" branch is taken only when a non-empty query
    /// returns zero rows (`BranchPickerView.branchListSection`).
    var showsEmptyState: Bool {
        filteredBranches.isEmpty && filteredRemoteMain == nil && !searchText.isEmpty
    }

    /// Whether any row renders at all.
    var hasAnyRow: Bool {
        !(filteredBranches.isEmpty && filteredRemoteMain == nil)
    }

    /// One row in the flat render list. The SwiftUI `BranchPickerView` rendered
    /// three `sectionHeader(_:)` labels (`BranchPickerView.swift:83,98,113`)
    /// between the row groups; the AppKit table reproduces them as
    /// non-selectable `.header` pseudo-rows interleaved with `.branch` rows so
    /// the section structure + the `Branches (N)` count survive the migration.
    enum Row: Equatable {
        case header(String)
        case branch(Branch)

        struct Branch: Equatable {
            let branch: String
            let isCurrent: Bool
            let subtitle: String?
        }

        /// The selectable branch payload, or nil for a header row.
        var branch: Branch? {
            if case .branch(let b) = self { return b }
            return nil
        }

        var isHeader: Bool {
            if case .header = self { return true }
            return false
        }
    }

    /// Flat row list in render order, with the three section headers
    /// (Current Branch → Remote Main → Branches (N)) interleaved exactly where
    /// the SwiftUI `branchListSection` emitted them.
    var rows: [Row] {
        var out: [Row] = []
        if let current = filteredCurrentBranch {
            out.append(.header(String(localized: "Current Branch")))
            out.append(
                .branch(Row.Branch(branch: current, isCurrent: true, subtitle: currentBranchStatus)))
        }
        if let remote = filteredRemoteMain {
            out.append(.header(String(localized: "Remote Main")))
            out.append(.branch(Row.Branch(branch: remote, isCurrent: false, subtitle: nil)))
        }
        let others = filteredOtherBranches
        if !others.isEmpty {
            out.append(.header(String(localized: "Branches (\(others.count))")))
            for branch in others {
                out.append(.branch(Row.Branch(branch: branch, isCurrent: false, subtitle: nil)))
            }
        }
        return out
    }

    /// Just the selectable branch rows (no headers) — keyboard/Confirm logic and
    /// the sectioning unit test read this so they don't have to skip headers.
    var branchRows: [Row.Branch] {
        rows.compactMap { $0.branch }
    }
}

/// AppKit replacement for `BranchPickerView.swift` (migration plan §4.6) — the
/// popover content hosted by the compose card's branch pill. `NSSearchField` +
/// a flat `NSTableView` rendering the sectioned branch rows + a Confirm bar.
///
/// Key routing (plan §4.6-8): Return → Confirm (only when a branch is selected),
/// Esc → dismiss; the search filter skips while the field is IME-composing
/// (`currentEditor()?.hasMarkedText()`). The filter MATH is reused verbatim via
/// `BranchPickerModel`; only the view is rebuilt to AppKit.
@MainActor
final class BranchPickerViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate
{
    nonisolated deinit {}

    // MARK: - Constants (verbatim from BranchPickerView.swift)

    /// Popover content width (`BranchPickerView.swift:51` `.frame(width: 300)`).
    static let contentWidth: CGFloat = 300
    /// Branch list height (`BranchPickerView.swift:134` `.frame(height: 200)`).
    static let listHeight: CGFloat = 200
    static let searchHInset: CGFloat = 12
    static let searchVInset: CGFloat = 8
    static let rowHeight: CGFloat = 28
    /// Section-header pseudo-row height: caption line + the SwiftUI
    /// `.padding(.vertical, 4)` (`BranchPickerView.swift:147`).
    static let headerRowHeight: CGFloat = 22

    // MARK: - State

    private var model: BranchPickerModel
    /// Selected branch; seeded to `currentBranch` on load (`onAppear { selected = currentBranch }`).
    private(set) var selectedBranch: String?
    /// Fired on Confirm / double-click (`BranchPickerView.onSelect`).
    let onSelect: (String) -> Void

    // MARK: - Views

    private let searchField = NSSearchField()
    /// Internal (not private) so a test can drive the real selection path via
    /// `selectRowIndexes(...)` → `tableViewSelectionDidChange` instead of a
    /// test-only seam (access modifier only; no behavior change).
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let confirmButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: String(localized: "No Matching Branches"))
    private let emptyIcon = NSImageView()
    private let emptyContainer = NSView()

    init(
        branches: [String],
        currentBranch: String?,
        remoteMainBranch: String?,
        currentBranchStatus: String?,
        onSelect: @escaping (String) -> Void
    ) {
        self.model = BranchPickerModel(
            branches: branches,
            currentBranch: currentBranch,
            remoteMainBranch: remoteMainBranch,
            currentBranchStatus: currentBranchStatus)
        self.selectedBranch = currentBranch
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 256))
        root.translatesAutoresizingMaskIntoConstraints = false

        // Search.
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = String(localized: "Search branches…")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.focusRingType = .none
        root.addSubview(searchField)

        // Table in a scroll view.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("branch"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.action = #selector(rowClicked)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        root.addSubview(scrollView)

        // Empty state.
        emptyContainer.translatesAutoresizingMaskIntoConstraints = false
        emptyContainer.isHidden = true
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyIcon.image = NSImage(
            systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        emptyIcon.contentTintColor = .secondaryLabelColor
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 15, weight: .regular)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyContainer.addSubview(emptyIcon)
        emptyContainer.addSubview(emptyLabel)
        root.addSubview(emptyContainer)

        // Confirm bar.
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.title = String(localized: "Confirm")
        confirmButton.bezelStyle = .rounded
        confirmButton.controlSize = .small
        confirmButton.keyEquivalent = "\r"  // Return → Confirm (plan §4.6-8)
        confirmButton.target = self
        confirmButton.action = #selector(confirmTapped)
        root.addSubview(confirmButton)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.contentWidth),

            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.searchVInset),
            searchField.leadingAnchor.constraint(
                equalTo: root.leadingAnchor, constant: Self.searchHInset),
            searchField.trailingAnchor.constraint(
                equalTo: root.trailingAnchor, constant: -Self.searchHInset),

            scrollView.topAnchor.constraint(
                equalTo: searchField.bottomAnchor, constant: Self.searchVInset),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: Self.listHeight),

            emptyContainer.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyContainer.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyContainer.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            emptyContainer.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            emptyIcon.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            emptyIcon.centerYAnchor.constraint(equalTo: emptyContainer.centerYAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 4),

            confirmButton.topAnchor.constraint(
                equalTo: scrollView.bottomAnchor, constant: Self.searchVInset),
            confirmButton.trailingAnchor.constraint(
                equalTo: root.trailingAnchor, constant: -Self.searchHInset),
            confirmButton.bottomAnchor.constraint(
                equalTo: root.bottomAnchor, constant: -Self.searchVInset),
        ])

        view = root
        reconcile()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Seed selection highlight + put focus in the search field so the user
        // can type to filter immediately.
        reconcile()
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Reconcile (rebuild rows from the model)

    private func reconcile() {
        let showEmpty = model.showsEmptyState
        emptyContainer.isHidden = !showEmpty
        scrollView.isHidden = showEmpty
        confirmButton.isEnabled = selectedBranch != nil
        tableView.reloadData()
        // Restore selection highlight to the selected branch's row, if visible.
        if let sel = selectedBranch, let idx = rowIndex(ofBranch: sel) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    /// The flat-list index of a branch's `.branch` row, or nil (header rows + a
    /// filtered-out branch return nil).
    private func rowIndex(ofBranch branch: String) -> Int? {
        model.rows.firstIndex { $0.branch?.branch == branch }
    }

    // MARK: - NSSearchFieldDelegate / search

    func controlTextDidChange(_ obj: Notification) {
        // Skip filter recompute while the field is IME-composing (plan §4.6-8):
        // a half-typed CJK query shouldn't filter against incomplete text. The
        // field editor is an `NSTextView` under the hood.
        if let editor = searchField.currentEditor() as? NSTextView, editor.hasMarkedText() {
            return
        }
        applySearch(searchField.stringValue)
    }

    /// Public entry point so a test can drive the search without an editor.
    func applySearch(_ text: String) {
        model.searchText = text
        reconcile()
    }

    // MARK: - Row actions

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < model.rows.count, let branch = model.rows[row].branch else { return }
        selectedBranch = branch.branch
        confirmButton.isEnabled = true
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < model.rows.count, let branch = model.rows[row].branch else { return }
        selectedBranch = branch.branch
        onSelect(branch.branch)
    }

    @objc private func confirmTapped() { confirm() }

    /// Confirm the current selection (Return / Confirm button). Fires
    /// `onSelect` only with a selection (`disabled(selected == nil)`).
    func confirm() {
        guard let branch = selectedBranch else { return }
        onSelect(branch)
    }

    /// Esc → dismiss the popover (plan §4.6-8).
    override func cancelOperation(_ sender: Any?) {
        view.window?.close()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    )
        -> NSView?
    {
        guard row < model.rows.count else { return nil }
        switch model.rows[row] {
        case .header(let text):
            let cell =
                (tableView.makeView(withIdentifier: BranchSectionHeaderView.identifier, owner: self)
                    as? BranchSectionHeaderView) ?? BranchSectionHeaderView()
            cell.identifier = BranchSectionHeaderView.identifier
            cell.configure(text: text)
            return cell
        case .branch(let data):
            let cell =
                (tableView.makeView(withIdentifier: BranchRowView.identifier, owner: self)
                    as? BranchRowView) ?? BranchRowView()
            cell.identifier = BranchRowView.identifier
            cell.configure(
                branch: data.branch,
                isCurrent: data.isCurrent,
                isSelected: data.branch == selectedBranch,
                subtitle: data.subtitle)
            return cell
        }
    }

    /// Header pseudo-rows are non-selectable captions — mirror the SwiftUI
    /// `sectionHeader(_:)` which was a plain `Text`, not a tappable row.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < model.rows.count else { return false }
        return !model.rows[row].isHeader
    }

    /// Section headers are shorter than branch rows (caption-height) — match the
    /// SwiftUI `sectionHeader` `.caption` + `.padding(.vertical, 4)`.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < model.rows.count else { return Self.rowHeight }
        return model.rows[row].isHeader ? Self.headerRowHeight : Self.rowHeight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < model.rows.count, let branch = model.rows[row].branch else { return }
        selectedBranch = branch.branch
        confirmButton.isEnabled = true
        // Re-render so the checkmark glyph tracks the new selection.
        for visible in tableView.subviews.compactMap({ $0 as? BranchRowView }) {
            visible.updateSelectionGlyph(selected: visible.branch == selectedBranch)
        }
    }
}

// MARK: - BranchRowView

/// A single branch row: selection-circle glyph + branch label (+ "current"
/// chip) + optional status subtitle. Ports `BranchPickerView.BranchRow`'s
/// layout constants (`BranchPickerView.swift:198-243`).
@MainActor
private final class BranchRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("BranchRowView")

    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let currentChip = NSTextField(labelWithString: String(localized: "current"))
    private let subtitleLabel = NSTextField(labelWithString: "")
    private(set) var branch: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        addSubview(glyph)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
        addSubview(label)

        currentChip.translatesAutoresizingMaskIntoConstraints = false
        currentChip.font = NSFont.systemFont(ofSize: 10)
        currentChip.textColor = .secondaryLabelColor
        currentChip.wantsLayer = true
        currentChip.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
        currentChip.layer?.cornerRadius = 4
        currentChip.isHidden = true
        addSubview(currentChip)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 10)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.cell?.usesSingleLineMode = true
        subtitleLabel.isHidden = true
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            glyph.widthAnchor.constraint(equalToConstant: 12),
            glyph.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            currentChip.leadingAnchor.constraint(
                greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            currentChip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            currentChip.centerYAnchor.constraint(equalTo: label.centerYAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -12),
            subtitleLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(branch: String, isCurrent: Bool, isSelected: Bool, subtitle: String?) {
        self.branch = branch
        label.stringValue = branch
        currentChip.isHidden = !isCurrent
        if let subtitle, !subtitle.isEmpty {
            subtitleLabel.stringValue = subtitle
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.isHidden = true
        }
        updateSelectionGlyph(selected: isSelected)
    }

    func updateSelectionGlyph(selected: Bool) {
        glyph.image = NSImage(
            systemSymbolName: selected ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: nil)
        glyph.contentTintColor = selected ? NSColor.controlAccentColor : .secondaryLabelColor
    }
}

// MARK: - BranchSectionHeaderView

/// A non-selectable section-header pseudo-row (`Current Branch` / `Remote Main` /
/// `Branches (N)`). Ports the SwiftUI `sectionHeader(_:)` style
/// (`BranchPickerView.swift:142-148`): `.caption .secondary`, `.h12 .v4`.
@MainActor
private final class BranchSectionHeaderView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("BranchSectionHeaderView")

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        // `.caption` ≈ the system caption text style.
        label.font = NSFont.preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String) {
        label.stringValue = text
    }
}

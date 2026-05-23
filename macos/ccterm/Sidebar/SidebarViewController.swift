import AppKit
import Observation

/// AppKit-native sidebar built on `NSOutlineView` in source-list style.
/// Replaces the prior SwiftUI `SidebarView2`.
///
/// Data is FLAT — every visible row is at the top level of the outline
/// view (`isItemExpandable` always false). Folder toggle animates rows
/// in / out via `insertItems(at:inParent:withAnimation:)` /
/// `removeItems(at:inParent:withAnimation:)`. The outline view's
/// built-in expand/collapse machinery is bypassed, which also keeps
/// the source-list style from drawing its own disclosure triangle on
/// the left of folder rows.
///
/// Row heights are left at the source-list defaults — we do not
/// override `rowHeight`, `heightOfRowByItem`, or
/// `usesAutomaticRowHeights`. The cell views just anchor their content
/// against the cell's `centerY`.
@MainActor
final class SidebarViewController: NSViewController {

    let model: MainSelectionModel
    let sessionManager: SessionManager

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let column = NSTableColumn(identifier: .init("Sidebar"))

    /// Single flat list of visible rows. `rebuildItems` recomputes this
    /// from `SessionManager.records` + `collapsedFolders`; folder toggle
    /// mutates it in-place + animates the diff.
    private var visibleItems: [SidebarItemNode] = []

    /// Folders the user has collapsed. Folders default to expanded.
    private var collapsedFolders: Set<String> = []

    /// Per-history-row observation handles. Keyed by sessionId so we
    /// can cancel + re-arm when the underlying `Session` is replaced.
    private var rowObservations: [String: Task<Void, Never>] = [:]

    private var recordsObservationTask: Task<Void, Never>?
    private var selectionObservationTask: Task<Void, Never>?
    private var isApplyingSelectionFromModel = false

    init(model: MainSelectionModel, sessionManager: SessionManager) {
        self.model = model
        self.sessionManager = sessionManager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        recordsObservationTask?.cancel()
        selectionObservationTask?.cancel()
        for task in rowObservations.values { task.cancel() }
    }

    override func loadView() {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        view = host

        configureOutline()
        configureScrollView()
        host.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: host.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuildItems()
        applyModelSelection()
        startRecordsObservation()
        startSelectionObservation()
    }

    // MARK: - View construction

    private func configureOutline() {
        column.isEditable = false
        column.resizingMask = [.autoresizingMask]
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = nil
        outlineView.headerView = nil
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .sourceList
        outlineView.indentationPerLevel = 0
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(handleOutlineClick(_:))
        outlineView.menu = makeContextMenu()
    }

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let archive = NSMenuItem(
            title: String(localized: "Archive"),
            action: #selector(archiveSelectedRow(_:)),
            keyEquivalent: "")
        archive.target = self
        menu.addItem(archive)
        return menu
    }

    // MARK: - Items

    private func rebuildItems() {
        let previousSelectionTag = currentSelectionTag()
        visibleItems = buildVisibleItems()
        outlineView.reloadData()
        if let tag = previousSelectionTag {
            selectRow(for: tag)
        }
    }

    private func buildVisibleItems() -> [SidebarItemNode] {
        var items: [SidebarItemNode] = []
        for kind in FixedKind.allCases {
            items.append(
                SidebarItemNode(kind: .fixed(kind), selectionTag: kind.selectionTag))
        }
        for group in groupedRecords() {
            let folderNode = SidebarItemNode(
                kind: .folder(name: group.folderName), selectionTag: nil)
            items.append(folderNode)
            if !collapsedFolders.contains(group.folderName) {
                for record in group.records {
                    items.append(
                        SidebarItemNode(
                            kind: .history(
                                sessionId: record.sessionId, fallbackTitle: record.title),
                            selectionTag: record.sessionId))
                }
            }
        }
        return items
    }

    private struct RecordGroup {
        let folderName: String
        let records: [SessionRecord]
    }

    private func groupedRecords() -> [RecordGroup] {
        let buckets = Dictionary(grouping: sessionManager.records) {
            $0.groupingFolderName ?? "Unknown"
        }
        return buckets.map { folder, items in
            RecordGroup(
                folderName: folder,
                records: items.sorted { $0.lastActiveAt > $1.lastActiveAt })
        }
        .sorted {
            guard let a = $0.records.first, let b = $1.records.first else { return false }
            return a.lastActiveAt > b.lastActiveAt
        }
    }

    private func currentSelectionTag() -> String? {
        let row = outlineView.selectedRow
        guard row >= 0, row < visibleItems.count else { return nil }
        return visibleItems[row].selectionTag
    }

    private func selectRow(for tag: String) {
        guard let row = visibleItems.firstIndex(where: { $0.selectionTag == tag }) else {
            return
        }
        isApplyingSelectionFromModel = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isApplyingSelectionFromModel = false
    }

    // MARK: - Selection / records observation

    private func applyModelSelection() {
        guard let tag = model.selectedSessionId else {
            isApplyingSelectionFromModel = true
            outlineView.deselectAll(nil)
            isApplyingSelectionFromModel = false
            return
        }
        selectRow(for: tag)
    }

    private func startSelectionObservation() {
        selectionObservationTask?.cancel()
        selectionObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { cont in
                withObservationTracking {
                    _ = self.model.selectedSessionId
                } onChange: {
                    Task { @MainActor in cont.resume() }
                }
            }
            self.applyModelSelection()
            self.startSelectionObservation()
        }
    }

    private func startRecordsObservation() {
        recordsObservationTask?.cancel()
        recordsObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { cont in
                withObservationTracking {
                    _ = self.sessionManager.records
                } onChange: {
                    Task { @MainActor in cont.resume() }
                }
            }
            self.rebuildItems()
            self.startRecordsObservation()
        }
    }

    // MARK: - Folder toggle (data-driven, animated)

    private func toggleFolder(at row: Int) {
        guard row >= 0, row < visibleItems.count else { return }
        let node = visibleItems[row]
        guard case .folder(let name) = node.kind else { return }
        let currentlyCollapsed = collapsedFolders.contains(name)
        if currentlyCollapsed {
            // Expand: insert this folder's records after the folder row.
            let records = groupedRecords().first(where: { $0.folderName == name })?.records ?? []
            let newItems = records.map {
                SidebarItemNode(
                    kind: .history(sessionId: $0.sessionId, fallbackTitle: $0.title),
                    selectionTag: $0.sessionId)
            }
            let insertRange = (row + 1)...(row + newItems.count)
            visibleItems.insert(contentsOf: newItems, at: row + 1)
            collapsedFolders.remove(name)
            outlineView.beginUpdates()
            outlineView.insertItems(
                at: IndexSet(insertRange),
                inParent: nil,
                withAnimation: [.slideDown, .effectFade])
            outlineView.endUpdates()
        } else {
            // Collapse: remove rows that belong to this folder (until
            // the next folder or end-of-list).
            var end = row + 1
            while end < visibleItems.count {
                if case .folder = visibleItems[end].kind { break }
                end += 1
            }
            let removeRange = (row + 1)..<end
            guard !removeRange.isEmpty else {
                collapsedFolders.insert(name)
                if let cell = folderCell(at: row) {
                    cell.setExpanded(false, animated: true)
                }
                return
            }
            visibleItems.removeSubrange(removeRange)
            collapsedFolders.insert(name)
            outlineView.beginUpdates()
            outlineView.removeItems(
                at: IndexSet(integersIn: removeRange),
                inParent: nil,
                withAnimation: [.slideUp, .effectFade])
            outlineView.endUpdates()
        }
        if let cell = folderCell(at: row) {
            // After toggle: new expanded state is `currentlyCollapsed`
            // (it was just collapsed → now expanded, or vice versa).
            cell.setExpanded(currentlyCollapsed, animated: true)
        }
    }

    private func folderCell(at row: Int) -> SidebarFolderCellView? {
        outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? SidebarFolderCellView
    }

    // MARK: - Click + context menu

    @objc private func handleOutlineClick(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, row < visibleItems.count else { return }
        let node = visibleItems[row]
        if case .folder = node.kind {
            toggleFolder(at: row)
        }
    }

    @objc private func archiveSelectedRow(_ sender: Any?) {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, row < visibleItems.count else { return }
        guard case .history(let sessionId, _) = visibleItems[row].kind else { return }
        if model.selectedSessionId == sessionId {
            model.selectedSessionId = SidebarSentinel.newSession
        }
        sessionManager.archive(sessionId)
    }
}

// MARK: - DataSource / Delegate

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return visibleItems.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        return visibleItems[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return false
    }
}

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let node = item as? SidebarItemNode else { return nil }
        switch node.kind {
        case .fixed(let kind):
            let cell = SidebarFixedCellView()
            cell.configure(kind: kind)
            return cell
        case .folder(let name):
            let cell = SidebarFolderCellView()
            let isExpanded = !collapsedFolders.contains(name)
            cell.configure(folderName: name, isExpanded: isExpanded)
            return cell
        case .history(let sessionId, let fallback):
            let cell = SidebarHistoryCellView()
            configureHistoryCell(cell, sessionId: sessionId, fallback: fallback)
            return cell
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SidebarItemNode else { return false }
        if case .folder = node.kind { return false }
        return true
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        selectionIndexesForProposedSelection proposed: IndexSet
    ) -> IndexSet {
        var allowed = IndexSet()
        for row in proposed {
            guard row < visibleItems.count else { continue }
            if case .folder = visibleItems[row].kind { continue }
            allowed.insert(row)
        }
        return allowed
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelectionFromModel else { return }
        let row = outlineView.selectedRow
        guard row >= 0, row < visibleItems.count,
            let tag = visibleItems[row].selectionTag
        else { return }
        if model.selectedSessionId != tag {
            model.selectedSessionId = tag
        }
    }
}

// MARK: - Per-row observation

extension SidebarViewController {
    fileprivate func configureHistoryCell(
        _ cell: SidebarHistoryCellView, sessionId: String, fallback: String
    ) {
        if let earlier = cell.observedSessionId, earlier != sessionId {
            rowObservations[earlier]?.cancel()
            rowObservations[earlier] = nil
        }
        cell.observedSessionId = sessionId
        cell.fallbackTitle = fallback
        applyHistoryState(cell: cell, sessionId: sessionId, fallback: fallback)
        armRowObservation(cell: cell, sessionId: sessionId)
    }

    private func armRowObservation(cell: SidebarHistoryCellView, sessionId: String) {
        rowObservations[sessionId]?.cancel()
        rowObservations[sessionId] = Task { @MainActor [weak self, weak cell] in
            guard let controller = self, let initial = cell,
                initial.observedSessionId == sessionId
            else { return }
            await withCheckedContinuation { cont in
                withObservationTracking {
                    let session = controller.sessionManager.existingSession(sessionId)
                    _ = session?.title
                    _ = session?.isRunning
                    _ = session?.hasUnread
                    _ = session?.isGeneratingTitle
                } onChange: {
                    Task { @MainActor in cont.resume() }
                }
            }
            guard let refreshed = cell, refreshed.observedSessionId == sessionId else { return }
            controller.applyHistoryState(
                cell: refreshed, sessionId: sessionId, fallback: refreshed.fallbackTitle)
            controller.armRowObservation(cell: refreshed, sessionId: sessionId)
        }
    }

    private func applyHistoryState(
        cell: SidebarHistoryCellView, sessionId: String, fallback: String
    ) {
        let session = sessionManager.existingSession(sessionId)
        cell.configure(
            title: session?.title ?? fallback,
            isRunning: session?.isRunning ?? false,
            hasUnread: session?.hasUnread ?? false,
            isGeneratingTitle: session?.isGeneratingTitle ?? false)
    }
}

// MARK: - Context menu validation

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = outlineView.clickedRow
        let allowed: Bool
        if row >= 0, row < visibleItems.count,
            case .history = visibleItems[row].kind
        {
            allowed = true
        } else {
            allowed = false
        }
        for item in menu.items { item.isHidden = !allowed }
    }
}

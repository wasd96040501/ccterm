import AppKit
import Observation

/// AppKit-native sidebar built on `NSOutlineView` in source-list style.
/// Replaces the prior SwiftUI `SidebarView2`.
///
/// Data model is **hierarchical**: the root holds fixed top items
/// followed by folder nodes; folder nodes hold history nodes as
/// children. This means expand / collapse rides on the outline view's
/// built-in `expandItem(_:)` / `collapseItem(_:)` (animated, persistent
/// across reloads) and drag-and-drop of whole folders goes through the
/// standard `pasteboardWriterForItem` / `validateDrop` / `acceptDrop`
/// trio.
///
/// The standard left-edge disclosure triangle is suppressed by
/// overriding `frameOfOutlineCell(atRow:)` to return `.zero` on a
/// private NSOutlineView subclass — we draw a custom right-side
/// chevron in the folder cell instead. Children render flush-left (no
/// indent) because `indentationPerLevel = 0`; alignment relies on the
/// cells sharing a fixed leading-icon slot.
///
/// Row heights are explicit via `outlineView(_:heightOfRowByItem:)` —
/// `style = .sourceList` resets `rowHeight` and `intercellSpacing`
/// after it's assigned, so per-row sizing has to come from the
/// delegate. The three heights (`SidebarLayout.fixedRowHeight` /
/// `.folderRowHeight` / `.historyRowHeight`) reproduce the prior
/// SwiftUI sidebar's rhythm.
///
/// Group order is sourced from `SidebarSessionGroupOrderStore`
/// (UserDefaults). Newly-appeared groups (a user just sent the first
/// message in a folder that had no prior sessions) are detected via
/// the records-observation diff and prepended to the store.
@MainActor
final class SidebarViewController: NSViewController {

    /// The sidebar-scope dependency bag, handed down from the split.
    /// `model`, `sessionManager`, `groupOrderStore`, and `openInService` are
    /// read through this.
    let context: SidebarContext

    private let scrollView = NSScrollView()
    private let outlineView = NoDisclosureOutlineView()
    private let column = NSTableColumn(identifier: .init("Sidebar"))

    /// "Open in" context-menu item. Its submenu (the per-app list) is
    /// rebuilt on every right-click in `menuNeedsUpdate`, and the item
    /// itself is disabled (greyed) when the clicked session has no
    /// openable directory on disk.
    private let openInItem = NSMenuItem(
        title: String(localized: "Open in"), action: nil, keyEquivalent: "")

    /// "Copy Session File Path" context-menu item. Held as a field so
    /// `menuNeedsUpdate` can grey it out when the clicked session has no
    /// JSONL on disk yet (same enable/disable discipline as `openInItem`).
    private let copyPathItem = NSMenuItem(
        title: String(localized: "Copy Session File Path"),
        action: #selector(copySessionFilePath(_:)),
        keyEquivalent: "")

    /// Flat list of the outline's root children. Folder nodes inside
    /// hold their own `children` arrays for the hierarchy. Recomputed
    /// by `rebuildItems`; mutated in-place during drag-and-drop so
    /// `outlineView.moveItem` can animate the change.
    private var rootChildren: [SidebarItemNode] = []

    /// Snapshot of the group names present at the last records refresh.
    /// Initialized in `viewDidLoad` to the current set so the first
    /// observation fire reads as a "real change" rather than cold-start.
    private var lastSeenGroups: Set<String> = []

    /// Per-history-row observation handles. Keyed by sessionId so we
    /// can cancel + re-arm when the underlying `Session` is replaced.
    private var rowObservations: [String: Task<Void, Never>] = [:]

    private var recordsObservationTask: Task<Void, Never>?
    private var selectionObservationTask: Task<Void, Never>?
    private var isApplyingSelectionFromModel = false

    init(context: SidebarContext) {
        self.context = context
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
        // Initialize the seen-groups snapshot from the current
        // repository state. Without this, the first records-observation
        // fire after launch would treat every existing group as
        // newly-appeared and prepend them in iteration order.
        lastSeenGroups = SidebarTreeModel.currentGroupSet(context.sessionManager.records)
        rebuildItems()  // also runs expandAllFolders + restores selection
        applyModelSelection()
        startRecordsObservation()
        startSelectionObservation()
    }

    // MARK: - View construction

    private func configureOutline() {
        column.isEditable = false
        column.resizingMask = [.autoresizingMask]
        outlineView.addTableColumn(column)
        // Keep `outlineTableColumn = column` so NSOutlineView wires its
        // child-of-item dispatch correctly; the disclosure triangle is
        // hidden by the subclass overriding `frameOfOutlineCell`.
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .sourceList
        // `style = .sourceList` resets indentation; force it to zero so
        // history children sit in the same leading column as folder
        // headers (alignment relies on the shared 16pt icon slot, not
        // on outline indent).
        outlineView.indentationPerLevel = 0
        // Pin per-row heights to `heightOfRowByItem` instead of letting
        // the source-list style fall back to intrinsic-size auto sizing
        // — auto sizing would let a long title's intrinsic content size
        // stretch the row and bleed into adjacent rows.
        outlineView.usesAutomaticRowHeights = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(handleOutlineClick(_:))
        outlineView.menu = makeContextMenu()
        outlineView.registerForDraggedTypes([SidebarLayout.folderDragType])
        outlineView.setDraggingSourceOperationMask([.move], forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)
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
        // Manage enabled state ourselves — the default autoenable path
        // would route through `validateMenuItem`/responder chain and
        // override the greyed-out "Open in" state we set explicitly.
        menu.autoenablesItems = false

        let archive = NSMenuItem(
            title: String(localized: "Archive"),
            action: #selector(archiveSelectedRow(_:)),
            keyEquivalent: "")
        archive.target = self
        menu.addItem(archive)

        copyPathItem.target = self
        menu.addItem(copyPathItem)

        let openInSubmenu = NSMenu()
        openInSubmenu.autoenablesItems = false
        openInItem.submenu = openInSubmenu
        menu.addItem(openInItem)
        return menu
    }

    /// Resolve the directory to open for a history session: prefer
    /// `cwd`, fall back to `originPath`. Returns nil when neither is set
    /// or the resolved path no longer exists as a directory on disk —
    /// the caller greys out "Open in" in that case.
    private func openablePath(forSessionId sessionId: String) -> String? {
        guard let record = context.sessionManager.records.first(where: { $0.sessionId == sessionId })
        else { return nil }
        guard let candidate = record.cwd ?? record.originPath, !candidate.isEmpty else {
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir),
            isDir.boolValue
        else { return nil }
        return candidate
    }

    /// On-disk path of the session's history JSONL, resolved through the
    /// same `HistoryLoader.locate` the runtime uses (ccterm export →
    /// CLI live file → project-dir scan). Returns nil when no JSONL
    /// exists yet — the caller greys out "Copy Session File Path".
    private func jsonlPath(forSessionId sessionId: String) -> String? {
        let slug = context.sessionManager.records.first { $0.sessionId == sessionId }?.slug
        return HistoryLoader.locate(sessionId: sessionId, slug: slug)?.path
    }

    /// Rebuild the "Open in" submenu for the clicked session. Enabled
    /// only when there's a valid directory and at least one installed
    /// app; otherwise the parent item is left disabled and the submenu
    /// empty.
    private func rebuildOpenInSubmenu(forSessionId sessionId: String) {
        let submenu = openInItem.submenu ?? NSMenu()
        submenu.removeAllItems()

        let path = openablePath(forSessionId: sessionId)
        let targets = context.openInService.targets
        openInItem.isEnabled = path != nil && !targets.isEmpty

        guard let path, !targets.isEmpty else { return }
        for target in targets {
            let item = NSMenuItem(
                title: target.name, action: #selector(openInApp(_:)), keyEquivalent: "")
            item.target = self
            item.image = target.icon
            item.representedObject = OpenInRequest(path: path, target: target)
            submenu.addItem(item)
        }
    }

    /// Captured at submenu-build time so the action handler has both the
    /// directory and the chosen app without re-reading `clickedRow`
    /// (which is no longer valid by the time the item fires).
    private struct OpenInRequest {
        let path: String
        let target: OpenInAppService.Target
    }

    @objc private func openInApp(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? OpenInRequest else { return }
        context.openInService.open(path: request.path, with: request.target)
    }

    // MARK: - Items

    private func rebuildItems() {
        let previousSelection = currentSelection()
        // `build` is pure: it takes the store's persisted order as a
        // snapshot input and returns fresh nodes. New-folder detection and
        // the `prependIfAbsent` writes already ran in `handleRecordsChanged`
        // *before* this call, so `storedOrder()` here reflects any just-
        // prepended folders. `lastSeenGroups` is irrelevant to the nodes,
        // so the returned `newGroups` is ignored on this path.
        let result = SidebarTreeModel.build(
            records: context.sessionManager.records,
            groupOrder: context.groupOrderStore.storedOrder(),
            previouslySeenGroups: lastSeenGroups)
        rootChildren = result.nodes
        outlineView.reloadData()
        expandAllFolders()
        if let selection = previousSelection {
            selectRow(for: selection)
        }
    }

    /// Index range within `rootChildren` that holds folder nodes.
    /// Fixed items occupy the first `FixedKind.allCases.count` indices;
    /// folders follow.
    private var folderRange: Range<Int> {
        let start = FixedKind.allCases.count
        let end = rootChildren.count
        return start..<end
    }

    private func currentSelection() -> MainSelection? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        let item = outlineView.item(atRow: row) as? SidebarItemNode
        return item?.selection
    }

    private func selectRow(for selection: MainSelection) {
        // Walk the visible rows to find the matching selection. Folders
        // aren't selectable so they're skipped naturally.
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? SidebarItemNode,
                node.selection == selection
            else { continue }
            isApplyingSelectionFromModel = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            isApplyingSelectionFromModel = false
            return
        }
    }

    /// Expand every folder synchronously without animation.
    /// `outlineView.expandItem(_:)` (the non-animator form) is already
    /// non-animated by default; an earlier attempt wrapped this in
    /// `NSAnimationContext.runAnimationGroup { duration:0 }` to be safe,
    /// but the wrapper was pure ceremony.
    private func expandAllFolders() {
        for node in rootChildren where node.isFolder {
            outlineView.expandItem(node)
        }
    }

    // MARK: - Selection / records observation

    private func applyModelSelection() {
        if context.model.selection == .none {
            isApplyingSelectionFromModel = true
            outlineView.deselectAll(nil)
            isApplyingSelectionFromModel = false
            return
        }
        selectRow(for: context.model.selection)
    }

    private func startSelectionObservation() {
        selectionObservationTask?.cancel()
        selectionObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { cont in
                withObservationTracking {
                    _ = self.context.model.selection
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
                    // `records` now carries `/new` / `/clear` drafts too (as
                    // `.draft`-status rows), so this single read covers draft
                    // adds, promotions (in-place status flip), and archives.
                    _ = self.context.sessionManager.records
                } onChange: {
                    Task { @MainActor in cont.resume() }
                }
            }
            self.handleRecordsChanged()
            self.startRecordsObservation()
        }
    }

    private func handleRecordsChanged() {
        // Detect groups that appeared since the last refresh. Treat
        // them as "user just created a new project" → prepend to the
        // order store so the new project rides to the top. Cold-start
        // (no prior snapshot) is excluded by initializing
        // `lastSeenGroups` in `viewDidLoad` to the current set.
        //
        // Ordering is load-bearing: `prependIfAbsent` mutates the store's
        // persisted order, and `rebuildItems` reads `storedOrder()` to lay
        // out folders — so the prepends MUST run before `rebuildItems`.
        // Detection itself is the pure `currentGroupSet` helper; `build`
        // only produces nodes here, so the new-folder set is computed
        // separately rather than from `build`'s `newGroups` (which would
        // use the pre-prepend order for its nodes).
        let current = SidebarTreeModel.currentGroupSet(context.sessionManager.records)
        let newlyAppeared = current.subtracting(lastSeenGroups)
        // Sort for a deterministic prepend order. The old code iterated an
        // unordered `Set`; this only changes the relative slot of several
        // groups appearing in one refresh (see SidebarTreeModel notes).
        for name in newlyAppeared.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            context.groupOrderStore.prependIfAbsent(name)
        }
        lastSeenGroups = current
        rebuildItems()
    }

    // MARK: - Click + context menu

    @objc private func handleOutlineClick(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        guard let node = outlineView.item(atRow: row) as? SidebarItemNode else { return }
        if node.isFolder {
            toggleFolder(node)
        }
    }

    private func toggleFolder(_ node: SidebarItemNode) {
        let isExpanded = outlineView.isItemExpanded(node)
        // Call through the animator proxy directly — NSOutlineView
        // attaches its own row insert/remove animation (slide-down for
        // expand, slide-up for collapse). Wrapping this in a manual
        // `NSAnimationContext.runAnimationGroup` with
        // `allowsImplicitAnimation = true` (an earlier attempt) made
        // CoreAnimation layer animations race the row animation and
        // produced the "children fly in from the top of the scrollview"
        // visual glitch.
        if isExpanded {
            outlineView.animator().collapseItem(node)
        } else {
            outlineView.animator().expandItem(node)
        }
        // Eager chevron update so it doesn't lag the slide animation
        // by a frame. `outlineViewItemDidExpand` / `…DidCollapse` (in
        // the delegate extension) is the fallback for state arrived at
        // through other paths (autosave restore, etc).
        let row = outlineView.row(forItem: node)
        if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? SidebarFolderCellView
        {
            cell.setExpanded(!isExpanded, animated: true)
        }
    }

    @objc private func archiveSelectedRow(_ sender: Any?) {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarItemNode else {
            return
        }
        guard case .history(let sessionId, _, _) = node.kind else { return }
        if context.model.selection == .session(sessionId) {
            context.model.select(.newSession)
        }
        context.sessionManager.archive(sessionId)
    }

    @objc private func copySessionFilePath(_ sender: Any?) {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarItemNode else {
            return
        }
        guard case .history(let sessionId, _, _) = node.kind else { return }
        guard let path = jsonlPath(forSessionId: sessionId) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}

// MARK: - DataSource

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return rootChildren.count }
        guard let node = item as? SidebarItemNode else { return 0 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return rootChildren[index] }
        let node = item as! SidebarItemNode
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarItemNode else { return false }
        return node.isFolder
    }

    // MARK: Drag-and-drop

    func outlineView(
        _ outlineView: NSOutlineView, pasteboardWriterForItem item: Any
    ) -> NSPasteboardWriting? {
        guard let node = item as? SidebarItemNode, let name = node.folderName else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(name, forType: SidebarLayout.folderDragType)
        return pb
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // Folder reorder is allowed only at the root level, between
        // children (no "on" drops, no drops into a folder).
        guard item == nil else { return [] }
        guard index != NSOutlineViewDropOnItemIndex else { return [] }
        guard pasteboardFolderName(in: info) != nil else { return [] }
        // Clamp the drop position into the folder range — refuse drops
        // above the fixed top items, even if AppKit proposes them.
        let range = folderRange
        let clamped = max(range.lowerBound, min(index, range.upperBound))
        if clamped != index {
            outlineView.setDropItem(nil, dropChildIndex: clamped)
        }
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let folderName = pasteboardFolderName(in: info) else { return false }
        guard
            let oldIndex = rootChildren.firstIndex(where: { $0.folderName == folderName })
        else { return false }

        let range = folderRange
        var targetIndex = max(range.lowerBound, min(index, range.upperBound))
        // When moving within the same parent, NSOutlineView's
        // childIndex is "where to insert assuming the source is still
        // in place". Adjust for the upcoming removal of the source row
        // when it sits before the target.
        if targetIndex > oldIndex { targetIndex -= 1 }
        guard targetIndex != oldIndex else { return false }

        let node = rootChildren.remove(at: oldIndex)
        rootChildren.insert(node, at: targetIndex)

        outlineView.moveItem(
            at: oldIndex, inParent: nil, to: targetIndex, inParent: nil)

        // Persist the new full order of folder names (not session ids).
        let newOrder = rootChildren.compactMap(\.folderName)
        context.groupOrderStore.replace(with: newOrder)
        return true
    }

    private func pasteboardFolderName(in info: NSDraggingInfo) -> String? {
        info.draggingPasteboard.pasteboardItems?
            .compactMap { $0.string(forType: SidebarLayout.folderDragType) }
            .first
    }
}

// MARK: - Delegate

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
            cell.configure(folderName: name, isExpanded: outlineView.isItemExpanded(node))
            return cell
        case .history(let sessionId, let fallback, let isDraft):
            let cell = SidebarHistoryCellView()
            configureHistoryCell(cell, sessionId: sessionId, fallback: fallback, isDraft: isDraft)
            return cell
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SidebarItemNode else { return SidebarLayout.fixedRowHeight }
        switch node.kind {
        case .fixed: return SidebarLayout.fixedRowHeight
        case .folder: return SidebarLayout.folderRowHeight
        case .history: return SidebarLayout.historyRowHeight
        }
    }

    /// Filter folder rows out of any proposed selection (click, keyboard
    /// navigation, programmatic). When this delegate method is
    /// implemented, NSOutlineView skips the older per-item
    /// `outlineView(_:shouldSelectItem:)` path entirely, so it lives
    /// here alone.
    func outlineView(
        _ outlineView: NSOutlineView,
        selectionIndexesForProposedSelection proposed: IndexSet
    ) -> IndexSet {
        var allowed = IndexSet()
        for row in proposed {
            guard let node = outlineView.item(atRow: row) as? SidebarItemNode else { continue }
            if node.isFolder { continue }
            allowed.insert(row)
        }
        return allowed
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelectionFromModel else { return }
        let row = outlineView.selectedRow
        guard row >= 0,
            let node = outlineView.item(atRow: row) as? SidebarItemNode,
            let selection = node.selection
        else { return }
        if context.model.selection != selection {
            context.model.select(selection)
        }
    }

    // Built-in expand/collapse can be triggered via paths other than
    // our click handler (e.g. accessibility), so sync the chevron from
    // the notification as a backstop.
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarItemNode else { return }
        let row = outlineView.row(forItem: node)
        if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? SidebarFolderCellView
        {
            cell.setExpanded(true, animated: false)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarItemNode else { return }
        let row = outlineView.row(forItem: node)
        if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? SidebarFolderCellView
        {
            cell.setExpanded(false, animated: false)
        }
    }
}

// MARK: - Per-row observation

extension SidebarViewController {
    fileprivate func configureHistoryCell(
        _ cell: SidebarHistoryCellView, sessionId: String, fallback: String, isDraft: Bool
    ) {
        if let earlier = cell.observedSessionId, earlier != sessionId {
            rowObservations[earlier]?.cancel()
            rowObservations[earlier] = nil
        }
        cell.observedSessionId = sessionId
        cell.fallbackTitle = fallback
        cell.isDraftRow = isDraft
        applyHistoryState(cell: cell, sessionId: sessionId, fallback: fallback, isDraft: isDraft)
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
                    let session = controller.context.sessionManager.existingSession(sessionId)
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
                cell: refreshed, sessionId: sessionId, fallback: refreshed.fallbackTitle,
                isDraft: refreshed.isDraftRow)
            controller.armRowObservation(cell: refreshed, sessionId: sessionId)
        }
    }

    private func applyHistoryState(
        cell: SidebarHistoryCellView, sessionId: String, fallback: String, isDraft: Bool
    ) {
        let session = context.sessionManager.existingSession(sessionId)
        // A not-yet-sent `/new` / `/clear` draft is differentiated: it shows a
        // dedicated "New Draft" placeholder (vs the generic "Untitled" used for
        // a real session whose async title-gen hasn't landed) and a dimmed
        // row. `isDraft` is the node-snapshot taken at tree-build time (from
        // the record's `.draft` status), so the marker needs no per-row lookup
        // and works for uncached rows after a cold restart.
        let rawTitle = session?.title ?? fallback
        let displayTitle: String =
            rawTitle.isEmpty
            ? (isDraft ? String(localized: "New Draft") : String(localized: "Untitled"))
            : rawTitle
        cell.configure(
            title: displayTitle,
            isRunning: session?.isRunning ?? false,
            hasUnread: session?.hasUnread ?? false,
            isGeneratingTitle: session?.isGeneratingTitle ?? false,
            isDraft: isDraft)
    }
}

// MARK: - Context menu validation

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = outlineView.clickedRow
        var historySessionId: String?
        if row >= 0,
            let node = outlineView.item(atRow: row) as? SidebarItemNode,
            case .history(let sessionId, _, _) = node.kind
        {
            historySessionId = sessionId
        }
        let allowed = historySessionId != nil
        for item in menu.items { item.isHidden = !allowed }
        if let historySessionId {
            copyPathItem.isEnabled = jsonlPath(forSessionId: historySessionId) != nil
            rebuildOpenInSubmenu(forSessionId: historySessionId)
        }
    }
}

// MARK: - NSOutlineView subclass

/// Suppresses the left-edge disclosure triangle that NSOutlineView
/// otherwise draws for expandable items. The sidebar's folder cells
/// host their own right-edge chevron and own the expand/collapse
/// gesture via `outlineView.action` + `clickedRow`.
private final class NoDisclosureOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
}

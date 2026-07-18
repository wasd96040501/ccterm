import AppKit

/// The history transcript's view controller: builds the `NSScrollView`
/// (host) + `TranscriptTableView`, binds itself as the table's dataSource /
/// delegate, and drives data from the injected `TranscriptStore`. A thin
/// coordinator — all state (rows + layout cache) lives in the store; this
/// VC only maps table callbacks onto store queries and mounts cells.
///
/// Geometry model: the table is a **full-width, frame-based documentView**
/// — the native contract for `NSTableView` (width tracks the clip, height
/// comes from the table's own tile). The centered 460–780 content column
/// lives *inside* each row: widths and origins all come from
/// `TranscriptMetrics`, and the cell clips drawing to the column so no
/// layout can paint outside it.
@MainActor
final class TranscriptViewController: NSViewController {
    private let store: TranscriptStore

    private let scrollView = NSScrollView()
    private let tableView = TranscriptTableView()
    /// Selection state + drag algorithm; the table drives it from its
    /// tracking loop, this VC serves as its row-data surface.
    private let selection = TranscriptSelectionCoordinator()

    /// Last clamped **column** width processed by `tableFrameDidChange`.
    /// Every per-row typeset width derives from this single value, so a
    /// frame change that leaves the clamped column width unchanged — a
    /// resize inside the `>maxLayoutWidth` band, where `layoutOrigin`
    /// re-centers content for free — needs no reflow. Sentinel `-1` won't
    /// match any real width on first run.
    private var lastColumnWidth: CGFloat = -1

    /// The in-flight post-resize refill (`refillLayoutCacheAfterResize`).
    /// Cancelled + superseded by the next resize (or a session switch) so a
    /// fast drag→drag→drag leaves only the last width's refill live.
    private var refillTask: Task<Void, Never>?

    init(store: TranscriptStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        // Selector-based observer — the deterministic-cleanup rule (root
        // CLAUDE.md) wants an explicit `removeObserver`, not a
        // `deinit`-timing gamble; `deinit` here is just the last hop where
        // `self` (the observer) is still valid to unregister.
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - View tree

    override func loadView() {
        let host = NSView()

        // Full-width table — frame-based documentView (no constraints, no
        // translates=false: a table documentView manages its own frame via
        // tile and the clip's autoresize). All per-row centering is
        // expressed by `TranscriptMetrics` inside the row.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("block"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = []

        // Host scroll view.
        scrollView.wantsLayer = true
        scrollView.layerContentsRedrawPolicy = .never
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 56, left: 0, bottom: 112, right: 0)
        // Stock clip view; layer-backed `.never` so scroll ticks composite
        // the cached bitmap instead of re-running draw.
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layerContentsRedrawPolicy = .never
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: host.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])

        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.dataSource = self
        tableView.delegate = self
        selection.rowSource = self
        selection.tableView = tableView
        tableView.selection = selection

        // Width-change driven relayout. The table is a full-width
        // frame-based documentView, so a window / sidebar resize changes
        // `bounds.width` — but AppKit tiles without re-querying `heightOfRow`
        // / `viewFor`, so without this the cached (old-width) row layouts
        // survive: text stops reflowing and rows clip.
        // `frameDidChangeNotification` fires per frame during a live resize.
        tableView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tableFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: tableView)
        tableView.onLiveResizeEnded = { [weak self] in
            self?.refillLayoutCacheAfterResize()
        }
    }

    // MARK: - Presentation

    /// One-shot blocking load of `sessionId`'s history, then anchor to the
    /// tail.
    func present(sessionId: String) {
        refillTask?.cancel()
        selection.clearAll()
        store.load(sessionId: sessionId)
        tableView.reloadData()
        scrollToTail()
    }

    /// Scroll so the last row's bottom sits at the visible content edge.
    func scrollToTail() {
        // First layout pass with the dataSource bound tiles the table at
        // the settled width, so `numberOfRows` / `rect(ofRow:)` are real.
        tableView.layoutSubtreeIfNeeded()
        // Record the settled column width now that the tile has run, so the
        // first real `tableFrameDidChange` after load short-circuits
        // instead of redundantly invalidating every row at the same width.
        let settled = BlockStyle.clampedLayoutWidth(forRowWidth: tableView.bounds.width)
        if tableView.bounds.width > 1 { lastColumnWidth = settled }
        let rowCount = tableView.numberOfRows
        guard rowCount > 0 else { return }
        tableView.scrollRowToVisible(rowCount - 1)
    }

    // MARK: - Width-change driven relayout

    /// Per-frame width tracker. Short-circuits notifications whose clamped
    /// column width didn't move; otherwise invalidates the rows whose
    /// typeset width just changed — **only the visible ones during a live
    /// resize** (bounded per-frame work; off-screen rows keep their stale
    /// layouts, repaired by the post-resize refill) and every row for a
    /// one-off programmatic frame change (sidebar collapse, zoom).
    @objc private func tableFrameDidChange(_ note: Notification) {
        guard tableView.bounds.width > 1 else { return }
        let colWidth = BlockStyle.clampedLayoutWidth(forRowWidth: tableView.bounds.width)
        if colWidth == lastColumnWidth { return }
        lastColumnWidth = colWidth

        let rowCount = tableView.numberOfRows
        guard rowCount > 0 else { return }

        if tableView.inLiveResize {
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.location != NSNotFound, visible.length > 0 else { return }
            invalidate(
                rows: IndexSet(visible.location..<visible.location + visible.length))
        } else {
            invalidate(rows: IndexSet(0..<rowCount))
        }
    }

    /// Re-typeset + re-measure `indexes` at the current width.
    /// `reloadData(forRowIndexes:)` re-runs `viewFor` so each cell picks up
    /// its layout at the new width (the store cache self-heals — a width
    /// mismatch recomputes, no explicit eviction needed);
    /// `noteHeightOfRows` re-queries `heightOfRow` so the row frames resize.
    /// The zero-duration / actions-disabled grouping is the live-resize fix
    /// (NativeTranscript2 §2.10): by default `noteHeightOfRows` animates row
    /// reposition while the cell redraw is synchronous, so during fast drag
    /// a cell paints at the new height while the row below is mid-animation
    /// at the old y and they visibly overlap. Landing both in the same
    /// display cycle removes the ghosting.
    private func invalidate(rows indexes: IndexSet) {
        guard !indexes.isEmpty else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tableView.beginUpdates()
        tableView.reloadData(
            forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
        tableView.endUpdates()
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    // MARK: - Post-resize refill

    /// Live-resize end (NativeTranscript2 §2.7). During the drag only the
    /// visible rows were re-typeset; every off-screen row still holds an
    /// old-width layout + a stale cached height (which would clip when
    /// scrolled to). Recompute those rows at the settled width **off-main**
    /// (so resize-end never runs a CTLine pass inline), then note the new
    /// heights under a visual-top anchor so correcting the above-viewport
    /// rows doesn't jump the content the user is reading.
    private func refillLayoutCacheAfterResize() {
        guard tableView.bounds.width > 1 else { return }
        let rowCount = tableView.numberOfRows
        guard rowCount > 0 else { return }
        let finalColWidth =
            BlockStyle.clampedLayoutWidth(forRowWidth: tableView.bounds.width)
        let width = layoutWidth

        // The rows whose cached width no longer matches the settled width —
        // i.e. the off-screen rows the drag phase skipped (NSTableView
        // eagerly queries every row's height to size the documentView, so
        // every row is cached; the visible ones were kept current each drag
        // frame, so they fall out here).
        var staleRows: [TranscriptRow] = []
        var requests: [(id: UUID, content: TranscriptRow.Content, width: CGFloat)] = []
        for index in 0..<rowCount {
            guard let row = store.row(at: index) else { continue }
            if store.cachedWidth(for: row.id) != width {
                staleRows.append(row)
                requests.append((row.id, row.content, width))
            }
        }
        guard !requests.isEmpty else { return }

        refillTask?.cancel()
        refillTask = Task { [weak self] in
            guard let self else { return }
            await self.store.refillLayouts(requests)
            if Task.isCancelled { return }
            // A newer resize moved the width again → this refill is stale;
            // the newer one's refill owns the cache now. Stale cache entries
            // self-heal on the next `heightOfRow` miss.
            guard
                BlockStyle.clampedLayoutWidth(forRowWidth: self.tableView.bounds.width)
                    == finalColWidth
            else { return }
            self.applyRefilledHeights(for: staleRows)
        }
    }

    /// Re-tile the refilled rows to their corrected heights. The layouts are
    /// already cached (off-main precompute above), so `noteHeightOfRows`'
    /// re-query is a cache hit, not a typeset.
    private func applyRefilledHeights(for rows: [TranscriptRow]) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        withVisualTopAnchor {
            let indexes = rows.compactMap { store.index(for: $0.id) }
            if !indexes.isEmpty {
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(indexes))
                // Force the re-tile now so the anchor restore (run right
                // after this body) reads real `rect(ofRow:)` instead of
                // AppKit's deferred-stale heights — otherwise the pinned row
                // jumps. Cache-hit cheap, since the layouts are warm.
                tableView.layoutSubtreeIfNeeded()
            }
        }
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    /// Run `body` (a height-changing re-tile) while keeping the topmost
    /// visible row pinned to the same on-screen position.
    private func withVisualTopAnchor(_ body: () -> Void) {
        let clip = scrollView.contentView
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0,
            let anchor = store.row(at: visible.location)
        else {
            body()
            return
        }
        // How far the anchor row's top sits below the current scroll origin.
        let delta = tableView.rect(ofRow: visible.location).minY - clip.bounds.origin.y

        body()

        guard let newRow = store.index(for: anchor.id) else { return }
        let targetY = tableView.rect(ofRow: newRow).minY - delta
        let candidate = NSRect(
            origin: CGPoint(x: clip.bounds.origin.x, y: targetY), size: clip.bounds.size)
        let constrained = clip.constrainBoundsRect(candidate)
        guard abs(constrained.origin.y - clip.bounds.origin.y) > 0.5 else { return }
        clip.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Row geometry

    /// The row width every horizontal metric derives from. Before the first
    /// real layout pass the table can still be zero-sized; fall back to the
    /// max column width so early queries stay sane.
    private var rowWidth: CGFloat {
        let width = tableView.bounds.width
        return width > 1 ? width : BlockStyle.maxLayoutWidth
    }

    /// The typeset width for every row — `heightOfRow` and `viewFor` share
    /// this so a row is typeset at exactly one width. Uniform across rows
    /// (the flat transcript has no per-row indentation).
    private var layoutWidth: CGFloat {
        TranscriptMetrics.layoutWidth(forRowWidth: rowWidth)
    }
}

// MARK: - NSTableViewDataSource

extension TranscriptViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        store.numberOfRows
    }
}

// MARK: - NSTableViewDelegate

extension TranscriptViewController: NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let item = store.row(at: row) else { return nil }
        let cell =
            tableView.makeView(
                withIdentifier: TranscriptCellView.reuseIdentifier, owner: self)
            as? TranscriptCellView
            ?? {
                let created = TranscriptCellView(frame: .zero)
                created.identifier = TranscriptCellView.reuseIdentifier
                return created
            }()
        cell.layoutWidth = layoutWidth
        cell.padTop = store.verticalPadding(for: item).top
        cell.layout = store.rowLayout(for: item, width: cell.layoutWidth)
        cell.selection = selection.selection(for: item.id)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let item = store.row(at: row) else { return 1 }
        return store.height(for: item, width: layoutWidth)
    }

    /// Stable row-view reuse key (reuses NativeTranscript2's no-op row view
    /// — centering happens in the cell's `layoutOrigin`, not here).
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("TranscriptRowView")
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self)
            as? CenteredRowView
        {
            return existing
        }
        let rowView = CenteredRowView()
        rowView.identifier = identifier
        return rowView
    }
}

// MARK: - TranscriptSelectionRowSource

extension TranscriptViewController: TranscriptSelectionRowSource {
    func selectionRow(atRow row: Int) -> TranscriptRow? {
        guard row >= 0, row < tableView.numberOfRows else { return nil }
        return store.row(at: row)
    }

    func selectionAdapter(for row: TranscriptRow) -> SelectionAdapter? {
        store.rowLayout(for: row, width: layoutWidth).selectionAdapter
    }

    /// Layout origin of the row's content in document coords — the same
    /// point the cell's `layoutOrigin` resolves to, expressed here off the
    /// row rect so the selection algorithm can convert doc-space drag points
    /// into layout-local positions.
    func selectionContentOrigin(atRow row: Int) -> CGPoint {
        guard let item = selectionRow(atRow: row) else { return .zero }
        let rowRect = tableView.rect(ofRow: row)
        let x = rowRect.minX + TranscriptMetrics.contentX(forRowWidth: rowRect.width)
        let y = rowRect.minY + store.verticalPadding(for: item).top
        return CGPoint(x: x, y: y)
    }

    func selectionMarkNeedsDisplay(rowId: UUID) {
        guard let row = store.index(for: rowId),
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? TranscriptCellView
        else { return }
        cell.selection = selection.selection(for: rowId)
    }
}

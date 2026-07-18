import AppKit

/// The outline transcript's view controller: builds the
/// `NSScrollView` (host) + `TranscriptOutlineView` tree, binds itself as
/// the outline's dataSource / delegate, and drives data from the
/// injected `TranscriptStore`. A thin coordinator — all state (tree +
/// layout cache) lives in the store; this VC only maps outline callbacks
/// onto store queries and mounts cells (SPEC §6.2).
///
/// Geometry model (SPEC §5): the outline is a **full-width, frame-based
/// documentView** — the native contract for `NSTableView`-family views
/// (width tracks the clip, height comes from the table's own tile, so
/// user-driven animated expansion grows the document correctly). The
/// centered 460–780 content column lives *inside* each row: widths and
/// origins all come from `TranscriptOutlineMetrics`, the disclosure
/// triangle is repositioned into the column by
/// `TranscriptOutlineView.frameOfOutlineCell(atRow:)`, and the cell clips
/// drawing to the column so no layout can paint outside it.
@MainActor
final class TranscriptViewController: NSViewController {
    private let store: TranscriptStore

    private let scrollView = NSScrollView()
    private let outlineView = TranscriptOutlineView()
    /// Selection state + drag algorithm; the outline drives it from its
    /// tracking loop, this VC serves as its row-data surface.
    private let selection = TranscriptSelectionCoordinator()

    /// Last clamped **column** width processed by `outlineFrameDidChange`.
    /// Every per-row typeset width derives from this single value (net of
    /// fixed level / chevron insets), so a frame change that leaves the
    /// clamped column width unchanged — a resize inside the `>maxLayoutWidth`
    /// band, where `layoutOrigin` re-centers content for free — needs no
    /// reflow. Sentinel `-1` won't match any real width on first run.
    private var lastColumnWidth: CGFloat = -1

    /// The in-flight post-resize refill (`refillLayoutCacheAfterResize`).
    /// Cancelled + superseded by the next resize so a fast drag→drag→drag
    /// leaves only the last width's refill live.
    private var refillTask: Task<Void, Never>?

    init(store: TranscriptStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        // Selector-based observer — the deterministic-cleanup rule
        // (root CLAUDE.md) wants an explicit `removeObserver`, not a
        // `deinit`-timing gamble; `deinit` here is just the last hop
        // where `self` (the observer) is still valid to unregister.
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - View tree

    override func loadView() {
        let host = NSView()

        // Full-width outline — frame-based documentView (no constraints,
        // no translates=false: a table-family documentView manages its
        // own frame via tile and the clip's autoresize; constraining it
        // is outside its design contract and breaks the height growth
        // path of animated expansion). Native triangle placement is
        // handled by `TranscriptOutlineView`; all per-level indentation
        // is expressed by `TranscriptOutlineMetrics` inside the centered
        // column, so the native per-level cell shift is disabled.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("block"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.backgroundColor = .clear
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .none
        outlineView.usesAutomaticRowHeights = false
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.autoresizesOutlineColumn = false
        outlineView.indentationPerLevel = 0
        outlineView.indentationMarkerFollowsCell = false

        // Host scroll view (SPEC §5).
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
        scrollView.documentView = outlineView
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
        outlineView.dataSource = self
        outlineView.delegate = self
        selection.rowSource = self
        selection.outlineView = outlineView
        outlineView.selection = selection

        // Width-change driven relayout. The outline is a full-width
        // frame-based documentView, so a window / sidebar resize changes
        // `bounds.width` — but AppKit tiles without re-querying
        // `heightOfRowByItem` / `viewFor`, so without this the cached
        // (old-width) row layouts survive: text stops reflowing and rows
        // clip. `frameDidChangeNotification` fires per frame during a live
        // resize (width set synchronously in `setFrameSize`, so the read
        // below is current). Ports NativeTranscript2's `tableFrameDidChange`.
        outlineView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(outlineFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: outlineView)
        outlineView.onLiveResizeEnded = { [weak self] in
            self?.refillLayoutCacheAfterResize()
        }
    }

    // MARK: - Presentation

    /// One-shot blocking load of `sessionId`'s history, then anchor to the
    /// tail. Tool groups start collapsed (the outline's default) so only
    /// top-level user / markdown nodes show initially (SPEC §4).
    func present(sessionId: String) {
        selection.clearAll()
        store.load(sessionId: sessionId)
        outlineView.reloadData()
        scrollToTail()
    }

    /// Scroll so the last row's bottom sits at the visible content edge.
    func scrollToTail() {
        // First layout pass with the dataSource bound tiles the outline at
        // the settled width, so `numberOfRows` / `rect(ofRow:)` are real.
        outlineView.layoutSubtreeIfNeeded()
        // Record the settled column width now that the tile has run, so the
        // first real `outlineFrameDidChange` after load short-circuits
        // instead of redundantly invalidating every row at the same width.
        let settled = BlockStyle.clampedLayoutWidth(forRowWidth: outlineView.bounds.width)
        if outlineView.bounds.width > 1 { lastColumnWidth = settled }
        let rowCount = outlineView.numberOfRows
        guard rowCount > 0 else { return }
        outlineView.scrollRowToVisible(rowCount - 1)
    }

    // MARK: - Width-change driven relayout

    /// Per-frame width tracker. Short-circuits notifications whose clamped
    /// column width didn't move; otherwise invalidates the rows whose
    /// typeset width just changed — **only the visible ones during a live
    /// resize** (bounded per-frame work; off-screen rows keep their stale
    /// layouts, repaired by the post-resize refill) and every row for a
    /// one-off programmatic frame change (sidebar collapse, zoom).
    @objc private func outlineFrameDidChange(_ note: Notification) {
        guard outlineView.bounds.width > 1 else { return }
        let colWidth = BlockStyle.clampedLayoutWidth(forRowWidth: outlineView.bounds.width)
        if colWidth == lastColumnWidth { return }
        lastColumnWidth = colWidth

        let rowCount = outlineView.numberOfRows
        guard rowCount > 0 else { return }

        if outlineView.inLiveResize {
            let visible = outlineView.rows(in: outlineView.visibleRect)
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
    /// `noteHeightOfRows` re-queries `heightOfRowByItem` so the row frames
    /// resize. The zero-duration / actions-disabled grouping is the
    /// live-resize fix (NativeTranscript2 §2.10): by default
    /// `noteHeightOfRows` animates row reposition while the cell redraw is
    /// synchronous, so during fast drag a cell paints at the new height
    /// while the row below is mid-animation at the old y and they visibly
    /// overlap. Landing both in the same display cycle removes the ghosting.
    private func invalidate(rows indexes: IndexSet) {
        guard !indexes.isEmpty else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outlineView.beginUpdates()
        outlineView.reloadData(
            forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
        outlineView.noteHeightOfRows(withIndexesChanged: indexes)
        outlineView.endUpdates()
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
        guard outlineView.bounds.width > 1 else { return }
        let rowCount = outlineView.numberOfRows
        guard rowCount > 0 else { return }
        let finalColWidth =
            BlockStyle.clampedLayoutWidth(forRowWidth: outlineView.bounds.width)

        // The rows whose cached width no longer matches the width they'd
        // typeset at now — i.e. the off-screen rows the drag phase skipped.
        // (NSOutlineView eagerly queries every row's height to size the
        // documentView, so every row is cached; the visible ones were kept
        // current each drag frame, so they fall out here.)
        var staleItems: [TranscriptNodeItem] = []
        var requests: [(id: UUID, content: TranscriptNode.Content, width: CGFloat)] = []
        for row in 0..<rowCount {
            guard let item = outlineView.item(atRow: row) as? TranscriptNodeItem else { continue }
            let width = layoutWidth(for: item)
            if store.cachedWidth(for: item.id) != width {
                staleItems.append(item)
                requests.append((item.id, item.node.content, width))
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
            // self-heal on the next `heightOfRowByItem` miss.
            guard
                BlockStyle.clampedLayoutWidth(forRowWidth: self.outlineView.bounds.width)
                    == finalColWidth
            else { return }
            self.applyRefilledHeights(for: staleItems)
        }
    }

    /// Re-tile the refilled rows to their corrected heights. The layouts are
    /// already cached (off-main precompute above), so `noteHeightOfRows`'
    /// re-query is a cache hit, not a typeset. Row indexes are re-resolved
    /// from the items because the `await` above yielded the main actor (a
    /// user expand/collapse in that window would have shifted rows); dead
    /// items resolve to `-1` and drop out.
    private func applyRefilledHeights(for items: [TranscriptNodeItem]) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        withVisualTopAnchor {
            let rows = items.compactMap { item -> Int? in
                let row = outlineView.row(forItem: item)
                return row >= 0 ? row : nil
            }
            if !rows.isEmpty {
                outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(rows))
                // Force the re-tile now so the anchor restore (run right
                // after this body) reads real `rect(ofRow:)` instead of
                // AppKit's deferred-stale heights — otherwise the pinned row
                // jumps. Cache-hit cheap, since the layouts are warm.
                outlineView.layoutSubtreeIfNeeded()
            }
        }
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    /// Run `body` (a height-changing re-tile) while keeping the topmost
    /// visible row pinned to the same on-screen position — the outline's
    /// equivalent of the old renderer's `.saveVisible(.visualTop)`.
    private func withVisualTopAnchor(_ body: () -> Void) {
        let clip = scrollView.contentView
        let visible = outlineView.rows(in: outlineView.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0,
            let anchor = outlineView.item(atRow: visible.location) as? TranscriptNodeItem
        else {
            body()
            return
        }
        // How far the anchor row's top sits below the current scroll origin.
        let delta = outlineView.rect(ofRow: visible.location).minY - clip.bounds.origin.y

        body()

        let newRow = outlineView.row(forItem: anchor)
        guard newRow >= 0 else { return }
        let targetY = outlineView.rect(ofRow: newRow).minY - delta
        let candidate = NSRect(
            origin: CGPoint(x: clip.bounds.origin.x, y: targetY), size: clip.bounds.size)
        let constrained = clip.constrainBoundsRect(candidate)
        guard abs(constrained.origin.y - clip.bounds.origin.y) > 0.5 else { return }
        clip.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Row geometry

    /// The row width every horizontal metric derives from. Before the
    /// first real layout pass the outline can still be zero-sized; fall
    /// back to the max column width so early queries stay sane.
    private var rowWidth: CGFloat {
        let width = outlineView.bounds.width
        return width > 1 ? width : BlockStyle.maxLayoutWidth
    }

    private func level(of item: TranscriptNodeItem) -> Int {
        max(0, outlineView.level(forItem: item))
    }

    /// The typeset width for a node — `heightOfRowByItem` and `viewFor`
    /// share this so a row is typeset at exactly one width.
    private func layoutWidth(for item: TranscriptNodeItem) -> CGFloat {
        TranscriptOutlineMetrics.layoutWidth(
            forRowWidth: rowWidth, level: level(of: item),
            hasChevronSlot: item.isHeader)
    }
}

// MARK: - NSOutlineViewDataSource

extension TranscriptViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        store.numberOfChildren(of: item as? TranscriptNodeItem)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        store.child(index, of: item as? TranscriptNodeItem)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? TranscriptNodeItem)?.isExpandable ?? false
    }
}

// MARK: - NSOutlineViewDelegate

extension TranscriptViewController: NSOutlineViewDelegate {
    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let node = item as? TranscriptNodeItem else { return nil }
        let cell =
            outlineView.makeView(
                withIdentifier: OutlineBlockCellView.reuseIdentifier, owner: self)
            as? OutlineBlockCellView
            ?? {
                let created = OutlineBlockCellView(frame: .zero)
                created.identifier = OutlineBlockCellView.reuseIdentifier
                return created
            }()
        let nodeLevel = level(of: node)
        cell.level = nodeLevel
        cell.hasChevronSlot = node.isHeader
        cell.layoutWidth = layoutWidth(for: node)
        cell.padTop = store.verticalPadding(for: node, level: nodeLevel).top
        cell.layout = store.rowLayout(for: node, width: cell.layoutWidth)
        cell.selection = selection.selection(for: node.id)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? TranscriptNodeItem else { return 1 }
        return store.height(
            for: node, width: layoutWidth(for: node), level: level(of: node))
    }
}

// MARK: - TranscriptSelectionRowSource

extension TranscriptViewController: TranscriptSelectionRowSource {
    func selectionItem(atRow row: Int) -> TranscriptNodeItem? {
        guard row >= 0, row < outlineView.numberOfRows else { return nil }
        return outlineView.item(atRow: row) as? TranscriptNodeItem
    }

    func selectionAdapter(for item: TranscriptNodeItem) -> SelectionAdapter? {
        store.rowLayout(for: item, width: layoutWidth(for: item)).selectionAdapter
    }

    /// Layout origin of the row's content in document coords — the same
    /// point the cell's `layoutOrigin` resolves to, expressed here off
    /// the row rect so the selection algorithm can convert doc-space
    /// drag points into layout-local positions.
    func selectionContentOrigin(atRow row: Int) -> CGPoint {
        guard let item = selectionItem(atRow: row) else { return .zero }
        let rowRect = outlineView.rect(ofRow: row)
        let nodeLevel = level(of: item)
        let x =
            rowRect.minX
            + TranscriptOutlineMetrics.contentX(
                forRowWidth: rowRect.width, level: nodeLevel,
                hasChevronSlot: item.isHeader)
        let y = rowRect.minY + store.verticalPadding(for: item, level: nodeLevel).top
        return CGPoint(x: x, y: y)
    }

    func selectionMarkNeedsDisplay(itemId: UUID) {
        guard let item = store.item(for: itemId) else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0,
            let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? OutlineBlockCellView
        else { return }
        cell.selection = selection.selection(for: itemId)
    }
}

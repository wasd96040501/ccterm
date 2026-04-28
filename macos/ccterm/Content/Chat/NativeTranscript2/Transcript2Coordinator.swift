import AppKit

/// `NSTableViewDataSource` + `NSTableViewDelegate` for the transcript table.
///
/// Single source of truth: `blocks: [Block]`. Layout is treated as a **pure
/// derivation** of `(block, width)` — `layoutCache` is a memo, not a parallel
/// truth. There is no `rows` mirror, no sync invariant between data and
/// layout, no diff anywhere.
///
/// ### Two orthogonal trigger families
///
/// - **Caller mutation** (`apply(_:)`)
///   `Change` enum carries intent directly: `insert` / `append` / `remove`
///   update `blocks` and notify the table granularly via
///   `insertRows` / `removeRows` / `reloadRows + noteHeightOfRows`.
///   `update` evicts the affected id's cache entry. `replaceAll` clears the
///   cache and `reloadData`s — the bad-case escape hatch. Every code path is
///   O(1) per change in caller-driven structure (cache hits are O(1);
///   `firstIndex`/`enumerated` lookups are O(n) but only over `blocks`,
///   never over a separate cache structure).
///
/// - **Width change** (`tableFrameDidChange`)
///   The cache is keyed by `(id, width)`. When the table's width changes,
///   subsequent lookups miss and lazy-recompute on demand. The frame-change
///   handler only calls `noteHeightOfRows` to make AppKit re-query: live
///   resize bounds it to visible indexes (per-frame work stays bounded
///   regardless of transcript length); other frame changes invalidate all.
///
/// ### Concurrency
///
/// Everything is `@MainActor`. Background producers must hop before calling
/// `apply`. `prefetchAllInBackground` (run from `viewDidEndLiveResize`)
/// computes layouts on a detached task, hops back to main, and merges
/// **only if** the snapshot generation still matches — otherwise drops the
/// result. The merge itself is a cache-write + `noteHeightOfRows` + scroll
/// anchor compensation, so a live resize and a background apply can never
/// observe each other's intermediate state.
@MainActor
final class Transcript2Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var tableView: NSTableView? {
        didSet {
            // If `apply` was called before the table was attached, blocks
            // already exist; the freshly-attached table starts at
            // `numberOfRows = 0` until reloaded.
            if let table = tableView, oldValue !== tableView, !blocks.isEmpty {
                table.reloadData()
            }
        }
    }

    /// Notifies the controller after every successful mutation so SwiftUI
    /// observers on `blockCount` see the new value.
    var onSnapshotChange: ((Int) -> Void)?

    private var blocks: [Block] = []

    /// Memo of `(block, width) -> RowLayout`. Keyed by id so updates and
    /// removes can evict in O(1). The `width` field invalidates the entry
    /// when the table width changes — lookups at a different width treat the
    /// entry as a miss and overwrite it on recompute, so the cache never
    /// holds layouts at multiple widths simultaneously.
    private var layoutCache: [UUID: CachedLayout] = [:]

    private struct CachedLayout {
        let width: CGFloat
        let layout: RowLayout
    }

    /// Bumped on every `apply`. The background prefetch task captures it at
    /// start and validates against it before merging — covers all mutation
    /// kinds (insert / remove / update / replaceAll) with a single Int
    /// equality check.
    private var generation: UInt64 = 0
    private var prefetchTask: Task<Void, Never>?

    // MARK: - Read-only snapshot

    var blockCount: Int { blocks.count }
    var blockIds: [UUID] { blocks.map(\.id) }

    func block(at index: Int) -> Block? {
        blocks.indices.contains(index) ? blocks[index] : nil
    }

    func block(id: UUID) -> Block? {
        blocks.first { $0.id == id }
    }

    // MARK: - Mutation

    func apply(_ changes: [Transcript2Controller.Change]) {
        prefetchTask?.cancel()
        prefetchTask = nil
        generation &+= 1

        let table = tableView
        // Granular changes are wrapped in a single beginUpdates / endUpdates
        // so AppKit batches animations and height invalidations. `replaceAll`
        // closes any open transaction and runs as a standalone reload.
        var inBatch = false
        for change in changes {
            switch change {
            case .replaceAll:
                if inBatch { table?.endUpdates(); inBatch = false }
                applyChange(change, in: table)
            default:
                if !inBatch, let table { table.beginUpdates(); inBatch = true }
                applyChange(change, in: table)
            }
        }
        if inBatch { table?.endUpdates() }

        onSnapshotChange?(blocks.count)
    }

    private func applyChange(_ change: Transcript2Controller.Change,
                             in table: NSTableView?) {
        switch change {
        case .insert(let at, let new):
            let idx = max(0, min(at, blocks.count))
            blocks.insert(contentsOf: new, at: idx)
            table?.insertRows(at: IndexSet(idx ..< idx + new.count),
                              withAnimation: [.effectFade])

        case .append(let new):
            let idx = blocks.count
            blocks.append(contentsOf: new)
            table?.insertRows(at: IndexSet(idx ..< idx + new.count),
                              withAnimation: [.effectFade])

        case .remove(let ids):
            let idSet = Set(ids)
            var indexes = IndexSet()
            for (i, b) in blocks.enumerated() where idSet.contains(b.id) {
                indexes.insert(i)
            }
            guard !indexes.isEmpty else { return }
            for i in indexes.reversed() { blocks.remove(at: i) }
            for id in idSet { layoutCache.removeValue(forKey: id) }
            table?.removeRows(at: indexes, withAnimation: [.effectFade])

        case .update(let id, let kind):
            guard let i = blocks.firstIndex(where: { $0.id == id }) else { return }
            blocks[i] = Block(id: id, kind: kind)
            layoutCache.removeValue(forKey: id)
            let idx = IndexSet(integer: i)
            table?.reloadData(forRowIndexes: idx,
                              columnIndexes: IndexSet(integer: 0))
            table?.noteHeightOfRows(withIndexesChanged: idx)

        case .replaceAll(let next):
            blocks = next
            layoutCache.removeAll(keepingCapacity: true)
            table?.reloadData()
        }
    }

    // MARK: - Lazy layout

    private func layout(for block: Block, width: CGFloat) -> RowLayout {
        if let cached = layoutCache[block.id], cached.width == width {
            return cached.layout
        }
        let layout = Self.makeLayout(for: block, width: width)
        layoutCache[block.id] = CachedLayout(width: width, layout: layout)
        return layout
    }

    /// Pure: `(block, width) -> RowLayout`. `nonisolated static` so the
    /// background prefetch task can call it off-MainActor.
    nonisolated static func makeLayout(for block: Block, width: CGFloat) -> RowLayout {
        let contentWidth = max(0, width - 2 * BlockStyle.blockHorizontalPadding)
        switch block.kind {
        case .heading(let text):
            return .text(TextLayout.make(
                attributed: BlockStyle.headingAttributed(text),
                maxWidth: contentWidth))
        case .paragraph(let text):
            return .text(TextLayout.make(
                attributed: BlockStyle.paragraphAttributed(text),
                maxWidth: contentWidth))
        case .image(let image):
            return .image(ImageLayout.make(
                image: image,
                maxWidth: contentWidth,
                maxHeight: BlockStyle.imageMaxHeight))
        }
    }

    // MARK: - Width-change driven invalidation

    @objc func tableFrameDidChange(_ note: Notification) {
        guard let tableView, !blocks.isEmpty else { return }
        if tableView.inLiveResize {
            // Bounded per-frame layout work: only invalidate visible rows.
            // Off-screen rows keep their stale heights and stale cached
            // layouts — invisible to the user and repaired by the
            // post-resize background prefetch.
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.location != NSNotFound, visible.length > 0 else { return }
            invalidate(rows: IndexSet(visible.location ..< visible.location + visible.length),
                       in: tableView)
        } else {
            // Outside live resize, frame changes are programmatic / one-off
            // (initial layout, window animation). Invalidate everything;
            // AppKit re-queries lazily on next layout pass.
            invalidate(rows: IndexSet(0 ..< blocks.count), in: tableView)
        }
    }

    /// `reloadData(forRowIndexes:)` re-runs `viewFor` so the cell picks up
    /// the layout at the current width; `noteHeightOfRows` tells AppKit to
    /// re-query `heightOfRow` so cell frames resize. Both are needed —
    /// dropping `reloadData(forRowIndexes:)` leaves visible cells holding
    /// the old `RowLayout` (drawn at old width) inside a newly-resized
    /// frame, so glyphs land at the wrong x positions during a live resize.
    private func invalidate(rows indexes: IndexSet, in tableView: NSTableView) {
        guard !indexes.isEmpty else { return }
        tableView.beginUpdates()
        tableView.reloadData(forRowIndexes: indexes,
                             columnIndexes: IndexSet(integer: 0))
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
        tableView.endUpdates()
    }

    // MARK: - Background prefetch (post-live-resize)

    func prefetchAllInBackground() {
        guard let tableView else { return }
        let width = effectiveContentWidth(of: tableView)
        guard width > 0 else { return }
        // Skip if every entry is already at this width — common case when
        // resize ended at the start width with no actual change.
        if blocks.allSatisfy({ layoutCache[$0.id]?.width == width }) { return }

        prefetchTask?.cancel()
        let snapshot = blocks
        let snapshotGen = generation
        prefetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var precomputed: [(UUID, RowLayout)] = []
            precomputed.reserveCapacity(snapshot.count)
            for block in snapshot {
                if Task.isCancelled { return }
                precomputed.append((block.id, Self.makeLayout(for: block, width: width)))
            }
            if Task.isCancelled { return }
            await MainActor.run { [precomputed] in
                self?.applyPrefetch(precomputed, width: width, snapshotGen: snapshotGen)
            }
        }
    }

    private func applyPrefetch(_ entries: [(UUID, RowLayout)],
                               width: CGFloat,
                               snapshotGen: UInt64) {
        guard let tableView else { return }
        // Width drifted again before completion — discard.
        guard effectiveContentWidth(of: tableView) == width else { return }
        // Any apply landed in flight — discard. O(1) check covers all
        // mutation kinds (insert / remove / update / replaceAll).
        guard generation == snapshotGen else { return }

        // Anchor a visible row before invalidating heights. Off-screen rows
        // had stale layouts (and therefore stale heights cached by AppKit
        // from prior `heightOfRow` answers) during live resize; correcting
        // those heights now shifts every row's Y, so we compensate the
        // scroll offset by the anchor's doc-Y delta to keep the visible
        // content visually fixed. Same approach as Telegram's
        // `saveScrollState` in `TableView.layoutItems()`.
        let scrollView = tableView.enclosingScrollView
        let visible = tableView.rows(in: tableView.visibleRect)
        let anchor: (row: Int, oldDocY: CGFloat, oldScrollY: CGFloat)?
        if let scrollView, visible.location != NSNotFound, visible.length > 0 {
            anchor = (
                row: visible.location,
                oldDocY: tableView.rect(ofRow: visible.location).origin.y,
                oldScrollY: scrollView.contentView.bounds.origin.y)
        } else {
            anchor = nil
        }

        // Atomically install prefetched layouts then invalidate AppKit's
        // height cache. Wrapped in a disabled-animation transaction so the
        // height correction and the scroll compensation land in the same
        // commit (without this, two implicit animations would race: the
        // row-height transition (~0.2s default) and the layer-backed
        // ClipView's bounds.origin animation from `scroll(to:)`).
        for (id, layout) in entries {
            layoutCache[id] = CachedLayout(width: width, layout: layout)
        }

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0 ..< blocks.count))

        if let anchor, let scrollView {
            let newDocY = tableView.rect(ofRow: anchor.row).origin.y
            let delta = newDocY - anchor.oldDocY
            if abs(delta) > 0.5 {
                scrollView.contentView.scroll(
                    to: NSPoint(x: scrollView.contentView.bounds.origin.x,
                                y: anchor.oldScrollY + delta))
            }
        }

        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { blocks.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard blocks.indices.contains(row) else { return 1 }
        let width = effectiveContentWidth(of: tableView)
        return layout(for: blocks[row], width: width).totalHeight
            + 2 * BlockStyle.blockVerticalPadding
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard blocks.indices.contains(row) else { return nil }
        let width = effectiveContentWidth(of: tableView)
        let cellLayout = layout(for: blocks[row], width: width)

        let id = NSUserInterfaceItemIdentifier("BlockCell")
        let cell: BlockCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? BlockCellView {
            cell = reused
        } else {
            cell = BlockCellView()
            cell.identifier = id
        }
        cell.layout = cellLayout
        return cell
    }

    // MARK: - Helpers

    private func effectiveContentWidth(of tableView: NSTableView) -> CGFloat {
        // The single column has `.autoresizingMask` so NSTableView keeps its
        // width in sync with available space.
        tableView.tableColumns.first?.width ?? 0
    }
}

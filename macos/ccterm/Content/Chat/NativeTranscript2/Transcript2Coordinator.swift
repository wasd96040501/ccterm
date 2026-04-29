import AppKit

/// `NSTableViewDataSource` + `NSTableViewDelegate` for the transcript table.
///
/// Single source of truth: `blocks: [Block]`. Layout is treated as a **pure
/// derivation** of `(block, width)` — `layoutCache` is a memo, not a parallel
/// truth. There is no `rows` mirror, no sync invariant between data and
/// layout, no diff anywhere.
///
/// ### Mutation paths
///
/// - **`apply(_:scroll:)`** — sync. Layouts compute lazily on `heightOfRow`
///   queries. Used for incremental updates (live messages, single removals,
///   tool-result updates).
/// - **`applyInBackground(_:scroll:)`** — layouts for the inserted blocks
///   compute on a detached `Task`, then a main hop installs them and runs
///   the structural change in one shot. Used by `Controller.loadInitial`'s
///   Phase 2 (large prepend after the viewport batch is already visible).
///
/// Both paths run their structural change inside `withScrollAdjustment`,
/// which interprets `ScrollState`:
/// - `.none` — no scroll work.
/// - `.top(id)` / `.bottom(id)` — direct scroll-to-position after the change.
/// - `.saveVisible(side)` — capture an anchor row's screen position before,
///   compensate scroll origin after so the row stays visually fixed across
///   the structural change. Same trick as Telegram's `saveScrollState` in
///   `TableView.layoutItems()`.
///
/// ### Width change (resize)
///
/// `layoutCache` is keyed by `(id, width)`. When the table width changes,
/// existing entries become misses and lazy-recompute. `tableFrameDidChange`
/// invalidates rows; live resize bounds work to visible rows;
/// `refillLayoutCache` (post-resize) reuses the same async pipeline
/// (`precomputeLayoutsInBackground` → `cacheLayouts` → `noteHeightOfRows`
/// under `.saveVisible(.visualTop)`).
///
/// ### Concurrency
///
/// Everything is `@MainActor`. Two distinct off-main lifecycles, kept
/// apart on purpose because their AppKit semantics differ:
///
/// - **`cacheRefillTask`** — `tableFrameDidChange` post-resize refill.
///   `numberOfRows` doesn't change; the only effect is to populate
///   `layoutCache` at the new width and `noteHeightOfRows` the rows whose
///   heights moved. Superseded only by the next `refillLayoutCache`. Loss is
///   CPU only — `heightOfRow` lazy-recomputes.
///
/// - **`applyInBackground`'s detached task** — row-mutation precompute.
///   Fire-and-forget, *not* tracked by a field, *not* cancellable: the
///   `insertRows` it carries is `dataSource`-changing critical work and
///   has to land. `Change.insert` resolves its anchor by id at apply-time,
///   so landing is robust against inflight `apply`s in between.
///
/// Cache anti-poison sits inside `cacheLayouts`: a write skips entries
/// already fresh at the same width, so an inflight task hopping in *after*
/// `apply .update`/`.remove` evicted and lazy-refilled an entry can't
/// overwrite the authoritative fresh layout with its older snapshot.
///
/// On top of that, a `mutationCounter` snapshot lets the refill task
/// drop its entire onMain block (including `noteHeightOfRows` and
/// `saveVisible`) when an `apply` ran during the task — running
/// `saveVisible` against stale AppKit heights (deferred re-query) would
/// otherwise jitter the anchor row.
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
    var onBlockCountChanged: ((Int) -> Void)?

    /// Cross-row text selection. Owns the selection dict; reads back into
    /// us through the helpers below (`block(atRow:)`, `textLayout(atRow:)`,
    /// `attributedString(forBlockId:)`, `markCellNeedsDisplay(blockId:)`).
    let selection: Transcript2SelectionCoordinator

    override init() {
        self.selection = Transcript2SelectionCoordinator()
        super.init()
        self.selection.transcript = self
    }

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

    /// Tracks the `tableFrameDidChange` post-resize layout refill task.
    /// Superseded only by the next `refillLayoutCache`. `applyInBackground`'s
    /// detached task is intentionally *not* stored here — it's
    /// fire-and-forget so an in-flight row-mutation can't be interrupted
    /// by an unrelated cancel path.
    private var cacheRefillTask: Task<Void, Never>?

    /// Bumped on every `apply`. The refill task captures it at start; if
    /// it drifts during the task run, the entire onMain block (cache
    /// writes, `noteHeightOfRows`, `saveVisible`) is dropped. Reason: the
    /// `saveVisible` anchor math relies on AppKit re-querying heights for
    /// rows we just `noteHeightOfRows`'d, but that re-query is deferred
    /// to the next layout pass — so running `applyAnchor` immediately
    /// after compensates against stale internal heights and the row
    /// visually jumps when AppKit eventually catches up. Skipping refill
    /// in this case is harmless: `apply`'s own scroll already settled the
    /// post-mutation state, and `heightOfRow` lazy-fills missing layouts
    /// on demand. `applyInBackground` doesn't bump because its own
    /// row-mutation is the change-event for its own scroll handling.
    private var mutationCounter: UInt64 = 0

    // MARK: - Read-only snapshot

    var blockIds: [UUID] { blocks.map(\.id) }

    /// Width that rows are laid out at — clamped to
    /// `BlockStyle.[min,max]LayoutWidth`. Driven by the single column's
    /// `.autoresizingMask` (which tracks the table width). Returns 0 if
    /// the table isn't attached or hasn't been sized yet.
    ///
    /// Clamping here is the single source of truth: `makeLayout` sees the
    /// clamped width, `layoutCache` keys on it, and `CenteredRowView` /
    /// `Transcript2SelectionCoordinator` both consume `BlockStyle`'s
    /// helpers to stay in sync. Window resizes that don't cross the
    /// clamp boundary land on the same cache entry — no relayout.
    var layoutWidth: CGFloat {
        guard let raw = tableView?.tableColumns.first?.width, raw > 0 else { return 0 }
        return BlockStyle.clampedLayoutWidth(forRowWidth: raw)
    }

    /// Last `layoutWidth` we processed in `tableFrameDidChange`. Used to
    /// short-circuit notifications whose underlying column-width change
    /// didn't move the clamped value (resize within the >max band).
    /// Sentinel `-1` will not match any real width on first run.
    private var lastLayoutWidth: CGFloat = -1

    /// Visible-region height of the enclosing scroll view. Returns 0 if
    /// no scroll view is attached.
    var viewportHeight: CGFloat {
        tableView?.enclosingScrollView?.contentView.bounds.height ?? 0
    }

    private var transcriptScrollView: Transcript2ScrollView? {
        tableView?.enclosingScrollView as? Transcript2ScrollView
    }

    /// Forwarders for `Transcript2ScrollView`'s scroller-hidden refcount.
    /// Silently no-op when no scroll view is attached — push/pop balance
    /// holds because both will no-op together.
    func pushScrollerHidden() { transcriptScrollView?.pushScrollerHidden() }
    func popScrollerHidden()  { transcriptScrollView?.popScrollerHidden() }

    // MARK: - Mutation: sync

    func apply(_ changes: [Transcript2Controller.Change],
               scroll: Transcript2Controller.ScrollState = .none) {
        // Bump so any inflight `cacheRefillTask` discards its onMain on
        // hop. We don't cancel here: the counter is the actual guard, and
        // `cacheRefillTask` polices its own lifetime via the next
        // `refillLayoutCache`. Discarding refill in this window matters
        // because its `saveVisible` would compensate against stale AppKit
        // heights (deferred re-query) — running on top of `apply`'s own
        // settled scroll would jitter the anchor row.
        mutationCounter &+= 1

        let table = tableView
        if let table {
            withScrollAdjustment(scroll, in: table) {
                table.beginUpdates()
                for change in changes {
                    applyStructuralChange(change, in: table)
                }
                table.endUpdates()
            }
        } else {
            // Table not attached. Just mutate `blocks`; future attach will
            // `reloadData()`. Scroll state is meaningless without a table.
            for change in changes {
                applyStructuralChange(change, in: nil)
            }
        }

        onBlockCountChanged?(blocks.count)
    }

    // MARK: - Mutation: off-main (Phase 2 of loadInitial, future use cases)

    /// Layouts for the inserted blocks compute on a detached task; a single
    /// main hop installs them and runs the structural changes under
    /// `scroll`.
    ///
    /// **Fire-and-forget.** The task is not tracked and not cancellable:
    /// row-mutation is `dataSource` critical-path work that must land.
    /// `Change.insert`'s id-based anchor resolves at apply-time, so
    /// landing stays correct across any `apply`s that ran in between.
    /// Layout entries enter the cache only on width match; a drifted
    /// width keeps the row-mutation but skips the cache write
    /// (`heightOfRow` lazy-recomputes at the new width).
    ///
    /// `completion` fires on main exactly once, in every outcome
    /// (succeeded, table-detached, zero-width). Callers use it to balance
    /// paired lifecycle work (e.g. scroller push/pop) that must survive
    /// the async hop.
    func applyInBackground(_ changes: [Transcript2Controller.Change],
                           scroll: Transcript2Controller.ScrollState,
                           completion: @MainActor @escaping () -> Void = {}) {
        guard tableView != nil else { completion(); return }
        let width = layoutWidth
        guard width > 0 else { completion(); return }

        // Only `.insert` carries new blocks; `.remove` / `.update` either
        // don't add layouts or evict them. `.update`'s replacement layout
        // is computed lazily by `applyStructuralChange` after the main hop.
        let toCompute: [Block] = changes.flatMap { change -> [Block] in
            if case .insert(_, let blocks) = change { return blocks }
            return []
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            var entries: [(UUID, RowLayout)] = []
            entries.reserveCapacity(toCompute.count)
            for block in toCompute {
                entries.append((block.id, Self.makeLayout(for: block, width: width)))
            }
            await MainActor.run { [entries] in
                defer { completion() }
                guard let self, let table = self.tableView else { return }
                self.withScrollAdjustment(scroll, in: table) {
                    if self.layoutWidth == width {
                        self.cacheLayouts(entries, width: width)
                    }
                    table.beginUpdates()
                    for change in changes {
                        self.applyStructuralChange(change, in: table)
                    }
                    table.endUpdates()
                }
                self.onBlockCountChanged?(self.blocks.count)
            }
        }
    }

    // MARK: - Structural change (mechanical, no scroll, no scheduling)

    private func applyStructuralChange(_ change: Transcript2Controller.Change,
                                       in table: NSTableView?) {
        switch change {
        case .insert(let after, let new):
            guard !new.isEmpty else { return }
            let idx: Int
            if let after {
                guard let i = blocks.firstIndex(where: { $0.id == after }) else { return }
                idx = i + 1
            } else {
                idx = 0
            }
            blocks.insert(contentsOf: new, at: idx)
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
            for id in idSet {
                removeCachedLayout(for: id)
                selection.dropEntry(blockId: id)
            }
            table?.removeRows(at: indexes, withAnimation: [.effectFade])

        case .update(let id, let kind):
            guard let i = blocks.firstIndex(where: { $0.id == id }) else { return }
            blocks[i] = Block(id: id, kind: kind)
            removeCachedLayout(for: id)
            // Content replacement invalidates the prior selection range
            // (offsets no longer index into the same string). Drop now so
            // the upcoming `reloadData(forRowIndexes:)` runs viewFor with
            // a clean empty selection on the recycled cell.
            selection.dropEntry(blockId: id)
            let idx = IndexSet(integer: i)
            table?.reloadData(forRowIndexes: idx,
                              columnIndexes: IndexSet(integer: 0))
            table?.noteHeightOfRows(withIndexesChanged: idx)
        }
    }

    // MARK: - Scroll adjustment

    /// Wraps a structural-change closure with the requested scroll behavior.
    /// `.saveVisible` disables implicit animations so the height/insert
    /// transition doesn't race with the scroll-origin compensation.
    private func withScrollAdjustment(_ scroll: Transcript2Controller.ScrollState,
                                      in tableView: NSTableView,
                                      body: () -> Void) {
        switch scroll {
        case .none:
            body()
        case .top(let id):
            body()
            scrollRowToTop(id: id, in: tableView)
        case .bottom(let id):
            body()
            scrollRowToBottom(id: id, in: tableView)
        case .saveVisible(let side):
            let anchor = captureAnchor(side: side, in: tableView)
            // Disable both NSAnimationContext (row-height transition) and
            // CATransaction (layer-backed ClipView's bounds.origin animation
            // from `scroll(to:)`) so they don't race.
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            body()
            if let anchor { applyAnchor(anchor, in: tableView) }
            CATransaction.commit()
            NSAnimationContext.endGrouping()
        }
    }

    private struct ScrollAnchor {
        let blockId: UUID
        /// `rect.origin.y` for `.visualTop`, `rect.maxY` for `.visualBottom`.
        let oldRefY: CGFloat
        let oldScrollY: CGFloat
        let side: Transcript2Controller.ScrollState.Side
    }

    private func captureAnchor(side: Transcript2Controller.ScrollState.Side,
                               in tableView: NSTableView) -> ScrollAnchor? {
        guard let scrollView = tableView.enclosingScrollView else { return nil }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return nil }

        // NSTableView is flipped (default): smallest visible row index = top
        // of viewport; largest = bottom.
        let anchorRow: Int
        switch side {
        case .visualTop:
            anchorRow = visible.location
        case .visualBottom:
            anchorRow = visible.location + visible.length - 1
        }
        guard blocks.indices.contains(anchorRow) else { return nil }
        let rect = tableView.rect(ofRow: anchorRow)
        let refY: CGFloat = (side == .visualTop) ? rect.origin.y : rect.maxY
        return ScrollAnchor(
            blockId: blocks[anchorRow].id,
            oldRefY: refY,
            oldScrollY: scrollView.contentView.bounds.origin.y,
            side: side)
    }

    private func applyAnchor(_ anchor: ScrollAnchor, in tableView: NSTableView) {
        guard let scrollView = tableView.enclosingScrollView else { return }
        guard let newRow = blocks.firstIndex(where: { $0.id == anchor.blockId }) else {
            return
        }
        let newRect = tableView.rect(ofRow: newRow)
        let newRefY: CGFloat = (anchor.side == .visualTop) ? newRect.origin.y : newRect.maxY
        let delta = newRefY - anchor.oldRefY
        if abs(delta) > 0.5 {
            scrollView.contentView.scroll(
                to: NSPoint(x: scrollView.contentView.bounds.origin.x,
                            y: anchor.oldScrollY + delta))
        }
    }

    private func scrollRowToTop(id: UUID, in tableView: NSTableView) {
        guard let row = blocks.firstIndex(where: { $0.id == id }),
              let scrollView = tableView.enclosingScrollView else { return }
        let target = tableView.rect(ofRow: row).origin.y
        scrollView.contentView.scroll(
            to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: target))
    }

    private func scrollRowToBottom(id: UUID, in tableView: NSTableView) {
        guard let row = blocks.firstIndex(where: { $0.id == id }),
              let scrollView = tableView.enclosingScrollView else { return }
        let rect = tableView.rect(ofRow: row)
        let viewportH = scrollView.contentView.bounds.height
        let target = max(0, rect.maxY - viewportH)
        scrollView.contentView.scroll(
            to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: target))
    }

    // MARK: - Layout cache

    /// All access to `layoutCache` goes through these helpers and the lazy
    /// `layout(for:width:)` path below. Direct subscripting from elsewhere
    /// is banned by convention so the width invariant and the "evict on
    /// input change" discipline have a single audit point.

    /// Writes precomputed layouts into the cache. Skips an entry if a
    /// fresh layout at the same width is already present —— that means the
    /// sync `apply` path has run `removeCachedLayout` + a layout pass
    /// since this batch was computed, and the lazy re-fill it triggered
    /// is the authoritative entry. Overwriting it with our (older
    /// snapshot's) layout would poison the cache.
    private func cacheLayouts(_ entries: [(UUID, RowLayout)], width: CGFloat) {
        for (id, layout) in entries {
            if layoutCache[id]?.width == width { continue }
            layoutCache[id] = CachedLayout(width: width, layout: layout)
        }
    }

    private func removeCachedLayout(for id: UUID) {
        layoutCache.removeValue(forKey: id)
    }

    private func indexesNeedingLayoutRefresh(at width: CGFloat) -> [Int] {
        blocks.indices.filter { layoutCache[blocks[$0].id]?.width != width }
    }

    // MARK: - Lazy layout (heightOfRow / viewFor)

    private func layout(for block: Block, width: CGFloat) -> RowLayout {
        if let c = layoutCache[block.id], c.width == width {
            return c.layout
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
        case .heading(let level, let inlines):
            return .text(TextLayout.make(
                attributed: BlockStyle.headingAttributed(level: level, inlines: inlines),
                maxWidth: contentWidth))
        case .paragraph(let inlines):
            return .text(TextLayout.make(
                attributed: BlockStyle.paragraphAttributed(inlines: inlines),
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
        // Resizes inside the >max clamp band leave `layoutWidth` unchanged.
        // `CenteredRowView.layout()` still re-runs (driven by NSTableView's
        // tile pass) and repositions the cell horizontally, but no row needs
        // its layout invalidated — so skip the reload/noteHeightOfRows pair.
        let width = layoutWidth
        if width == lastLayoutWidth { return }
        lastLayoutWidth = width
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
    ///
    /// The no-animation grouping is the live-resize fix: by default
    /// `noteHeightOfRows` repositions rows below via an implicit
    /// NSAnimationContext / CATransaction animation, while cell-internal
    /// redraw is synchronous (`needsDisplay = true` in `layout` setter).
    /// During fast resize the cell already paints at the new height while
    /// the row below is still mid-animation at its old y — visually the
    /// rows overlap. Zeroing duration and disabling layer actions makes
    /// row repositioning land in the same display cycle as the redraw.
    /// Mirrors Telegram's `TableView.layoutIfNeeded(with:oldWidth:)` →
    /// `noteHeightOfRow(_:false)` path, which does the same suppression.
    private func invalidate(rows indexes: IndexSet, in tableView: NSTableView) {
        guard !indexes.isEmpty else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tableView.beginUpdates()
        tableView.reloadData(forRowIndexes: indexes,
                             columnIndexes: IndexSet(integer: 0))
        tableView.noteHeightOfRows(withIndexesChanged: indexes)
        tableView.endUpdates()
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    // MARK: - Background prefetch (post-live-resize)

    func refillLayoutCache() {
        guard let tableView else { return }
        let width = layoutWidth
        guard width > 0 else { return }
        let staleIdxs = indexesNeedingLayoutRefresh(at: width)
        // Empty → fully cached at this width. Common case when resize
        // ended at the start width with no actual change. No push
        // happened, so no pop needed.
        guard !staleIdxs.isEmpty else { return }

        let snapshot = staleIdxs.map { blocks[$0] }
        let snapshotCounter = mutationCounter
        // Push covers the async layout window so the scroller stays hidden
        // through the post-resize relayout. Popped via the task's defer in
        // every outcome (cancelled, drifted, succeeded).
        pushScrollerHidden()

        cacheRefillTask?.cancel()
        cacheRefillTask = Task.detached(priority: .userInitiated) { [weak self] in
            var entries: [(UUID, RowLayout)] = []
            entries.reserveCapacity(snapshot.count)
            var aborted = false
            for block in snapshot {
                if Task.isCancelled { aborted = true; break }
                entries.append((block.id, Self.makeLayout(for: block, width: width)))
            }
            await MainActor.run { [entries] in
                defer { self?.popScrollerHidden() }
                if aborted { return }
                guard let self, let table = self.tableView,
                      self.layoutWidth == width else { return }
                // mutationCounter drift → an `apply` ran during the task.
                // Skip the entire onMain (cache writes, noteHeightOfRows,
                // saveVisible). Reason: noteHeightOfRows is deferred to
                // the next layout pass, so `applyAnchor` would run
                // against AppKit's still-stale internal heights and
                // produce a wrong scroll compensation; the row visually
                // jumps when AppKit eventually re-queries. `apply` has
                // already settled its own scroll, and `heightOfRow` will
                // lazy-fill the layouts as needed.
                guard self.mutationCounter == snapshotCounter else { return }
                // applyInBackground (fire-and-forget, counter-untracked)
                // may have shifted indices. Re-resolve via id so
                // noteHeightOfRows targets the current dataSource state.
                let idxs = entries.compactMap { (id, _) -> Int? in
                    self.blocks.firstIndex { $0.id == id }
                }
                self.withScrollAdjustment(.saveVisible(.visualTop), in: table) {
                    self.cacheLayouts(entries, width: width)
                    if !idxs.isEmpty {
                        table.noteHeightOfRows(withIndexesChanged: IndexSet(idxs))
                    }
                }
            }
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { blocks.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard blocks.indices.contains(row) else { return 1 }
        let width = layoutWidth
        return layout(for: blocks[row], width: width).totalHeight
            + 2 * BlockStyle.blockVerticalPadding
    }

    func tableView(_ tableView: NSTableView,
                   rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("BlockRow")
        if let reused = tableView.makeView(withIdentifier: id, owner: self)
            as? CenteredRowView
        {
            return reused
        }
        let view = CenteredRowView()
        view.identifier = id
        return view
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard blocks.indices.contains(row) else { return nil }
        let width = layoutWidth
        let block = blocks[row]
        let cellLayout = layout(for: block, width: width)

        let id = NSUserInterfaceItemIdentifier("BlockCell")
        let cell: BlockCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? BlockCellView {
            cell = reused
        } else {
            cell = BlockCellView()
            cell.identifier = id
        }
        cell.layout = cellLayout
        // Selection is keyed by block id, not by cell instance, so a
        // recycled cell scrolling onto a row that already had a selection
        // picks up the existing range here. Empty range = no highlight.
        cell.blockId = block.id
        cell.selectedRange = selection.selection(for: block.id)
            ?? NSRange(location: 0, length: 0)
        return cell
    }

    // MARK: - Selection helpers (consumed by SelectionCoordinator)

    /// Block at `row`, or `nil` if out of bounds. Selection-side reads
    /// must accept "no block here" because `applyInBackground`'s
    /// fire-and-forget hop can shrink `blocks` between the caller's
    /// row resolution and this read.
    func block(atRow row: Int) -> Block? {
        blocks.indices.contains(row) ? blocks[row] : nil
    }

    /// Block by id. Linear scan — selection paths touch ≤ N blocks, the
    /// dict-keyed lookup elsewhere is `layoutCache`'s job, not this one.
    func block(forId id: UUID) -> Block? {
        blocks.first { $0.id == id }
    }

    /// `NSAttributedString` for a text-bearing block, rebuilt from the
    /// inline IR on demand. `nil` for `image`. Used by selection at copy
    /// time and Cmd+A — we deliberately don't cache it because the cost
    /// of caching outweighs the rarity of these paths (copy is once per
    /// gesture; Cmd+A is once per shortcut).
    func attributedString(forBlockId id: UUID) -> NSAttributedString? {
        guard let block = block(forId: id) else { return nil }
        switch block.kind {
        case .heading(let level, let inlines):
            return BlockStyle.headingAttributed(level: level, inlines: inlines)
        case .paragraph(let inlines):
            return BlockStyle.paragraphAttributed(inlines: inlines)
        case .image:
            return nil
        }
    }

    /// `TextLayout` for a row's block, or `nil` for non-text rows. Goes
    /// through the lazy `layout(for:width:)` path so a row whose layout
    /// was evicted (or not yet computed) lazy-fills its cache entry as
    /// a side effect.
    func textLayout(atRow row: Int) -> TextLayout? {
        guard let block = block(atRow: row) else { return nil }
        return layout(for: block, width: layoutWidth).textLayout
    }

    /// Push the current selection state for `blockId` to its visible
    /// cell, which triggers `needsDisplay` via the cell's `didSet` if
    /// the range actually changed. No-op if the cell isn't currently
    /// visible — when it scrolls in, `viewFor` will read the live state
    /// from the selection dict.
    func markCellNeedsDisplay(blockId: UUID) {
        guard let table = tableView,
              let row = blocks.firstIndex(where: { $0.id == blockId })
        else { return }
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? BlockCellView
        else { return }
        cell.selectedRange = selection.selection(for: blockId)
            ?? NSRange(location: 0, length: 0)
    }

}

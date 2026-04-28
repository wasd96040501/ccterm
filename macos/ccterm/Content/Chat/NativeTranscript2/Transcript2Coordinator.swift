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
/// `prefetchAll` (post-resize) reuses the same async pipeline
/// (`precomputeLayoutsInBackground` → `cacheLayouts` → `noteHeightOfRows`
/// under `.saveVisible(.visualTop)`).
///
/// ### Concurrency
///
/// Everything is `@MainActor`. Background producers must hop. Detached
/// layout tasks validate `(generation, width)` before their main-hop
/// merge — covers all mutation kinds with a single Int+CGFloat check.
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

    /// Bumped on every `apply` / `applyInBackground`. Detached prefetch
    /// tasks capture it at start and validate before merging.
    private var generation: UInt64 = 0
    private var prefetchTask: Task<Void, Never>?

    // MARK: - Read-only snapshot

    var blockIds: [UUID] { blocks.map(\.id) }

    /// Width that rows are laid out at. Driven by the single column's
    /// `.autoresizingMask`. Returns 0 if the table isn't attached.
    var layoutWidth: CGFloat {
        tableView?.tableColumns.first?.width ?? 0
    }

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
        prefetchTask?.cancel()
        prefetchTask = nil
        generation &+= 1

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
    /// main hop installs them, runs the structural changes, and applies
    /// `scroll`. Drops the result if `(generation, width)` drifted.
    ///
    /// `completion` fires on main exactly once, in every outcome
    /// (succeeded, superseded, table-detached, zero-width). Callers use it
    /// to balance scroller push/pop or other paired lifecycle work that
    /// must survive the async hop. AppKit completion-handler semantics:
    /// "did terminate", not "did succeed".
    func applyInBackground(_ changes: [Transcript2Controller.Change],
                           scroll: Transcript2Controller.ScrollState,
                           completion: @MainActor @escaping () -> Void = {}) {
        guard tableView != nil else { completion(); return }
        let width = layoutWidth
        guard width > 0 else { completion(); return }

        // Collect blocks that need layout — only `.insert` carries new
        // blocks; `.remove` / `.update` either don't add layouts or evict
        // them. `.update`'s replacement layout is computed lazily by the
        // sync `apply` after main-hop, since it's a single block.
        let toCompute: [Block] = changes.flatMap { change -> [Block] in
            if case .insert(_, let blocks) = change { return blocks }
            return []
        }

        generation &+= 1
        let snapshotGen = generation

        precomputeLayoutsInBackground(
            blocks: toCompute, width: width, snapshotGen: snapshotGen,
            onMain: { [weak self] entries in
                guard let self, let table = self.tableView else { return }
                self.withScrollAdjustment(scroll, in: table) {
                    self.cacheLayouts(entries, width: width)
                    table.beginUpdates()
                    for change in changes {
                        self.applyStructuralChange(change, in: table)
                    }
                    table.endUpdates()
                }
                self.onBlockCountChanged?(self.blocks.count)
            },
            completion: completion)
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

    // MARK: - Off-main layout pipeline (shared by applyInBackground + resize prefetch)

    /// Computes layouts on a detached task, hops to main, validates
    /// `(generation, width)`, then calls `onMain` with the precomputed
    /// entries. Caller decides what to do with them (cache + insert,
    /// cache + noteHeight, etc).
    ///
    /// `completion` fires on main exactly once, regardless of which path
    /// won (success / cancellation / supersede / detached table). It
    /// exists so callers can balance lifecycle work (e.g. scroller
    /// push/pop) that has to survive the async hop. Matches the AppKit
    /// completion-handler convention (`URLSession`, `NSAnimationContext`):
    /// "did terminate, possibly with error" — not "did succeed".
    private func precomputeLayoutsInBackground(
        blocks: [Block],
        width: CGFloat,
        snapshotGen: UInt64,
        onMain: @MainActor @escaping ([(UUID, RowLayout)]) -> Void,
        completion: @MainActor @escaping () -> Void = {}
    ) {
        prefetchTask?.cancel()
        prefetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var precomputed: [(UUID, RowLayout)] = []
            precomputed.reserveCapacity(blocks.count)
            var aborted = false
            for block in blocks {
                if Task.isCancelled { aborted = true; break }
                precomputed.append((block.id, Self.makeLayout(for: block, width: width)))
            }
            await MainActor.run { [precomputed] in
                defer { completion() }
                if aborted { return }
                guard let self else { return }
                guard self.generation == snapshotGen else { return }
                guard let table = self.tableView,
                      self.layoutWidth == width else { return }
                onMain(precomputed)
            }
        }
    }

    private func cacheLayouts(_ entries: [(UUID, RowLayout)], width: CGFloat) {
        for (id, layout) in entries {
            layoutCache[id] = CachedLayout(width: width, layout: layout)
        }
    }

    // MARK: - Lazy layout (heightOfRow / viewFor)

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

    func prefetchAll() {
        guard let tableView else { return }
        let width = layoutWidth
        guard width > 0 else { return }
        // Skip if every entry is already at this width — common case when
        // resize ended at the start width with no actual change. No push
        // happened, so no pop needed.
        if blocks.allSatisfy({ layoutCache[$0.id]?.width == width }) { return }

        let snapshot = blocks
        let snapshotGen = generation
        // Push covers the async layout window so the scroller stays hidden
        // through the post-resize relayout. Popped from `completion`, which
        // fires in every outcome.
        pushScrollerHidden()
        precomputeLayoutsInBackground(
            blocks: snapshot, width: width, snapshotGen: snapshotGen,
            onMain: { [weak self] entries in
                guard let self, let table = self.tableView else { return }
                // Off-screen rows had stale cached heights during live
                // resize; correcting them now shifts every row's Y, so
                // anchor on the visible top row to keep visible content
                // visually fixed.
                self.withScrollAdjustment(.saveVisible(.visualTop), in: table) {
                    self.cacheLayouts(entries, width: width)
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(0 ..< self.blocks.count))
                }
            },
            completion: { [weak self] in self?.popScrollerHidden() })
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
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard blocks.indices.contains(row) else { return nil }
        let width = layoutWidth
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

}

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

    /// Fires when `layoutWidth` first becomes > 0 — i.e. the table has
    /// been inserted into a scroll view and tiled. `Transcript2Controller`
    /// hooks this to consume any `loadInitial` it had to defer because
    /// the table wasn't mounted yet (re-entry race: SwiftUI commits the
    /// `NativeTranscript2View` *after* `.task` has already driven the
    /// `.reset` mutation through the bridge into `loadInitial`). Fires at
    /// most once per 0→positive transition; subsequent width changes
    /// (live resize, etc.) don't re-fire.
    var onLayoutReady: (() -> Void)?

    /// Set by `Transcript2Controller` to forward chevron taps to the
    /// SwiftUI-owned sheet binding. The cell's mouseDown handler resolves
    /// the chevron hit, looks up the source `Block.Kind.userBubble(text:)`,
    /// and fires this — keeping the cross-layer signal narrow (one block
    /// id + the original text) so neither side reaches into the other's
    /// internals.
    var onUserBubbleSheetRequested: ((UUID, String) -> Void)?

    /// Cross-row text selection. Owns the selection dict; reads back into
    /// us through the helpers below (`block(atRow:)`, `textLayout(atRow:)`,
    /// `attributedString(forBlockId:)`, `markCellNeedsDisplay(blockId:)`).
    let selection: Transcript2SelectionCoordinator

    /// In-transcript text search. Sibling to `selection` — both consume
    /// `SelectionAdapter` through the same back-channel helpers. Lives
    /// here so `viewFor` can reseat the per-cell highlight specs onto
    /// recycled cells the same way selection state is reseated.
    let search: Transcript2SearchCoordinator

    /// Async-filled per-block side data. Currently backs syntax tokens
    /// for code blocks; future highlight-shaped derivatives (diff hunks,
    /// inline annotations) will share the same storage by adding scopes.
    /// `apply` lifecycle wires `schedule` / `drop` calls; `onDidFill`
    /// drives a single-row reload after tokens land.
    let highlightStorage: Transcript2HighlightStorage

    /// Per-block fold-state persistence. Keyed by `Block.id` so the
    /// user's expand/collapse choice survives `.update` content
    /// replacement (a tool-result fill-in mid-stream should not yank a
    /// diff the user just expanded shut again). Sparse — only blocks
    /// that have been toggled at least once carry an entry; absent =
    /// the kind's default (`false` for diff, today's only consumer).
    /// Mutation goes through `toggleFold(id:)` which drives the
    /// single-row relayout.
    private var foldStates: [UUID: Bool] = [:]

    /// Per-surface runtime status — same sparse-dict pattern as
    /// `foldStates`. Keyed by `Block.id` for group-level status and
    /// by `ToolGroupBlock.Child.id` for per-child status. Absent =
    /// `.completed` (default visible state, matches the past-tense
    /// label convention used by every child kind's `headerLabel`).
    /// Driven by `Transcript2Controller.setToolStatus(id:status:)`
    /// — `setStatus(id:status:)` below is the single mutation
    /// entry point, and it evicts the host row's cached layout +
    /// reloads that single row.
    private var statusStates: [UUID: ToolStatus] = [:]

    init(syntaxEngine: SyntaxHighlightEngine? = nil) {
        self.selection = Transcript2SelectionCoordinator()
        self.search = Transcript2SearchCoordinator()
        self.highlightStorage = Transcript2HighlightStorage(engine: syntaxEngine)
        super.init()
        self.selection.transcript = self
        self.search.transcript = self
        self.highlightStorage.onDidFill = { [weak self] id in
            self?.handleHighlightDidFill(blockId: id)
        }
    }

    /// macOS 26 SDK workaround — `@MainActor` deinit routes through
    /// `swift_task_deinitOnExecutorImpl`, which aborts when tearing
    /// down `highlightStorage`'s `TaskLocal` state. `nonisolated`
    /// skips the executor hop. See `SessionHandle2.deinit`.
    nonisolated deinit {}

    /// Late-bind a syntax engine. Hosts that read `\.syntaxEngine` from
    /// SwiftUI environment hop here after `body` resolves the value.
    /// On `nil → engine` transition, every currently-installed block is
    /// re-scheduled so cold-loaded code blocks pick up tokens; passing
    /// the same engine again is harmless (the per-block generation guard
    /// dedupes redundant in-flight tasks).
    func attachSyntaxEngine(_ engine: SyntaxHighlightEngine?) {
        let wasAttached = highlightStorage.hasEngine
        highlightStorage.setEngine(engine)
        guard !wasAttached, engine != nil else { return }
        for block in blocks { highlightStorage.schedule(block) }
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
    /// `BlockStyle.[min,max]LayoutWidth`. Sourced from `tableView.bounds.width`,
    /// the same source `CenteredRowView` uses for row geometry — so this and
    /// `row.bounds.width` are always in lock-step.
    ///
    /// **Why not `tableColumns.first?.width`:** `NSTableColumn` autoresize
    /// is async — it converges in the next `tile` pass, *after* the
    /// `frameDidChange` notification has already fired. A `Coordinator`
    /// observer reading `column.width` from that first notification gets
    /// the stale default (100pt), which `clamp` lifts to `minLayoutWidth`.
    /// `bounds.width` is set synchronously inside `setFrameSize`, so a
    /// frame-driven `frameDidChange` and a downstream `layoutWidth` read
    /// see the same value on the same tick — no "small-width transient"
    /// window for `onLayoutReady` → `consumePendingInitial` to trip on.
    ///
    /// Clamping here is the single source of truth: `makeLayout` sees the
    /// clamped width, `layoutCache` keys on it, and `CenteredRowView` /
    /// `Transcript2SelectionCoordinator` both consume `BlockStyle`'s
    /// helpers to stay in sync. Window resizes that don't cross the
    /// clamp boundary land on the same cache entry — no relayout.
    var layoutWidth: CGFloat {
        guard let table = tableView, table.bounds.width > 0 else { return 0 }
        return BlockStyle.clampedLayoutWidth(forRowWidth: table.bounds.width)
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
    func popScrollerHidden() { transcriptScrollView?.popScrollerHidden() }

    // MARK: - Mutation: sync

    func apply(
        _ changes: [Transcript2Controller.Change],
        scroll: Transcript2Controller.ScrollState = .none
    ) {
        // Bump so any inflight `cacheRefillTask` discards its onMain on
        // hop. We don't cancel here: the counter is the actual guard, and
        // `cacheRefillTask` polices its own lifetime via the next
        // `refillLayoutCache`. Discarding refill in this window matters
        // because its `saveVisible` would compensate against stale AppKit
        // heights (deferred re-query) — running on top of `apply`'s own
        // settled scroll would jitter the anchor row.
        mutationCounter &+= 1

        if let table = tableView {
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
    func applyInBackground(
        _ changes: [Transcript2Controller.Change],
        scroll: Transcript2Controller.ScrollState,
        completion: @MainActor @escaping () -> Void = {}
    ) {
        guard tableView != nil else {
            completion()
            return
        }
        let width = layoutWidth
        guard width > 0 else {
            completion()
            return
        }

        // Only `.insert` carries new blocks; `.remove` / `.update` either
        // don't add layouts or evict them. `.update`'s replacement layout
        // is computed lazily by `applyStructuralChange` after the main hop.
        let toCompute: [Block] = changes.flatMap { change -> [Block] in
            if case .insert(_, let blocks) = change { return blocks }
            return []
        }

        // Snapshot highlight values + fold flags + status flags on
        // MainActor before detaching — the off-main loop reads per-block
        // data from these dicts instead of hopping back to the actor
        // mid-iteration. New tokens / fold toggles / status changes
        // that land between this snapshot and the main hop are picked
        // up by the `onDidFill` / `toggleFold` / `setStatus` reload
        // paths independently.
        let highlightSnapshot = highlightStorage.snapshot()
        let foldsSnapshot = foldStates
        let statusesSnapshot = statusStates

        Task.detached(priority: .userInitiated) { [weak self] in
            var entries: [(UUID, RowLayout)] = []
            entries.reserveCapacity(toCompute.count)
            for block in toCompute {
                entries.append(
                    (
                        block.id,
                        Self.makeLayout(
                            for: block, width: width,
                            highlights: highlightSnapshot,
                            folds: foldsSnapshot,
                            statuses: statusesSnapshot)
                    ))
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

    private func applyStructuralChange(
        _ change: Transcript2Controller.Change,
        in table: NSTableView?
    ) {
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
            for block in new { highlightStorage.schedule(block) }
            table?.insertRows(
                at: IndexSet(idx..<idx + new.count),
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
                search.dropEntry(blockId: id)
                highlightStorage.drop(blockId: id)
                // Cleanup is sparse-dict friendly — `removeValue` is a
                // no-op when the id never carried a fold/status flag
                // (most blocks). Child-keyed entries (per
                // `ToolGroupBlock.Child.id`) leak on group removal, same
                // posture as `foldStates`; bounded by total tool calls
                // in history.
                foldStates.removeValue(forKey: id)
                statusStates.removeValue(forKey: id)
            }
            table?.removeRows(at: indexes, withAnimation: [.effectFade])

        case .update(let id, let kind):
            guard let i = blocks.firstIndex(where: { $0.id == id }) else { return }
            let updated = Block(id: id, kind: kind)
            blocks[i] = updated
            removeCachedLayout(for: id)
            // Drop stale highlight tokens (the new kind may carry a
            // different code or language, or no highlight at all). The
            // generation guard inside `drop` also invalidates any
            // in-flight task for the previous content, then `schedule`
            // kicks the new pass for the replacement kind.
            highlightStorage.drop(blockId: id)
            highlightStorage.schedule(updated)
            // Content replacement invalidates the prior selection range
            // (offsets no longer index into the same string). Drop now so
            // the upcoming `reloadData(forRowIndexes:)` runs viewFor with
            // a clean empty selection on the recycled cell.
            selection.dropEntry(blockId: id)
            // Search hits referenced offsets into the old text — drop too.
            // The next `runQuery` (if user is still typing) will re-find
            // matches in the replacement content.
            search.dropEntry(blockId: id)
            let idx = IndexSet(integer: i)
            table?.reloadData(
                forRowIndexes: idx,
                columnIndexes: IndexSet(integer: 0))
            table?.noteHeightOfRows(withIndexesChanged: idx)
        }
    }

    // MARK: - Highlight tokens fill-in

    /// Called by `highlightStorage` after async tokens land for `blockId`.
    /// Evicts the stale (plain) `RowLayout` and reloads the single row.
    /// Skips `noteHeightOfRows` because token fill changes only color,
    /// not glyph metrics — a re-layout pass would be a wasted query.
    private func handleHighlightDidFill(blockId: UUID) {
        guard let table = tableView,
            let row = blocks.firstIndex(where: { $0.id == blockId })
        else { return }
        removeCachedLayout(for: blockId)
        table.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: 0))
    }

    // MARK: - Scroll adjustment

    /// Wraps a structural-change closure with the requested scroll behavior.
    /// `.saveVisible` disables implicit animations so the height/insert
    /// transition doesn't race with the scroll-origin compensation.
    private func withScrollAdjustment(
        _ scroll: Transcript2Controller.ScrollState,
        in tableView: NSTableView,
        body: () -> Void
    ) {
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

    private func captureAnchor(
        side: Transcript2Controller.ScrollState.Side,
        in tableView: NSTableView
    ) -> ScrollAnchor? {
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
                to: NSPoint(
                    x: scrollView.contentView.bounds.origin.x,
                    y: anchor.oldScrollY + delta))
        }
    }

    /// Scroll so `id`'s top aligns with the visible content area's top edge.
    ///
    /// `NSClipView.bounds.height` spans the full clip frame (NSScrollView's
    /// `contentInsets` does *not* shrink it — insets only widen the allowed
    /// scroll range), so visible-content-area-top in clip coords is at
    /// `contentInsets.top`, not 0. Setting `bounds.origin.y = rect.minY -
    /// contentInsets.top` lands the row's top there.
    private func scrollRowToTop(id: UUID, in tableView: NSTableView) {
        guard let row = blocks.firstIndex(where: { $0.id == id }),
            let scrollView = tableView.enclosingScrollView
        else { return }
        let rect = tableView.rect(ofRow: row)
        let target = rect.minY - scrollView.contentInsets.top
        scrollView.contentView.scroll(
            to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: target))
    }

    /// Scroll so `id`'s bottom aligns with the visible content area's bottom
    /// edge. Mirrors `scrollRowToTop`: clip bounds span the full frame, so
    /// the visible content area's bottom in clip coords is at
    /// `clip.bounds.height - contentInsets.bottom`. The pre-fix
    /// implementation used just `clip.bounds.height`, which dropped the row
    /// into the bottom inset region (under the input-bar overlay).
    ///
    /// `target` is clamped to `-contentInsets.top` — the lowest origin
    /// `NSClipView` treats as legal. Without the clamp, a transcript whose
    /// total height is shorter than the viewport produces a strongly
    /// negative target (rect.maxY is tiny, the visible-bottom term is
    /// large), and `NSClipView.scroll(to:)` writes it through without
    /// constraint, pushing the documentView down into the viewport and
    /// leaving a gap above the first row.
    private func scrollRowToBottom(id: UUID, in tableView: NSTableView) {
        guard let row = blocks.firstIndex(where: { $0.id == id }),
            let scrollView = tableView.enclosingScrollView
        else { return }
        let rect = tableView.rect(ofRow: row)
        let visibleBottomInClip =
            scrollView.contentView.bounds.height - scrollView.contentInsets.bottom
        let raw = rect.maxY - visibleBottomInClip
        let target = max(-scrollView.contentInsets.top, raw)
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
        let layout = Self.makeLayout(
            for: block, width: width,
            highlights: highlightStorage.snapshot(),
            folds: foldStates,
            statuses: statusStates)
        layoutCache[block.id] = CachedLayout(width: width, layout: layout)
        return layout
    }

    /// Pure: `(block, width, highlights, folds, statuses) -> RowLayout`.
    /// `nonisolated static` so the background prefetch task can call it
    /// off-MainActor. `highlights`, `folds`, and `statuses` are snapshots
    /// taken on MainActor before the detached task starts; passing the
    /// snapshots in keeps the per-block lookup actor-free during the
    /// off-main loop. Defaults to empty so call sites that genuinely
    /// don't want either (e.g. `Transcript2Controller.sliceForViewport`'s
    /// height-only probe) can omit them — height is status-independent,
    /// so the slice probe doesn't need the dict.
    nonisolated static func makeLayout(
        for block: Block, width: CGFloat,
        highlights: [Transcript2HighlightKey: HighlightValue] = [:],
        folds: [UUID: Bool] = [:],
        statuses: [UUID: ToolStatus] = [:]
    ) -> RowLayout {
        let contentWidth = max(0, width - 2 * BlockStyle.blockHorizontalPadding)
        switch block.kind {
        case .heading(let level, let inlines):
            return .text(
                TextLayout.make(
                    attributed: BlockStyle.headingAttributed(level: level, inlines: inlines),
                    maxWidth: contentWidth))
        case .paragraph(let inlines):
            return .text(
                TextLayout.make(
                    attributed: BlockStyle.paragraphAttributed(inlines: inlines),
                    maxWidth: contentWidth))
        case .image(let image):
            return .image(
                ImageLayout.make(
                    image: image,
                    maxWidth: contentWidth,
                    maxHeight: BlockStyle.imageMaxHeight))
        case .list(let listBlock):
            return .list(ListLayout.make(block: listBlock, maxWidth: contentWidth))
        case .table(let tableBlock):
            return .table(TableLayout.make(block: tableBlock, maxWidth: contentWidth))
        case .codeBlock(let language, let code):
            let codeTokens: [SyntaxToken]? = {
                guard
                    case .tokens(let t) = highlights[
                        Transcript2HighlightKey(blockId: block.id, scope: .codeBlock)]
                else { return nil }
                return t
            }()
            return .codeBlock(
                CodeBlockLayout.make(
                    code: code, language: language,
                    tokens: codeTokens, maxWidth: contentWidth))
        case .blockquote(let inlines):
            return .blockquote(BlockquoteLayout.make(inlines: inlines, maxWidth: contentWidth))
        case .thematicBreak:
            return .thematicBreak(ThematicBreakLayout.make(maxWidth: contentWidth))
        case .userBubble(let text):
            return .userBubble(UserBubbleLayout.make(text: text, maxWidth: contentWidth))
        case .toolGroup(let group):
            // Pull every per-child highlight snapshot up front so the
            // off-main precompute path has no per-iteration dict
            // lookups against `highlights` (one bulk filter is cheap
            // and keeps the inner loop tight). Each child decides how
            // to unpack the `HighlightValue` shape (`.lineMap` for
            // fileEdit, `.tokens` for bash, …).
            var childHighlights: [UUID: HighlightValue] = [:]
            for child in group.children {
                if let value = highlights[
                    Transcript2HighlightKey(
                        blockId: block.id,
                        scope: .toolGroupChild(itemId: child.id))]
                {
                    childHighlights[child.id] = value
                }
            }
            return .toolGroup(
                ToolGroupLayout.make(
                    blockId: block.id,
                    group: group,
                    foldStates: folds,
                    statusStates: statuses,
                    childHighlights: childHighlights,
                    maxWidth: contentWidth))
        case .loadingPill:
            // Intrinsic size — `contentWidth` is unused (pill is a
            // small chip that doesn't fill the column). Kept
            // `nonisolated static` so `applyInBackground`'s detached
            // precompute can call it; the pill never appears in a
            // Phase 2 prepend today, but the contract holds.
            return .loadingPill(LoadingPillLayout.make())
        }
    }

    // MARK: - Fold-state interactions

    /// Toggle the persistent fold flag for `id` and replay the single-row
    /// height change. Wraps the row mutation in a brief animation group so
    /// the height transition reads as a smooth expand/collapse, matching
    /// the old `NativeTranscript.GroupComponent` chevron behavior. Layouts
    /// receive the new flag through their next `makeLayout` query — the
    /// cache eviction here guarantees that lookup recomputes rather than
    /// returning the stale, oppositely-folded entry.
    ///
    /// No-op if `id` isn't a current block. Selection on the affected
    /// row is dropped: fold/unfold replaces the layout's body content,
    /// so prior selection offsets no longer index into anything
    /// meaningful.
    func toggleFold(id: UUID) {
        guard let table = tableView else { return }
        // Find the owning row. `id` may be either a top-level
        // `Block.id` (the group header itself) or a
        // `ToolGroupBlock.Child.id` (an item header inside a group).
        // Search both so child-header clicks reach the same code path
        // as group-header clicks — without this fallback, child
        // toggles silently no-op because nested ids never appear in
        // `blocks.firstIndex(...)`.
        let hostRow = blocks.firstIndex { block in
            if block.id == id { return true }
            switch block.kind {
            case .toolGroup(let group):
                return group.children.contains(where: { $0.id == id })
            default:
                return false
            }
        }
        guard let row = hostRow else { return }
        let newExpanded = !(foldStates[id] ?? false)
        foldStates[id] = newExpanded
        let hostId = blocks[row].id
        // Invalidate the host row's cached layout and selection — the
        // toggled id might be a child, but the *layout* of the
        // enclosing toolGroup row is what AppKit needs to re-query.
        removeCachedLayout(for: hostId)
        selection.dropEntry(blockId: hostId)

        // Cell-side fold transition runs *before* the reload so the
        // cell can snapshot its current state (mid-flight chevron
        // angle, pre-swap bitmap) and start its drivers. The
        // `reloadData` below installs the new `RowLayout` on the
        // same cell instance; AppKit reuses the cell for the same
        // row, so the animation state carries through.
        //
        // `beginFoldTransition` packages three drivers behind one
        // call (chevron rotation animation, cell-layer cross-fade,
        // and the one-shot `pendingFoldTransition` flag that routes
        // the upcoming `syncSubviewPlan()` through `view.animator()`).
        // Ordering between them is internal to the cell — callers
        // can't get it wrong by reordering.
        let cell =
            table.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? BlockCellView
        cell?.beginFoldTransition(foldId: id, toExpanded: newExpanded)

        let idx = IndexSet(integer: row)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = BlockStyle.foldAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            table.beginUpdates()
            table.noteHeightOfRows(withIndexesChanged: idx)
            table.endUpdates()
            // `reloadData` swaps the cell's `RowLayout` so the new
            // folded/expanded body draws — must follow `noteHeightOfRows`
            // inside the same animation group so the row's height change
            // and content swap composite together rather than tearing.
            table.reloadData(
                forRowIndexes: idx,
                columnIndexes: IndexSet(integer: 0))
        }
    }

    // MARK: - Status interactions

    /// Update the runtime status for a tool surface and refresh the
    /// owning row. `id` may name either a `toolGroup` host
    /// `Block.id` (group-level status) or a nested `ToolGroupBlock.Child.id`
    /// (per-child status) — same dual-search as `toggleFold` so callers
    /// don't need to know which level they're addressing.
    ///
    /// No-op when the id resolves to nothing (block not in the
    /// transcript, or the host row isn't a `toolGroup`). Setting the
    /// same status the dict already holds is also a no-op so a stream
    /// of redundant updates from the CLI doesn't churn AppKit.
    ///
    /// **Why this isn't a `Change.update`:** `.update` evicts highlight
    /// tokens, drops selection, and forces the caller to rebuild the
    /// `Block.Kind` payload — all wasteful for a status flip. This path
    /// only invalidates the host's cached `RowLayout` (status is a
    /// layout-build input through the `statusStates` snapshot) and
    /// reloads the single row. Row height is status-independent, so we
    /// also skip `noteHeightOfRows`.
    func setStatus(id: UUID, status: ToolStatus) {
        guard let table = tableView else {
            // Table not attached yet — record the status so the future
            // `reloadData()` after attach picks it up via `makeLayout`.
            if statusStates[id] != status { statusStates[id] = status }
            return
        }
        // Resolve owning row: either the host block itself or a child
        // nested in a `toolGroup`. Matches `toggleFold` to keep both
        // hit paths working off one keyspace.
        let hostRow = blocks.firstIndex { block in
            if block.id == id { return true }
            switch block.kind {
            case .toolGroup(let group):
                return group.children.contains(where: { $0.id == id })
            default:
                return false
            }
        }
        guard let row = hostRow else {
            // Unknown id — still cache so a later insert with this id
            // picks the value up. Bounded by tool-call cardinality.
            if statusStates[id] != status { statusStates[id] = status }
            return
        }
        if statusStates[id] == status { return }
        statusStates[id] = status
        let hostId = blocks[row].id
        removeCachedLayout(for: hostId)
        // Selection / highlight intentionally untouched — status
        // doesn't change glyph geometry inside any selectable body, so
        // current offsets remain valid.
        table.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: 0))
        // No `noteHeightOfRows` — status only repaints the header
        // bands' colour palette; total row height is unchanged.
    }

    // MARK: - User bubble sheet

    /// Forwards a chevron click on the user bubble at `id` to the SwiftUI
    /// sheet binding (via `onUserBubbleSheetRequested`). No `.update` path
    /// — fold state is absent from the layout; the sheet is the place to
    /// read the full message. No-op if `id` is unknown or doesn't point
    /// at a `userBubble`.
    func requestUserBubbleSheet(id: UUID) {
        guard let i = blocks.firstIndex(where: { $0.id == id }),
            case .userBubble(let text) = blocks[i].kind
        else { return }
        onUserBubbleSheetRequested?(id, text)
    }

    // MARK: - Width-change driven invalidation

    @objc func tableFrameDidChange(_ note: Notification) {
        guard let tableView else { return }
        // Resizes inside the >max clamp band leave `layoutWidth` unchanged —
        // `BlockCellView.layoutOrigin` re-centers content automatically from
        // the new `bounds.width`, no row needs its layout invalidated.
        let width = layoutWidth
        if width == lastLayoutWidth { return }
        let prevWidth = lastLayoutWidth
        lastLayoutWidth = width
        // First 0→positive transition unblocks any deferred `loadInitial`
        // on the controller side. Has to fire *before* the `blocks.isEmpty`
        // guard below — when the controller is holding a pending payload,
        // `blocks` is still empty here, so the original `guard` would
        // short-circuit and the consume call would never happen.
        if prevWidth <= 0 && width > 0 {
            onLayoutReady?()
        }
        guard !blocks.isEmpty else { return }
        if tableView.inLiveResize {
            // Bounded per-frame layout work: only invalidate visible rows.
            // Off-screen rows keep their stale heights and stale cached
            // layouts — invisible to the user and repaired by the
            // post-resize background prefetch.
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.location != NSNotFound, visible.length > 0 else { return }
            invalidate(
                rows: IndexSet(visible.location..<visible.location + visible.length),
                in: tableView)
        } else {
            // Outside live resize, frame changes are programmatic / one-off
            // (initial layout, window animation). Invalidate everything;
            // AppKit re-queries lazily on next layout pass.
            invalidate(rows: IndexSet(0..<blocks.count), in: tableView)
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
        tableView.reloadData(
            forRowIndexes: indexes,
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
        let highlightSnapshot = highlightStorage.snapshot()
        let foldsSnapshot = foldStates
        let statusesSnapshot = statusStates
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
                if Task.isCancelled {
                    aborted = true
                    break
                }
                entries.append(
                    (
                        block.id,
                        Self.makeLayout(
                            for: block, width: width,
                            highlights: highlightSnapshot,
                            folds: foldsSnapshot,
                            statuses: statusesSnapshot)
                    ))
            }
            await MainActor.run { [entries] in
                defer { self?.popScrollerHidden() }
                if aborted { return }
                guard let self, let table = self.tableView,
                    self.layoutWidth == width
                else { return }
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
        let pad = BlockStyle.blockPadding(for: blocks[row].kind)
        return layout(for: blocks[row], width: width).totalHeight
            + pad.top + pad.bottom
    }

    func tableView(
        _ tableView: NSTableView,
        rowViewForRow row: Int
    ) -> NSTableRowView? {
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

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
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
        cell.padTop = BlockStyle.blockPadding(for: block.kind).top
        // Selection is keyed by block id, not by cell instance, so a
        // recycled cell scrolling onto a row that already had a selection
        // picks up the existing entry here. nil = no highlight.
        cell.blockId = block.id
        cell.selection = selection.selection(for: block.id)
        // Same recycle-friendly story for search highlights — drive them
        // off the per-block lookup so a scroll-in cell picks up the
        // current scan's hits without holding a cell ref.
        cell.searchHighlights = search.hits(for: block.id)?.ranges
        // Copy-feedback flash is per-cell transient state — clear it
        // on every reuse so a recycled cell doesn't carry a stale
        // checkmark onto a different code block.
        cell.resetCopiedFeedback()
        // Hover affordance is reseated by `layout.didSet` (via the
        // cached mouse-location re-evaluation): a fold-toggle reload
        // keeps the cursor over the same hit and so should keep
        // brightening it, while a scroll-recycle hop moves the cell
        // out from under the cursor and the re-evaluation clears the
        // stale hover by itself. No need to forcibly reset here.
        // Reinjected on every viewFor (cells are reused across rows) so
        // chevron mouseDown can hit `requestUserBubbleSheet` without
        // scanning the superview chain.
        cell.coordinator = self
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

    /// Selection-facing API for the block at `row`, or `nil` if the row
    /// is non-selectable (image, list). Goes through the lazy
    /// `layout(for:width:)` path so a row whose layout was evicted (or
    /// not yet computed) lazy-fills its cache entry as a side effect.
    func selectionAdapter(atRow row: Int) -> SelectionAdapter? {
        guard let block = block(atRow: row) else { return nil }
        return layout(for: block, width: layoutWidth).selectionAdapter
    }

    /// Selection-facing API keyed by block id (used by Cmd+A, copy, and
    /// other paths that don't have a row index handy).
    func selectionAdapter(forBlockId id: UUID) -> SelectionAdapter? {
        guard let block = block(forId: id) else { return nil }
        return layout(for: block, width: layoutWidth).selectionAdapter
    }

    /// Push the current selection state for `blockId` to its visible
    /// cell, which triggers `needsDisplay` via the cell's `didSet` if
    /// the value actually changed. No-op if the cell isn't currently
    /// visible — when it scrolls in, `viewFor` will read the live state
    /// from the selection dict.
    func markCellNeedsDisplay(blockId: UUID) {
        guard let table = tableView,
            let row = blocks.firstIndex(where: { $0.id == blockId })
        else { return }
        guard
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? BlockCellView
        else { return }
        cell.selection = selection.selection(for: blockId)
    }

    // MARK: - Search-side helpers

    /// Search-coordinator equivalent of `markCellNeedsDisplay`. Pushes
    /// the latest hit specs for `blockId` to its visible cell so the
    /// next draw frame reflects the new highlight state (added /
    /// removed hits, current-cursor flip). Non-visible cells get the
    /// state on scroll-in via `viewFor`.
    func markCellSearchDirty(blockId: UUID) {
        guard let table = tableView,
            let row = blocks.firstIndex(where: { $0.id == blockId })
        else { return }
        guard
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? BlockCellView
        else { return }
        cell.searchHighlights = search.hits(for: blockId)?.ranges
    }

    /// Force any ancestor folds on a search hit's row open before nav
    /// scrolls to it. For `toolGroup` rows the position encodes which
    /// child the hit lives in (`.diff` / `.textCard` carry `childIndex`)
    /// — only that specific child is unfolded so we don't disturb the
    /// user's expand state on sibling children. When `position` is `nil`
    /// or carries no child index (plain text blocks land here too),
    /// only the group host gets opened.
    func expandForSearchHit(blockId: UUID, position: LayoutPosition? = nil) {
        guard let i = blocks.firstIndex(where: { $0.id == blockId }) else { return }
        switch blocks[i].kind {
        case .toolGroup(let group):
            // Open the group host first — children only re-lay-out
            // once the group is expanded; their own `foldStates[child.id]`
            // is preserved from before the user folded the group.
            if foldStates[blockId] != true {
                toggleFold(id: blockId)
            }
            // Then narrow to the specific child the hit landed in.
            // The hit's position is `LayoutPosition.diff/.textCard`
            // which carries `childIndex` into `group.children`.
            guard let childIndex = Self.childIndex(for: position),
                group.children.indices.contains(childIndex)
            else { return }
            let child = group.children[childIndex]
            if child.hasExpandableBody, foldStates[child.id] != true {
                toggleFold(id: child.id)
            }
        default:
            return
        }
    }

    /// Extract the `childIndex` payload from a tool-group layout position.
    /// Returns `nil` for any position that doesn't carry one (plain text
    /// blocks, or `nil` position) — caller treats that as "no specific
    /// child to expand."
    private static func childIndex(for position: LayoutPosition?) -> Int? {
        switch position {
        case .diff(let i, _): return i
        case .textCard(let i, _, _): return i
        default: return nil
        }
    }

    /// Scroll so the row owning `blockId` is comfortably visible
    /// (top-aligned with a one-row breathing margin under the
    /// scroll-view's top inset). Used by search nav. No-op when the
    /// row is already in the visible band.
    func scrollBlockIntoView(blockId: UUID) {
        guard let table = tableView,
            let scrollView = table.enclosingScrollView,
            let row = blocks.firstIndex(where: { $0.id == blockId })
        else { return }
        let rect = table.rect(ofRow: row)
        let visible = table.visibleRect
        let visibleTop = visible.minY + scrollView.contentInsets.top
        let visibleBottom = visible.maxY - scrollView.contentInsets.bottom
        // Already comfortably in view → don't disturb scroll state.
        if rect.minY >= visibleTop, rect.maxY <= visibleBottom { return }
        // Otherwise scroll-to-top with the table's content inset
        // honored — reuse the helper used by `.scrollState(.top)`.
        scrollRowToTopPublic(id: blockId)
    }

    /// Public wrapper around the private `scrollRowToTop` helper so the
    /// search coordinator can ask for a top-aligned scroll without
    /// reaching into private API.
    func scrollRowToTopPublic(id: UUID) {
        guard let table = tableView else { return }
        scrollRowToTop(id: id, in: table)
    }

}

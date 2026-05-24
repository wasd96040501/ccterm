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
/// - **`apply(_:scroll:)`** — sync, the single mutation entry. Layouts compute
///   lazily on `heightOfRow` queries (or, for the backfill pipeline, were
///   precomputed off-main and land as cache hits). Handles every change —
///   live messages, tool-result updates, single removals, and the pipeline's
///   `.prepend` / `.append` backfill batches.
///
/// It runs its structural change inside `withScrollAdjustment`,
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
/// `refillLayoutCache` (post-resize) prefetches off-screen layouts on its own
/// detached task, then `cacheLayouts` → `noteHeightOfRows` →
/// `layoutSubtreeIfNeeded` → anchor-compensate, all under
/// `.saveVisible(.visualTop)`.
///
/// ### Concurrency
///
/// Everything is `@MainActor`. One off-main lifecycle:
///
/// - **`cacheRefillTask`** — `tableFrameDidChange` post-resize refill.
///   `numberOfRows` doesn't change; the only effect is to populate
///   `layoutCache` at the new width and `noteHeightOfRows` the rows whose
///   heights moved. Superseded only by the next `refillLayoutCache`. Loss is
///   CPU only — `heightOfRow` lazy-recomputes.
///
/// (Off-main layout for *backfill* lives in `TranscriptBackfillPipeline`'s
/// producer, which deposits pre-built pages the main drain applies via
/// `apply(.prepend)`; the coordinator itself no longer spawns a row-mutation
/// task.)
///
/// Cache anti-poison sits inside `cacheLayouts`: a write skips entries
/// already fresh at the same width, so an inflight task hopping in *after*
/// `apply .update`/`.remove` evicted and lazy-refilled an entry can't
/// overwrite the authoritative fresh layout with its older snapshot.
///
/// The refill hop's `saveVisible` anchor compensation is made correct against
/// a *concurrent* `apply` by forcing the re-tile in-tick
/// (`layoutSubtreeIfNeeded` after `noteHeightOfRows`, before `applyAnchor`) —
/// so the compensation always reads real `rect(ofRow:)`, never deferred-stale
/// heights. No mutation counter / drift guard is needed.
@MainActor
final class Transcript2Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var tableView: NSTableView?

    /// Notifies the controller after every successful mutation so SwiftUI
    /// observers on `blockCount` see the new value.
    var onBlockCountChanged: ((Int) -> Void)?

    /// Set by `Transcript2Controller` to forward chevron taps onto its
    /// `pendingUserBubbleSheet` field, which
    /// `Transcript2SheetPresenter` observes and turns into an AppKit
    /// sheet. The cell's mouseDown handler resolves the chevron hit,
    /// looks up the source `Block.Kind.userBubble(text:_:)`, and fires
    /// this — keeping the cross-layer signal narrow (one block id +
    /// the original text) so neither side reaches into the other's
    /// internals.
    var onUserBubbleSheetRequested: ((UUID, String) -> Void)?

    /// Set by `Transcript2Controller` to forward an attachment-chip
    /// click onto its `pendingImagePreview` field. The cell's
    /// mouseDown handler resolves the chip hit via
    /// `HitAction.openImagePreview(NSImage)` and fires this with the
    /// same `NSImage` instance the layout holds — narrow contract,
    /// symmetric with `onUserBubbleSheetRequested`.
    var onImagePreviewRequested: ((NSImage) -> Void)?

    /// Fires once at live-resize end (from `refillLayoutCache`) with the
    /// settled clamped `layoutWidth`. The backfill pipeline subscribes via
    /// `retarget(width:)` so **future** off-main pages build at the new width
    /// Purely a perf optimization — skipping it stays
    /// correct because already-built pages self-heal through the width-keyed
    /// cache; the hook never fires *during* a live resize (only at its end),
    /// matching §4.4's "minimum during the drag, real work at the end".
    var onLayoutWidthDidSettle: ((CGFloat) -> Void)?

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
    /// skips the executor hop. See `Session.deinit`.
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

    /// Resident telemetry: monotonic count of **on-main** `makeLayout`
    /// recomputes — layout-cache misses resolved synchronously through
    /// `layout(for:width:)` (`heightOfRow` / `viewFor`). Off-main precompute
    /// (`refillLayoutCache`, the backfill pipeline) calls `Self.makeLayout`
    /// directly and does **not** touch this, so the counter is exactly the
    /// main-thread typeset work. Read it as a *delta* around a known span
    /// (the attach-tick tile) so callers can log "how many rows this attach
    /// had to typeset on the main thread" **once** per attach — never per row
    /// (the per-row path is hot, so we bump an integer here and log nowhere).
    /// `&+=` wraps instead of trapping on a long-lived session; delta math
    /// within a single span is unaffected.
    private(set) var mainThreadLayoutComputes: Int = 0

    #if DEBUG
    /// Test-only observer: fires on every effective write into `layoutCache`,
    /// from both the batch path (`cacheLayouts`) and the lazy path
    /// (`layout(for:width:)`). Used by `TranscriptReentryLayoutCacheTests` to
    /// detect same-id re-layouts at different widths inside one source phase.
    /// Production never sets this; Release builds don't compile the hook.
    var onLayoutCacheWriteForDebug: ((UUID, CGFloat) -> Void)?
    #endif

    /// Tracks the `tableFrameDidChange` post-resize layout refill task,
    /// cancelled + superseded by the next `refillLayoutCache`.
    private var cacheRefillTask: Task<Void, Never>?

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
    /// window for `tableFrameDidChange`'s 0→positive anchor consumer to
    /// trip on.
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

    #if DEBUG
    /// Test-only read of the recorded display width that seeds the detached
    /// layout warm. Observation only; never gates behavior.
    var displayWidthForDebug: CGFloat { lastLayoutWidth }
    #endif

    /// Visible-region height of the enclosing scroll view. Returns 0 if
    /// no scroll view is attached.
    var viewportHeight: CGFloat {
        tableView?.enclosingScrollView?.contentView.bounds.height ?? 0
    }

    /// Total laid-out content height (the documentView's frame height). After
    /// an `insertRows` settles inside `endUpdates` (§2.6 — no estimated
    /// heights) this reflects the new total synchronously. `0` with no table.
    var documentHeight: CGFloat {
        tableView?.frame.height ?? 0
    }

    /// Whether the rendered content already covers the visible viewport — i.e.
    /// there is enough laid-out height to fill the screen with no blank band.
    /// Requires a live viewport (`> 0`); headless / unmounted always reports
    /// `false` (there is no screen to cover). The backfill pipeline polls this
    /// per drain tick to fire `onFirstScreenReady` the moment the first screen
    /// is visually complete.
    var contentCoversViewport: Bool {
        let viewport = viewportHeight
        return viewport > 0 && documentHeight >= viewport
    }

    private var transcriptScrollView: Transcript2ScrollView? {
        tableView?.enclosingScrollView as? Transcript2ScrollView
    }

    /// Hide / restore the vertical scroller for the duration of a cold
    /// history backfill. Each backfill `.prepend` grows `documentView` and
    /// nudges `contentView.bounds.origin`, which fades the overlay scroller
    /// in on every drain tick — a flickering thumb on the right edge while
    /// the load streams. Suppressing the scroller for the load window kills
    /// the flicker. Safe because the scroll view is pinned to `.overlay`
    /// (`Transcript2ScrollView.scrollerStyle`): an overlay scroller floats
    /// over content and owns no layout width, so toggling `hasVerticalScroller`
    /// never changes `contentView.bounds.width` → `tile()` is a no-op for the
    /// table frame and no second-width typeset fires (§2.19). On restore we
    /// `reflectScrolledClipView` so the re-added thumb syncs to the current
    /// origin instead of snapping back to the load-start position.
    func setHistoryBackfilling(_ active: Bool) {
        guard let scrollView = transcriptScrollView else { return }
        scrollView.hasVerticalScroller = !active
        if !active {
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: - Mutation: sync

    /// `precomputed` carries off-main-built layouts + the width they were
    /// typeset at (the backfill pipeline's producer). They
    /// are installed into the cache **before** the structural change so the
    /// synchronous `heightOfRow` queries `insertRows` fires inside `endUpdates`
    /// (§5.1 — no estimated heights) are cache **hits**, not on-main CTLine
    /// passes. Width is self-healing: an entry whose width doesn't match the
    /// table's current `layoutWidth` is simply a miss that lazy-recomputes
    /// (§4.3), never a corruption — so no validate gate. `nil` by default;
    /// every existing caller is unaffected.
    func apply(
        _ changes: [Transcript2Controller.Change],
        scroll: Transcript2Controller.ScrollState = .none,
        precomputed: Transcript2Controller.PrecomputedLayouts? = nil
    ) {
        if let table = tableView {
            withScrollAdjustment(scroll, in: table) {
                // Install the off-main layouts before the structural notify so
                // `insertRows`' in-`endUpdates` height query lands as a hit.
                if let precomputed {
                    cacheLayouts(precomputed.layouts, width: precomputed.width)
                }
                table.beginUpdates()
                for change in changes {
                    applyStructuralChange(change, in: table)
                }
                table.endUpdates()
            }
        } else {
            // No table attached — mutate `blocks` only; layouts compute
            // lazily once a table re-attaches and `heightOfRow` is
            // queried. Scroll state is meaningless without live geometry.
            // Still install the precomputed cache so a later attach finds
            // them at the producer's width (a hit if width is unchanged).
            if let precomputed {
                cacheLayouts(precomputed.layouts, width: precomputed.width)
            }
            for change in changes {
                applyStructuralChange(change, in: nil)
            }
            // Detached (non-active session): warm the newly-inserted blocks'
            // layouts off-main at the last-displayed width so a later attach
            // finds them as cache hits, instead of typesetting O(streamed
            // rows) on the main thread during the re-entry tile. Active
            // sessions skip this — their visible rows fill lazily through
            // `heightOfRow`, and off-screen rows stay lazy as today.
            let warmIds = changes.flatMap(warmCandidateIds)
            scheduleLayoutWarm(ids: warmIds)
        }

        onBlockCountChanged?(blocks.count)
    }

    // MARK: - Structural change (mechanical, no scroll, no scheduling)

    private func applyStructuralChange(
        _ change: Transcript2Controller.Change,
        in table: NSTableView?
    ) {
        switch change {
        case .prepend(let new):
            // Intrinsic position: head. Thin sugar over the shared insert
            // primitive so the data mutation + structural notify stays one
            // well-tested code path.
            insertBlocks(after: nil, new, in: table)

        case .append(let new):
            // Intrinsic position: tail. `blocks.last?.id == nil` (empty table)
            // collapses to an index-0 insert, which is the correct first land.
            insertBlocks(after: blocks.last?.id, new, in: table)

        case .replace(let oldIds, let newBlocks):
            // Segment swap: remove the contiguous `oldIds` and insert
            // `newBlocks` at the same start index, atomically. Anchor on the
            // block just above the run so the insert lands where the run began.
            // Degenerate / absent `oldIds` is an out-of-order sink → append.
            let idSet = Set(oldIds)
            guard !idSet.isEmpty,
                let firstIdx = blocks.firstIndex(where: { idSet.contains($0.id) })
            else {
                applyStructuralChange(.append(newBlocks), in: table)
                return
            }
            let anchorId: UUID? = firstIdx > 0 ? blocks[firstIdx - 1].id : nil
            applyStructuralChange(.remove(ids: oldIds), in: table)
            insertBlocks(after: anchorId, newBlocks, in: table)

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
            // Per-scope diff: `schedule` compares each scope's payload
            // fingerprint against `sourceKeys` and only re-tokenises the
            // scopes whose payload actually changed. Unchanged sibling
            // children (typical when a tool_result attaches to one
            // child of a tool group) keep their cached tokens, so the
            // visible row doesn't flicker plain → coloured. Drop is
            // reserved for `.remove`.
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

    /// Shared insert primitive for `.prepend` / `.append` / `.replace`.
    /// Position is the caller's concern (`after: nil` = head; `blocks.last?.id`
    /// = tail; the block above a removed run = in-place). Not a public
    /// `Change` case — the vocabulary exposes only intrinsic-position cases so
    /// no caller can thread an arbitrary anchor through a generic insert
    /// A non-nil but unknown `after` is a no-op, same
    /// posture as `.update` / `.remove` for unknown ids.
    private func insertBlocks(after: UUID?, _ new: [Block], in table: NSTableView?) {
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
    }

    // MARK: - Highlight tokens fill-in

    /// Called by `highlightStorage` after async tokens land for `blockId`.
    /// Evicts the stale (plain) `RowLayout` and reloads the single row.
    /// Skips `noteHeightOfRows` because token fill changes only color,
    /// not glyph metrics — a re-layout pass would be a wasted query.
    private func handleHighlightDidFill(blockId: UUID) {
        guard blocks.contains(where: { $0.id == blockId }) else { return }
        if let table = tableView,
            let row = blocks.firstIndex(where: { $0.id == blockId })
        {
            // Active: evict + single-row reload. The visible row recomputes
            // its now-coloured layout on the main thread immediately — one
            // row, on screen, no async hop, no plain→coloured flicker.
            removeCachedLayout(for: blockId)
            table.reloadData(
                forRowIndexes: IndexSet(integer: row),
                columnIndexes: IndexSet(integer: 0))
        } else {
            // Detached: don't just evict — that would punch a hole in the
            // warm cache that becomes a re-entry miss. Drop the stale plain
            // layout and re-warm off-main with the freshly-filled tokens, so
            // the cache stays warm AND coloured. `force` makes the coloured
            // write win over any in-flight plain insert-warm for this id.
            removeCachedLayout(for: blockId)
            scheduleLayoutWarm(ids: [blockId], force: true)
        }
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
        // See note in `scrollRowToBottom` — `NSClipView.scroll(to:)` does
        // not auto-update the enclosing scroll view's scrollers.
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
        // `NSClipView.scroll(to:)` writes the bounds origin but does NOT
        // auto-call `reflectScrolledClipView(_:)`. Without this follow-up
        // the enclosing scroll view's scroller stays synced to the *prior*
        // clip origin, so the thumb flashes at the top while content is at
        // the tail — visible on every populated-session re-attach.
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
    private func cacheLayouts(
        _ entries: [(UUID, RowLayout)], width: CGFloat, force: Bool = false
    ) {
        for (id, layout) in entries {
            // `force` overwrites a same-width entry; the detached highlight
            // re-warm needs it so its coloured layout wins over a queued plain
            // insert-warm regardless of which task completes last. Non-forced
            // writes keep the anti-poison skip (see the method's doc comment).
            if !force, layoutCache[id]?.width == width { continue }
            layoutCache[id] = CachedLayout(width: width, layout: layout)
            #if DEBUG
            onLayoutCacheWriteForDebug?(id, width)
            #endif
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
        // Hot path — count only (one integer bump), never log here. The
        // summary is logged once per attach by reading the delta (see
        // `mainThreadLayoutComputes`).
        mainThreadLayoutComputes &+= 1
        #if DEBUG
        onLayoutCacheWriteForDebug?(block.id, width)
        #endif
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
                    tokens: codeTokens,
                    copyButtonId: block.id,
                    maxWidth: contentWidth))
        case .blockquote(let inlines):
            return .blockquote(BlockquoteLayout.make(inlines: inlines, maxWidth: contentWidth))
        case .thematicBreak:
            return .thematicBreak(ThematicBreakLayout.make(maxWidth: contentWidth))
        case .userBubble(let text, let isQueued):
            return .userBubble(
                UserBubbleLayout.make(
                    text: text, isQueued: isQueued, maxWidth: contentWidth))
        case .userAttachments(let images):
            return .userAttachments(
                UserAttachmentsLayout.make(images: images, maxWidth: contentWidth))
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
            // `nonisolated static` so the off-main precompute paths
            // (`refillLayoutCache`, the backfill builder) can call it.
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
            // Table not attached yet. Record the status so the future
            // attach picks it up through `makeLayout`'s `statuses`
            // snapshot.
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
        //
        // Queue a `CATransition.fade` on the visible cell *before*
        // `reloadData(forRowIndexes:)`. AppKit reuses the same cell
        // for the same row, so the transition carries through the
        // `layout` swap that follows — title text + colour palette
        // crossfade rather than pop on `.running ↔ .completed`.
        // No-op when the row is off-screen (no cell to address).
        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? BlockCellView
        {
            cell.beginContentFadeTransition()
        }
        table.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: 0))
        // No `noteHeightOfRows` — status only repaints the header
        // bands' colour palette; total row height is unchanged.
    }

    /// Read-only view into the sparse status dict. Returns `.completed`
    /// for absent ids — matches the layout-side default (`statusStates`
    /// absent = `.completed`). Symmetric with `setStatus(id:status:)`.
    func status(for id: UUID) -> ToolStatus {
        statusStates[id] ?? .completed
    }

    /// Bulk-clear every `.running` entry to `.completed`. `.failed` and
    /// `.cancelled` entries are left alone. Fired by the bridge when the
    /// runtime sees `.result` (turn end) — any tool that hadn't received
    /// a `tool_result` by then is abandoned, and leaving it shimmering
    /// is misleading.
    ///
    /// Same single-row-reload pattern as `setStatus`: evict each affected
    /// host's cached layout, batch one `reloadData(forRowIndexes:)`. Row
    /// height is unchanged, so no `noteHeightOfRows`.
    func clearAllRunningStatuses() {
        let runningIds = statusStates.compactMap { (id, status) -> UUID? in
            if case .running = status { return id }
            return nil
        }
        guard !runningIds.isEmpty else { return }
        var affectedRows = IndexSet()
        for id in runningIds {
            statusStates[id] = .completed
            let hostRow = blocks.firstIndex { block in
                if block.id == id { return true }
                switch block.kind {
                case .toolGroup(let group):
                    return group.children.contains(where: { $0.id == id })
                default:
                    return false
                }
            }
            guard let row = hostRow else { continue }
            let hostId = blocks[row].id
            removeCachedLayout(for: hostId)
            affectedRows.insert(row)
        }
        guard let table = tableView, !affectedRows.isEmpty
        else { return }
        table.reloadData(
            forRowIndexes: affectedRows,
            columnIndexes: IndexSet(integer: 0))
    }

    // MARK: - User bubble sheet

    /// Forwards a chevron click on the user bubble at `id` to the SwiftUI
    /// sheet binding (via `onUserBubbleSheetRequested`). No `.update` path
    /// — fold state is absent from the layout; the sheet is the place to
    /// read the full message. No-op if `id` is unknown or doesn't point
    /// at a `userBubble`.
    func requestUserBubbleSheet(id: UUID) {
        guard let i = blocks.firstIndex(where: { $0.id == id }),
            case .userBubble(let text, _) = blocks[i].kind
        else { return }
        onUserBubbleSheetRequested?(id, text)
    }

    /// Forwards an attachment-chip click to the SwiftUI image preview
    /// sheet. The chip's `NSImage` is the same instance the layout
    /// holds, handed off verbatim — no `.update` path, no row mutation;
    /// presentation is SwiftUI's responsibility once the closure fires.
    func requestImagePreview(image: NSImage) {
        onImagePreviewRequested?(image)
    }

    // MARK: - Width-change driven invalidation

    @objc func tableFrameDidChange(_ note: Notification) {
        guard let tableView else { return }
        // Resizes inside the >max clamp band leave `layoutWidth` unchanged —
        // `BlockCellView.layoutOrigin` re-centers content automatically from
        // the new `bounds.width`, no row needs its layout invalidated.
        let width = layoutWidth
        if width == lastLayoutWidth { return }
        lastLayoutWidth = width

        if !blocks.isEmpty {
            if tableView.inLiveResize {
                // Bounded per-frame layout work: only invalidate visible rows.
                // Off-screen rows keep their stale heights and stale cached
                // layouts — invisible to the user and repaired by the
                // post-resize background prefetch.
                let visible = tableView.rows(in: tableView.visibleRect)
                if visible.location != NSNotFound, visible.length > 0 {
                    invalidate(
                        rows: IndexSet(visible.location..<visible.location + visible.length),
                        in: tableView)
                }
            } else {
                // Outside live resize, frame changes are programmatic / one-off
                // (initial layout, window animation). Invalidate everything;
                // AppKit re-queries lazily on next layout pass.
                invalidate(rows: IndexSet(0..<blocks.count), in: tableView)
            }
        }
    }

    /// Scroll the table to the initial anchor — used by
    /// `Transcript2Controller.scrollToTail` and `setHistory`'s Phase 1.
    /// Forces an immediate layout pass before sampling `rect(ofRow:)`
    /// because `invalidate`'s `noteHeightOfRows` is async; without it
    /// the documentView frame may still trail the row-height total and
    /// `NSClipView.scroll(to:)` would be pinned by `constrainBoundsRect`.
    ///
    /// No-op when `tableView` is nil.
    func scrollToInitialAnchor(_ anchor: Transcript2Controller.InitialAnchor) {
        guard let tableView else { return }
        tableView.layoutSubtreeIfNeeded()
        // Record the settled display width so the detached layout warm
        // (`scheduleLayoutWarm`) has a width to typeset at once the session is
        // switched away. `tableFrameDidChange` is the other writer, but it can
        // miss the first attach (the frame may settle before its observer is
        // registered in `bindData`); reading here — after the tile, when
        // `layoutWidth` is reliable — is the deterministic capture.
        let settledWidth = layoutWidth
        if settledWidth > 0, settledWidth != lastLayoutWidth {
            lastLayoutWidth = settledWidth
        }
        switch anchor {
        case .bottom:
            if let lastId = blocks.last?.id {
                scrollRowToBottom(id: lastId, in: tableView)
            }
        case .top(let id):
            scrollRowToTop(id: id, in: tableView)
        case .bottomTo(let id):
            scrollRowToBottom(id: id, in: tableView)
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
        // Resize has ended at a settled width — tell the backfill pipeline so
        // its future pages typeset at the new width (§4.4). Fired before the
        // stale-row early-return so a resize that didn't move any *cached* row
        // (all misses already, or nothing to refill) still retargets.
        onLayoutWidthDidSettle?(width)
        let staleIdxs = indexesNeedingLayoutRefresh(at: width)
        // Empty → fully cached at this width. Common case when resize
        // ended at the start width with no actual change.
        guard !staleIdxs.isEmpty else { return }

        let snapshot = staleIdxs.map { blocks[$0] }
        let highlightSnapshot = highlightStorage.snapshot()
        let foldsSnapshot = foldStates
        let statusesSnapshot = statusStates

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
                if aborted { return }
                guard let self, let table = self.tableView,
                    self.layoutWidth == width
                else { return }
                // Re-resolve each prefetched layout to its current row. An
                // `apply` since the snapshot may have moved rows (a live
                // message, a backfill `.prepend`) or removed them (`.remove`);
                // a removed id resolves to nil and is dropped, so
                // we never cache a layout for a row that no longer exists nor
                // `noteHeightOfRows` a stale index.
                let resolved: [(id: UUID, idx: Int, layout: RowLayout)] =
                    entries.compactMap { id, layout in
                        guard let idx = self.blocks.firstIndex(where: { $0.id == id })
                        else { return nil }
                        return (id, idx, layout)
                    }
                self.withScrollAdjustment(.saveVisible(.visualTop), in: table) {
                    self.cacheLayouts(resolved.map { ($0.id, $0.layout) }, width: width)
                    let idxs = resolved.map(\.idx)
                    if !idxs.isEmpty {
                        table.noteHeightOfRows(withIndexesChanged: IndexSet(idxs))
                    }
                    // Force the re-tile NOW so `applyAnchor` (run by
                    // `withScrollAdjustment` right after this body) reads real
                    // `rect(ofRow:)`. `noteHeightOfRows` only invalidates; the
                    // re-tile is otherwise deferred to `beforeWaiting`, and the
                    // anchor would compensate against AppKit's still-stale
                    // heights → the row jumps. The layouts are already cached
                    // (off-main precompute + the `cacheLayouts` above), so this
                    // tile is cache-hit cheap, not a CTLine pass. Computing the
                    // compensation in-tick is exactly what makes a concurrent
                    // `apply` harmless and the old `mutationCounter` drift-guard
                    // unnecessary.
                    table.layoutSubtreeIfNeeded()
                }
            }
        }
    }

    // MARK: - Detached layout warm (off-main cache pre-fill for non-active sessions)

    /// Block ids awaiting an off-main layout warm, mapped to whether the write
    /// must **overwrite** an existing same-width entry. Coalesced within a
    /// runloop tick so a burst of detached inserts / highlight re-fills
    /// produces one warm task. Main-actor owned; the detached task reads only
    /// the immutable snapshot captured at drain — the same lock-free shape as
    /// the backfill pipeline, so there is no lock and no
    /// shared mutable buffer.
    private var pendingWarmLayouts: [UUID: Bool] = [:]
    private var warmScheduled = false
    private var warmTask: Task<Void, Never>?

    /// Warm-candidate ids for a change applied to a **detached** coordinator:
    /// the newly-inserted blocks. `.update` is deliberately excluded — a
    /// streaming entry re-`.update`s many times and only its final state
    /// matters, so warming each intermediate is churn; `.remove` has nothing
    /// to warm.
    private func warmCandidateIds(_ change: Transcript2Controller.Change) -> [UUID] {
        switch change {
        case .prepend(let new), .append(let new): return new.map(\.id)
        case .replace(_, let new): return new.map(\.id)
        case .update, .remove: return []
        }
    }

    /// Queue `ids` for an off-main layout warm at the last-displayed width
    /// (`lastLayoutWidth`). Called **only** from the detached paths (`apply`
    /// with no table; the detached arm of `handleHighlightDidFill`) — when a
    /// table is bound, layouts fill lazily through `heightOfRow` for visible
    /// rows and the active path is untouched. The point: a session the user
    /// switched away from keeps its layout cache warm as the bridge streams
    /// into it, so re-entry is a cache hit rather than an O(streamed-rows)
    /// main-thread typeset. `force` overwrites a same-width entry — needed for
    /// the highlight re-fill, whose coloured layout must win over a queued
    /// plain insert-warm regardless of completion order; the default `false`
    /// defers to `cacheLayouts`' anti-poison.
    private func scheduleLayoutWarm(ids: [UUID], force: Bool = false) {
        guard !ids.isEmpty else { return }
        for id in ids {
            pendingWarmLayouts[id] = (pendingWarmLayouts[id] ?? false) || force
        }
        guard !warmScheduled else { return }
        warmScheduled = true
        DispatchQueue.main.async { [weak self] in self?.drainLayoutWarm() }
    }

    /// Typeset the queued blocks off-main at `lastLayoutWidth` and land them
    /// through `cacheLayouts`. Mirrors `refillLayoutCache`'s detached-typeset
    /// shape (snapshot on main → `makeLayout` off-main → `cacheLayouts` on
    /// main); unlike refill there is no table, so there is no
    /// `noteHeightOfRows` / anchor work — only the cache is warmed.
    private func drainLayoutWarm() {
        warmScheduled = false
        let width = lastLayoutWidth
        // No display width recorded yet (the session has never been shown) →
        // no width to typeset against; a first attach computes these lazily.
        // Drop the queue so we don't spin.
        guard width > 0 else {
            pendingWarmLayouts.removeAll()
            return
        }
        let requests = pendingWarmLayouts
        pendingWarmLayouts.removeAll()
        let present = blocks.filter { requests[$0.id] != nil }
        guard !present.isEmpty else { return }
        let forced = Set(requests.filter { $0.value }.map(\.key))
        let highlightSnapshot = highlightStorage.snapshot()
        let foldsSnapshot = foldStates
        let statusesSnapshot = statusStates
        warmTask = Task.detached(priority: .utility) { [weak self] in
            let entries: [(UUID, RowLayout)] = present.map { block in
                (
                    block.id,
                    Self.makeLayout(
                        for: block, width: width,
                        highlights: highlightSnapshot,
                        folds: foldsSnapshot,
                        statuses: statusesSnapshot)
                )
            }
            await MainActor.run { [entries] in
                guard let self else { return }
                // A wrong-width entry (window resized while detached) is a
                // self-healing miss on re-attach, never a corruption (§4.4),
                // so we never gate on the table's current width here.
                self.cacheLayouts(
                    entries.filter { forced.contains($0.0) }, width: width, force: true)
                self.cacheLayouts(
                    entries.filter { !forced.contains($0.0) }, width: width)
            }
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        blocks.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard blocks.indices.contains(row) else { return 1 }
        let width = layoutWidth
        let pad = BlockStyle.blockPadding(for: blocks[row].kind)
        #if DEBUG
        let perfStart = Transcript2PerfLog.enabled ? CFAbsoluteTimeGetCurrent() : 0
        let perfCacheHit =
            Transcript2PerfLog.enabled
            ? (layoutCache[blocks[row].id]?.width == width) : false
        #endif
        let h =
            layout(for: blocks[row], width: width).totalHeight
            + pad.top + pad.bottom
        #if DEBUG
        if Transcript2PerfLog.enabled {
            let ms = (CFAbsoluteTimeGetCurrent() - perfStart) * 1000
            Transcript2PerfLog.trace(
                "heightOfRow row=\(row) kind=\(blocks[row].kindLabel) "
                    + "cached=\(perfCacheHit) h=\(Int(h.rounded())) "
                    + "ms=\(String(format: "%.2f", ms))")
        }
        #endif
        return h
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
        #if DEBUG
        // Cache-hit snapshot taken BEFORE the lazy lookup below would
        // populate it on miss — that way the trace shows whether scroll
        // is hitting the memo or burning new layouts.
        let perfCacheHit =
            Transcript2PerfLog.enabled
            ? (layoutCache[block.id]?.width == width) : false
        #endif
        let cellLayout = layout(for: block, width: width)
        #if DEBUG
        if Transcript2PerfLog.enabled {
            Transcript2PerfLog.trace(
                "viewFor row=\(row) kind=\(block.kindLabel) cached=\(perfCacheHit)")
        }
        #endif

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
        // Cell-margin gutters (copy button etc.). Sparse per kind —
        // empty for image / thematic break / tool group / loading pill.
        cell.gutters = block.gutters
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

    // MARK: - Gutter dispatch

    /// Run the action attached to `spec` for the block with `blockId`.
    /// Heavy work (text serialization, pasteboard write) runs on a
    /// detached `userInitiated` task so a click on a 10 MB code-block's
    /// gutter never stalls the main thread. The cell's visual feedback
    /// (checkmark flash) is fire-and-forget and doesn't wait on this
    /// path — opportunistic UX.
    ///
    /// No-op when the block can't be resolved (raced removal) or the
    /// serialized text is empty (block kind that doesn't expose copyable
    /// content yet).
    func handleGutter(_ spec: GutterSpec, blockId: UUID) {
        guard let block = block(forId: blockId) else { return }
        switch spec.kind {
        case .copy:
            // `Block` is `@unchecked Sendable` — the `Kind.image` NSImage
            // is the only mutable field, and `.image` blocks emit no
            // gutters, so the snapshot we hand to the detached task is
            // effectively immutable for our purposes.
            let snapshot = block
            Task.detached(priority: .userInitiated) {
                let text = snapshot.copyableText()
                guard !text.isEmpty else { return }
                // `NSPasteboard.general` is thread-safe for
                // `clearContents` + `setString`; no need to hop back
                // to main. AppKit documents the pasteboard as safe to
                // use from any thread.
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }
    }

    // MARK: - Selection helpers (consumed by SelectionCoordinator)

    /// Block at `row`, or `nil` if out of bounds. Selection-side reads
    /// must accept "no block here" because an async backfill drain or
    /// `refillLayoutCache` hop can change `blocks` between the caller's
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

    // MARK: - Gutter hover (coordinator-owned single source of truth)

    /// Block id whose cell is currently under the cursor, or `nil` when
    /// no cell is. The gutter visibility check ([BlockCellView+Gutter.swift]
    /// `drawGutters`) reads this through `cellHovered` — by living on
    /// the coordinator rather than each `BlockCellView`, cell recycling
    /// can't carry stale `true` from a previously-hovered row to a
    /// freshly-dequeued one. The invariant "at most one block shows the
    /// gutter at any instant" falls out of the type itself.
    ///
    /// Writes come from `BlockCellView.mouseEntered` / `mouseExited`;
    /// `didSet` redraws the cell whose hover state actually flipped
    /// (old → no gutter, new → gutter). Non-visible blocks are a no-op
    /// because there is no cell to mark dirty.
    var hoveredBlockId: UUID? {
        didSet {
            guard hoveredBlockId != oldValue else { return }
            markGutterRedraw(blockId: oldValue)
            markGutterRedraw(blockId: hoveredBlockId)
        }
    }

    /// `true` while the user is actively scrolling (trackpad / wheel /
    /// scroller drag). Cells gate their hover writes on this so rows
    /// streaming past a stationary cursor don't repeatedly trigger
    /// `mouseExited`/`mouseEntered` → `needsDisplay` → full cell
    /// re-rasterisation. The `.inVisibleRect` tracking area makes that
    /// otherwise unavoidable: AppKit re-aligns the rect to the cell's
    /// visible region every scroll tick, so a stationary cursor traverses
    /// every cell's rect in turn.
    ///
    /// Flipped by `scrollViewWillStartLiveScroll` / `scrollViewDidEndLiveScroll`,
    /// wired in `TranscriptScrollViewFactory.bindData`. Programmatic
    /// scrolls (`scrollRowToTop` / `scrollRowToBottom` / `applyAnchor`)
    /// don't fire these notifications and don't toggle the flag — they're
    /// rare and short, so the brief enter/exit pair they trigger isn't
    /// worth gating.
    private(set) var isLiveScrolling: Bool = false

    @objc func scrollViewWillStartLiveScroll(_ note: Notification) {
        isLiveScrolling = true
        // Clear stale hover on the cell that was hovered before scroll
        // started — that cell will scroll off / under the cursor's
        // last position anyway, and leaving its gutter glyph painted
        // looks broken once the row is no longer under the pointer.
        if let oldId = hoveredBlockId,
            let table = tableView,
            let row = blocks.firstIndex(where: { $0.id == oldId }),
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? BlockCellView
        {
            cell.clearHoverDuringLiveScroll()
        }
        hoveredBlockId = nil
    }

    @objc func scrollViewDidEndLiveScroll(_ note: Notification) {
        isLiveScrolling = false
        reevaluateHoverFromMouseLocation()
    }

    /// Re-resolve which cell the cursor is over right now and seed its
    /// hover state. Without this, gutter / chevron affordances would
    /// stay blank after a scroll until the user wiggles the mouse to
    /// fire a real `mouseMoved` event.
    private func reevaluateHoverFromMouseLocation() {
        guard let table = tableView, let window = table.window else { return }
        let mouseInScreen = NSEvent.mouseLocation
        let windowFrameInScreen = window.frame
        guard windowFrameInScreen.contains(mouseInScreen) else { return }
        let mouseInWindow = window.convertPoint(fromScreen: mouseInScreen)
        let mouseInTable = table.convert(mouseInWindow, from: nil)
        let row = table.row(at: mouseInTable)
        guard row >= 0, blocks.indices.contains(row) else { return }
        let id = blocks[row].id
        hoveredBlockId = id
        guard
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? BlockCellView
        else { return }
        let cellLocal = cell.convert(mouseInWindow, from: nil)
        cell.reevaluateHoverAt(cellLocal)
    }

    private func markGutterRedraw(blockId: UUID?) {
        guard let blockId, let table = tableView,
            let row = blocks.firstIndex(where: { $0.id == blockId })
        else { return }
        guard
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? BlockCellView
        else { return }
        cell.needsDisplay = true
    }

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

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
/// - **`apply(_:)`** — sync. Layouts compute lazily on `heightOfRow`
///   queries. Used for incremental updates (live messages, single removals,
///   tool-result updates).
/// - **`applyInBackground(_:)`** — layouts for the inserted blocks
///   compute on a detached `Task`, then a main hop installs them and runs
///   the structural change in one shot. Used by `Controller.loadInitial`'s
///   Phase 2 (large prepend after the viewport batch is already visible).
///
/// Both paths end with `reaffirmScrollMode()` so the post-mutation
/// scroll position tracks the current `ScrollMode` (stickyBottom or a
/// captured free-scroll anchor). The mode itself is the single source
/// of truth for "where the user wants to be looking" — see the
/// `ScrollMode` section near the top of the class.
///
/// ### Width change (resize)
///
/// `layoutCache` is keyed by `(id, width)`. When the table width changes,
/// existing entries become misses and lazy-recompute. `tableFrameDidChange`
/// invalidates rows + reaffirms `scrollMode`; live resize bounds work to
/// visible rows; `refillLayoutCache` (post-resize) precomputes off-screen
/// layouts on a detached task and runs its own reaffirm on the main hop.
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
/// drop its entire onMain block (including `noteHeightOfRows` and the
/// post-refill reaffirm) when an `apply` ran during the task — running
/// reaffirm against AppKit's still-stale internal heights would jitter
/// the anchor row when AppKit eventually re-queries.
@MainActor
final class Transcript2Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var tableView: NSTableView? {
        didSet {
            if let table = tableView, oldValue !== tableView {
                // A new table attached. Reset `lastLayoutWidth` so the
                // next `tableFrameDidChange` re-runs the invalidate +
                // `reaffirmScrollMode` pipeline for the new geometry.
                // `scrollMode` itself is session-scoped and survives the
                // attach — its value (sticky-bottom by default, or the
                // free-scroll position the user was last at) drives the
                // reaffirm transparently to callers.
                lastLayoutWidth = -1
                detachClipObserver()
                // If `apply` ran before the table was attached, blocks
                // already exist; the freshly-attached table starts at
                // `numberOfRows = 0` until reloaded. The default landing
                // position after `reloadData()` is the document top —
                // `tableFrameDidChange` reaffirms the scroll mode as
                // soon as the new width becomes positive, before the
                // frame paints, so the user never sees the transient.
                if !blocks.isEmpty {
                    table.reloadData()
                }
            }
        }
    }

    /// Notifies the controller after every successful mutation so SwiftUI
    /// observers on `blockCount` see the new value.
    var onBlockCountChanged: ((Int) -> Void)?

    /// Set by `Transcript2Controller` to forward chevron taps to the
    /// SwiftUI-owned sheet binding. The cell's mouseDown handler resolves
    /// the chevron hit, looks up the source `Block.Kind.userBubble(text:)`,
    /// and fires this — keeping the cross-layer signal narrow (one block
    /// id + the original text) so neither side reaches into the other's
    /// internals.
    var onUserBubbleSheetRequested: ((UUID, String) -> Void)?

    // MARK: - Scroll mode

    /// What the transcript should be visually showing right now. Single
    /// source of truth for scroll position, owned by the coordinator and
    /// (because the coordinator is session-scoped) automatically
    /// persisted across `ChatHistoryView` mount/unmount cycles. No upper
    /// layer captures or restores — the transcript is self-stabilizing.
    ///
    /// Every layout-affecting operation (`apply`, `applyInBackground`'s
    /// main hop, post-resize refill, `tableFrameDidChange` to a positive
    /// width) ends in `reaffirmScrollMode()`, which derives the desired
    /// clip-view y from the current mode and the just-settled geometry.
    /// "Bottom" is not a fixed y; it's a target that follows row-height
    /// reflows.
    enum ScrollMode: Sendable, Equatable {
        /// Pinned to the visual bottom of the document. Default for
        /// cold-load (chat). Stays sticky as new blocks append and as
        /// width changes reflow row heights — every reaffirm pulls the
        /// clip back to bottom.
        case stickyBottom
        /// User has free-scrolled to an arbitrary position. `blockId`
        /// names the row whose top edge was at `offsetFromClipTop`
        /// pixels from the clip's bounds origin at the time the mode
        /// was captured. Reaffirms compute
        /// `clip.y = rect(blockId).origin.y - offsetFromClipTop` so
        /// the same row stays visually fixed across reflows.
        case free(blockId: UUID, offsetFromClipTop: CGFloat)
    }

    /// Current scroll mode. Writes go through `setScrollMode(_:)` or
    /// `captureFreeScrollFromCurrentPosition()`. Readable for tests and
    /// the controller's high-level public methods.
    private(set) var scrollMode: ScrollMode = .stickyBottom

    /// Bracket flag: `true` while we are inside our own programmatic
    /// `scroll(to:)` call. The clip-view bounds observer reads this and
    /// skips mode capture for our own scrolls — without it, every
    /// reaffirm would immediately re-capture mode = .free at the
    /// just-set position and the stickiness would dissolve on the next
    /// layout change.
    private var isProgrammaticallyScrolling = false

    /// Clip view we have a `boundsDidChangeNotification` observer on.
    /// Set by `attachClipObserver`, cleared by `detachClipObserver`.
    /// Detached automatically when `tableView` changes, since the new
    /// table has its own (possibly different) enclosing scroll view.
    private weak var observedClipView: NSClipView?

    /// Tolerance for "is clip.y at the document bottom?" — handles
    /// CGFloat drift from `scroll(to:)` rounding (typically sub-pixel).
    private static let bottomDetectionEpsilon: CGFloat = 1.0

    /// Public entry for the controller / search nav. Sets the mode and
    /// immediately reaffirms against current geometry. Idempotent for
    /// equal modes — no-op when mode didn't change.
    func setScrollMode(_ mode: ScrollMode) {
        scrollMode = mode
        reaffirmScrollMode()
    }

    /// Compute the clip.y target for the current scroll mode against
    /// the current (table, scroll) geometry and apply it. Safe to call
    /// when the table or scroll view isn't bound yet — the next attach
    /// + `tableFrameDidChange` will reaffirm again. Bracketed by
    /// `isProgrammaticallyScrolling` so the clip bounds observer
    /// distinguishes this from user input.
    private func reaffirmScrollMode() {
        guard let table = tableView,
            let scroll = table.enclosingScrollView,
            scroll.contentView.bounds.height > 0
        else { return }
        let width = layoutWidth
        guard width > 0 else { return }
        // Force AppKit to re-query `heightOfRow:` for every row and
        // update its internal document-height bookkeeping BEFORE we
        // try to scroll. Two reasons this is necessary:
        //
        // - `insertRows` only schedules new rows for height-query; it
        //   doesn't synchronously sum them into `table.frame.height`.
        // - At the initial attach, NSTableView's documentView frame is
        //   based on `numberOfRows × defaultRowHeight` (the cheap
        //   default), not on per-row `heightOfRow:` results. Until
        //   those are queried, AppKit thinks the document is much
        //   shorter than it really is.
        //
        // `NSClipView.constrainBoundsRect:` (which `scroll(to:)` runs
        // through) clamps our target against `documentView.frame.size
        // .height`. With stale height, the clamp pins us at the
        // pre-content bottom, and subsequent AppKit layout passes
        // re-confirm that wrong position. `noteHeightOfRows` flushes
        // those heights synchronously; the matching `setFrameSize`
        // installs the resulting document height on the documentView,
        // so the clip's constraint can let our scroll target through.
        let indices = IndexSet(blocks.indices)
        if !indices.isEmpty {
            table.noteHeightOfRows(withIndexesChanged: indices)
        }
        let docHeight = documentHeight(width: width)
        if abs(table.frame.size.height - docHeight) > 0.5 {
            table.setFrameSize(
                NSSize(width: table.frame.size.width, height: docHeight))
        }
        let target = computeClipY(for: scrollMode, table: table, scroll: scroll)
        guard let target else { return }
        applyClipY(target, scroll: scroll)
    }

    /// Pure compute-only: derive the clip.y target for `mode` against
    /// the current document layout. Returns `nil` when blocks are empty
    /// or the geometry isn't ready (caller should leave clip unchanged
    /// in that case).
    ///
    /// Falls back gracefully: a `.free` mode whose block has since been
    /// removed mutates `scrollMode` back to `.stickyBottom` and re-
    /// computes.
    ///
    /// **Why we don't use `NSTableView.rect(ofRow:)`.** AppKit defers
    /// re-querying `heightOfRow` for freshly-inserted rows until its
    /// next layout pass, so `rect(ofRow: lastRow)` immediately after
    /// `insertRows` returns the OLD geometry (the row that USED to be
    /// last). Reaffirming against that target lands the clip at the
    /// pre-insert bottom, leaving the new rows off-screen below the
    /// fold. The coordinator's `layout(for:width:)` is the
    /// authoritative source of row heights at this moment — it
    /// lazy-computes against fresh content, no deferred re-query — so
    /// we walk it directly to compute document-relative positions.
    private func computeClipY(
        for mode: ScrollMode,
        table: NSTableView,
        scroll: NSScrollView
    ) -> CGFloat? {
        guard !blocks.isEmpty else { return nil }
        let width = layoutWidth
        guard width > 0 else { return nil }
        let visibleBottomInClip =
            scroll.contentView.bounds.height - scroll.contentInsets.bottom
        let lowerBound = -scroll.contentInsets.top

        switch mode {
        case .stickyBottom:
            let docHeight = documentHeight(width: width)
            let raw = docHeight - visibleBottomInClip
            return max(lowerBound, raw)
        case .free(let id, let offset):
            guard let row = blocks.firstIndex(where: { $0.id == id }) else {
                // Anchor block was removed (e.g. bridge dropped a transient
                // tool block while we were detached). Degrade to bottom.
                scrollMode = .stickyBottom
                return computeClipY(
                    for: scrollMode, table: table, scroll: scroll)
            }
            let rowY = rowTopY(row: row, width: width)
            let raw = rowY - offset
            let docHeight = documentHeight(width: width)
            let maxValid = max(lowerBound, docHeight - visibleBottomInClip)
            return max(lowerBound, min(raw, maxValid))
        }
    }

    /// Sum of all row heights at the current width, computed from
    /// `layout(for:width:)` rather than `NSTableView.bounds.height`.
    /// The latter lags behind structural mutations until AppKit
    /// re-tiles; this walks the coordinator's own layout cache (which
    /// lazy-fills against fresh content) for an immediate, authoritative
    /// total. Bounded by `blocks.count` × cache lookup — O(N) but
    /// reaffirms are rare (per mutation / per frame-change) and N is
    /// the same order as cold-load size.
    private func documentHeight(width: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for block in blocks {
            let pad = BlockStyle.blockPadding(for: block.kind)
            total += layout(for: block, width: width).totalHeight + pad.top + pad.bottom
        }
        return total
    }

    /// y of the top edge of `row` in document coordinates, computed the
    /// same way as `documentHeight` (sum of preceding row heights).
    /// Matches what `NSTableView.rect(ofRow: row).origin.y` would
    /// eventually return — but immediately, not after AppKit's next
    /// layout pass.
    private func rowTopY(row: Int, width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        for i in 0..<row {
            guard blocks.indices.contains(i) else { break }
            let pad = BlockStyle.blockPadding(for: blocks[i].kind)
            y += layout(for: blocks[i], width: width).totalHeight + pad.top + pad.bottom
        }
        return y
    }

    /// Wraps `clip.scroll(to:)` with the programmatic-scroll bracket so
    /// the bounds observer doesn't re-capture mode = .free at our own
    /// target.
    private func applyClipY(_ y: CGFloat, scroll: NSScrollView) {
        isProgrammaticallyScrolling = true
        defer { isProgrammaticallyScrolling = false }
        let target = NSPoint(
            x: scroll.contentView.bounds.origin.x, y: y)
        scroll.contentView.scroll(to: target)
    }

    // MARK: - User-scroll observation

    /// Begin observing `boundsDidChange` on this clip view. Detaches any
    /// previous observation first so we never have two live observers
    /// (would double-count user-scroll captures). Wired from
    /// `tableFrameDidChange` the first time the table appears inside a
    /// scroll view — by which point the clip view is stable.
    private func attachClipObserver(_ clipView: NSClipView) {
        if observedClipView === clipView { return }
        detachClipObserver()
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: clipView)
        observedClipView = clipView
    }

    /// Tear down the clip observer. Called from `tableView.didSet` (new
    /// table coming) and from `NativeTranscript2View.dismantleNSView`
    /// (via `removeAllObservers`-equivalent in the dismantle path).
    private func detachClipObserver() {
        if let cv = observedClipView {
            NotificationCenter.default.removeObserver(
                self, name: NSView.boundsDidChangeNotification, object: cv)
            observedClipView = nil
        }
    }

    /// Clip-view bounds change. Three sources fire this:
    ///
    /// - Our own `applyClipY` → bracketed by `isProgrammaticallyScrolling`,
    ///   skip; reaffirm is what put the clip here, so the mode already
    ///   matches.
    /// - AppKit follow-up adjustments after `tile()` (row heights settle,
    ///   `tile` re-clamps clip into the valid range, etc.). These land
    ///   asynchronously *after* our flag clears. To avoid mistaking them
    ///   for user input, we re-derive what clip.y the current mode
    ///   *would* land at and compare — a match (within an epsilon) means
    ///   we're already where the mode wants us, no transition needed.
    /// - User input (wheel, trackpad, keyboard, scroller drag) → the
    ///   new position will diverge from what the current mode would
    ///   pick. Fall through to `captureFreeScrollFromCurrentPosition`,
    ///   which either transitions to `.stickyBottom` (user landed at
    ///   the document bottom) or `.free(topVisibleRow, offset)`.
    @objc private func clipBoundsDidChange(_ note: Notification) {
        if isProgrammaticallyScrolling { return }
        guard let table = tableView,
            let scroll = table.enclosingScrollView
        else { return }
        let clipY = scroll.contentView.bounds.origin.y
        if let expected = computeClipY(
            for: scrollMode, table: table, scroll: scroll),
            abs(clipY - expected) < Self.bottomDetectionEpsilon
        {
            // We're already at the position the current mode targets;
            // this is an AppKit follow-up to our own reaffirm.
            return
        }
        captureFreeScrollFromCurrentPosition()
    }

    /// Derive a new `scrollMode` from the clip view's current position.
    /// Called only for user-initiated scrolls. Uses the coordinator's
    /// own layout cache for row positions (same posture as
    /// `computeClipY`) — `NSTableView.rect(ofRow:)` lags behind
    /// structural mutations until AppKit re-tiles, which would
    /// mis-classify positions immediately after `apply`.
    private func captureFreeScrollFromCurrentPosition() {
        guard let table = tableView,
            let scroll = table.enclosingScrollView,
            !blocks.isEmpty
        else { return }
        let width = layoutWidth
        guard width > 0 else { return }
        let clipY = scroll.contentView.bounds.origin.y
        let docHeight = documentHeight(width: width)
        let visibleBottomInClip =
            scroll.contentView.bounds.height - scroll.contentInsets.bottom
        let maxY = docHeight - visibleBottomInClip
        if clipY >= maxY - Self.bottomDetectionEpsilon {
            scrollMode = .stickyBottom
            return
        }
        // Walk the document downward until we cross clipY: the row
        // containing clipY (or the first row at or below it) is the
        // visible-top row. `offsetFromClipTop = rowTopY - clipY`
        // captures the sub-row precision so reaffirm puts the row back
        // at exactly the same fractional position.
        var y: CGFloat = 0
        for (i, block) in blocks.enumerated() {
            let pad = BlockStyle.blockPadding(for: block.kind)
            let h = layout(for: block, width: width).totalHeight + pad.top + pad.bottom
            if y + h > clipY {
                scrollMode = .free(
                    blockId: block.id,
                    offsetFromClipTop: y - clipY)
                return
            }
            y += h
            _ = i
        }
        // All rows ended above clipY — clip is beyond the document.
        // Treat as bottom (degenerate; clamp logic in computeClipY
        // would have caught this if reaffirm produced it).
        if let last = blocks.last {
            scrollMode = .free(
                blockId: last.id,
                offsetFromClipTop: y - clipY)
        }
    }

    // MARK: - View dismantle hook

    /// Called from `NativeTranscript2View.dismantleNSView` before the
    /// scroll view is torn down. Detaches our clip observer (the next
    /// table attach re-attaches against the new clip view) and leaves
    /// `scrollMode` intact for the next mount to consume. No explicit
    /// "capture" step: every user scroll has already been recorded
    /// continuously via `clipBoundsDidChange`, so the mode is already
    /// up to date at dismantle time.
    func willDismantleView() {
        detachClipObserver()
    }

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

    /// Tracks the `tableFrameDidChange` post-resize layout refill task.
    /// Superseded only by the next `refillLayoutCache`. `applyInBackground`'s
    /// detached task is intentionally *not* stored here — it's
    /// fire-and-forget so an in-flight row-mutation can't be interrupted
    /// by an unrelated cancel path.
    private var cacheRefillTask: Task<Void, Never>?

    /// Bumped on every `apply`. The refill task captures it at start;
    /// if it drifts during the task run, the entire onMain block (cache
    /// writes, `noteHeightOfRows`, reaffirm) is dropped. Reason: the
    /// post-refill reaffirm reads `heightOfRow` to compute the target
    /// clip.y, but `noteHeightOfRows` defers its re-query to the next
    /// layout pass — running reaffirm immediately compensates against
    /// stale internal heights and the row visually jumps when AppKit
    /// eventually catches up. Skipping refill in this case is harmless:
    /// `apply`'s own reaffirm already settled the post-mutation scroll
    /// state, and `heightOfRow` lazy-fills missing layouts on demand.
    /// `applyInBackground` doesn't bump because its own
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
    /// window for `reaffirmScrollMode` to trip on.
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

    func apply(_ changes: [Transcript2Controller.Change]) {
        // Bump so any inflight `cacheRefillTask` discards its onMain
        // hop. We don't cancel here: the counter is the actual guard,
        // and `cacheRefillTask` polices its own lifetime via the next
        // `refillLayoutCache`. Skipping refill in this window matters
        // because its post-resize reaffirm would compensate against
        // stale AppKit heights (deferred re-query) — running on top of
        // `apply`'s own reaffirm would jitter the anchor row.
        mutationCounter &+= 1

        if let table = tableView {
            // Disable implicit animations across the structural change
            // and the reaffirm: the layer-backed `.never` clip view
            // would otherwise animate its bounds origin from
            // `contentView.scroll(to:)`, racing with the cell-redraw
            // pass. Same suppression as the old `withScrollAdjustment`.
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            table.beginUpdates()
            for change in changes {
                applyStructuralChange(change, in: table)
            }
            table.endUpdates()
            // Reaffirm sees fresh `rect(ofRow:)` values immediately
            // because they lazy-recompute against the just-installed
            // layouts. `table.bounds.height` may lag until the next
            // tile pass, but `computeClipY` reads `rect(ofRow:)` of the
            // last row directly to compute the bottom — so the target
            // is correct without waiting for AppKit's deferred re-query.
            // The subsequent `tableFrameDidChange` (when AppKit
            // finalizes the height) reaffirms again as a safety net.
            reaffirmScrollMode()
            CATransaction.commit()
            NSAnimationContext.endGrouping()
        } else {
            // Table not attached. Just mutate `blocks`; the next attach
            // will `reloadData()` and `tableFrameDidChange` will
            // reaffirm scrollMode against the new geometry.
            for change in changes {
                applyStructuralChange(change, in: nil)
            }
        }

        onBlockCountChanged?(blocks.count)
    }

    // MARK: - Mutation: off-main (Phase 2 of loadInitial, future use cases)

    /// Layouts for the inserted blocks compute on a detached task; a
    /// single main hop installs them and runs the structural changes,
    /// then reaffirms the current scroll mode against the post-mutation
    /// geometry.
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
        completion: @MainActor @escaping () -> Void = {}
    ) {
        guard tableView != nil else {
            // Detached path: a background-emitted change (Phase B prepend,
            // loadInitial Phase 2) arrived while the table is not bound.
            // The controller is now session-scoped (lives across view
            // mount/dismount), so dropping the change would leave
            // `blocks` out of sync with the underlying handle's messages
            // for any session whose view isn't currently mounted. Route
            // through sync `apply` so `blocks` stays authoritative;
            // layouts compute lazily once a table re-attaches and the
            // first `tableFrameDidChange` reaffirms scroll mode.
            apply(changes)
            completion()
            return
        }
        let width = layoutWidth
        guard width > 0 else {
            // Table is attached but not yet tiled. Same posture as the
            // no-table branch above — degrade to sync apply so `blocks`
            // is current; the next `tableFrameDidChange` will reaffirm.
            apply(changes)
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
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                NSAnimationContext.current.allowsImplicitAnimation = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if self.layoutWidth == width {
                    self.cacheLayouts(entries, width: width)
                }
                table.beginUpdates()
                for change in changes {
                    self.applyStructuralChange(change, in: table)
                }
                table.endUpdates()
                self.reaffirmScrollMode()
                CATransaction.commit()
                NSAnimationContext.endGrouping()
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
        // Resizes inside the >max clamp band leave `layoutWidth`
        // unchanged — `BlockCellView.layoutOrigin` re-centers content
        // automatically from the new `bounds.width`, no row needs its
        // layout invalidated. But height-only changes (e.g. AppKit
        // tile() catching up to a recent `noteHeightOfRows`) still
        // reach this notification; we still want to reaffirm scroll
        // mode for those, because "stickyBottom" may have moved.
        let width = layoutWidth
        if width != lastLayoutWidth {
            lastLayoutWidth = width
            if !blocks.isEmpty {
                if tableView.inLiveResize {
                    // Bounded per-frame layout work: only invalidate visible
                    // rows. Off-screen rows keep their stale heights and
                    // stale cached layouts — invisible to the user and
                    // repaired by the post-resize background prefetch.
                    let visible = tableView.rows(in: tableView.visibleRect)
                    if visible.location != NSNotFound, visible.length > 0 {
                        invalidate(
                            rows: IndexSet(
                                visible.location..<visible.location + visible.length),
                            in: tableView)
                    }
                } else {
                    // Outside live resize, frame changes are programmatic /
                    // one-off (initial layout, window animation). Invalidate
                    // everything; AppKit re-queries lazily on next layout pass.
                    invalidate(rows: IndexSet(0..<blocks.count), in: tableView)
                }
            }
        }

        guard width > 0 else { return }

        // Reaffirm on EVERY positive frame change — not only the
        // initial 0→positive transition. SwiftUI's session-switch
        // commit can cycle the new table through transient widths
        // before landing on the final column width; the last fire
        // (terminal geometry) gives the authoritative scroll target,
        // so we just reapply every time and let it converge.
        //
        // Reaffirm runs BEFORE wiring the clip observer on the very
        // first frame change after attach. Reason: AppKit's
        // scrollView/clipView setup may fire transient
        // `boundsDidChange` notifications during initial layout that
        // come from clamping logic, not user input. Observing them
        // before our scroll target lands would let `computeClipY`
        // compare against pre-reaffirm geometry and mis-classify the
        // notification as user scroll, capturing a bogus `.free`
        // anchor. Reaffirming first guarantees the clip is at the
        // mode's target before any observer fires.
        reaffirmScrollMode()

        // Now wire (or keep) the clip-view observer for user-scroll
        // capture. `enclosingScrollView` becomes non-nil only after
        // `scroll.documentView = table` (assigned strictly after
        // `coordinator.tableView = table`), so this is the earliest
        // we can do it.
        if observedClipView == nil,
            let clip = tableView.enclosingScrollView?.contentView
        {
            attachClipObserver(clip)
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
        guard tableView != nil else { return }
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
                // reaffirm). Reason: noteHeightOfRows is deferred to the
                // next layout pass, so reaffirm would run against
                // AppKit's still-stale internal heights and produce a
                // wrong scroll target; the row visually jumps when
                // AppKit eventually re-queries. `apply` has already
                // settled its own scroll, and `heightOfRow` will
                // lazy-fill the layouts as needed.
                guard self.mutationCounter == snapshotCounter else { return }
                // applyInBackground (fire-and-forget, counter-untracked)
                // may have shifted indices. Re-resolve via id so
                // noteHeightOfRows targets the current dataSource state.
                let idxs = entries.compactMap { (id, _) -> Int? in
                    self.blocks.firstIndex { $0.id == id }
                }
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                NSAnimationContext.current.allowsImplicitAnimation = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.cacheLayouts(entries, width: width)
                if !idxs.isEmpty {
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(idxs))
                }
                self.reaffirmScrollMode()
                CATransaction.commit()
                NSAnimationContext.endGrouping()
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
    /// (top-aligned with the scroll view's top content inset honored).
    /// Used by search nav. No-op when the row is already in the visible
    /// band. Sets `scrollMode = .free(blockId, offsetFromClipTop:
    /// insets.top)` so subsequent layout reflows keep the hit visually
    /// anchored at the top — only a user-driven scroll will move on.
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
        setScrollMode(
            .free(
                blockId: blockId,
                offsetFromClipTop: scrollView.contentInsets.top))
    }

}

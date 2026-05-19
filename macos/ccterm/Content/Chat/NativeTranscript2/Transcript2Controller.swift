import AppKit

/// Identifies the user bubble whose full text should be shown in a SwiftUI
/// modal sheet. `id` is the originating block's id; `text` is the
/// untruncated source. `Identifiable` so SwiftUI's `.sheet(item:)`
/// resolves presentation identity from this value alone.
struct UserBubbleSheetRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
}

/// Public, imperative API for `NativeTranscript2`. Three orthogonal channels:
///
/// 1. **Mutation** — `apply(_:scroll:)` accepts one or more `Change` values
///    (insert / remove / update) and a `ScrollState`. Granular only; no
///    diff, no `reloadData` escape hatch.
/// 2. **First-screen load** — `loadInitial(_:anchor:)` is the dedicated
///    cold-load path. Splits into a viewport-covering Phase 1 (sync, main)
///    and a Phase 2 (off-main layout, main-hop insert) so 10k-row initial
///    loads don't block the main thread.
/// 3. **Query** — read-only snapshot accessors.
///
/// `@MainActor`-isolated. Background producers must hop before calling.
@MainActor
@Observable
final class Transcript2Controller {
    enum Change: Sendable {
        /// Insert `blocks` after the block with id `after`. `after: nil`
        /// prepends (index 0). If `after` is non-nil but unknown (e.g. the
        /// anchor was removed), the change is a no-op — same posture as
        /// `.update` / `.remove` for unknown ids. To append, pass the
        /// current last block's id (or `nil` if empty).
        case insert(after: UUID?, _ blocks: [Block])
        /// Remove every block whose id is in `ids`. Unknown ids are ignored.
        case remove(ids: [UUID])
        /// Replace the kind of an existing block, preserving its id. No-op
        /// if the id is unknown.
        case update(id: UUID, kind: Block.Kind)
    }

    /// What the table should do with scroll position around an `apply`.
    enum ScrollState: Sendable, Equatable {
        case none
        /// After applying, scroll so the row with `id` is at the visual top.
        case top(id: UUID)
        /// After applying, scroll so the row with `id` is at the visual bottom.
        case bottom(id: UUID)
        /// Capture an anchor row's screen position before the change,
        /// recompute scroll afterwards so the same row stays visually in
        /// place. `Side` picks which row in the visible range to anchor on.
        case saveVisible(Side)

        enum Side: Sendable {
            case visualTop
            case visualBottom
        }
    }

    /// Where to land scroll on first-screen load.
    enum InitialAnchor: Sendable, Equatable {
        /// Default for chat: last block pinned to visual bottom.
        case bottom
        /// Pin the block with `id` to the visual top (jump to message /
        /// unread marker).
        case top(id: UUID)
        /// Pin the block with `id` to the visual bottom.
        case bottomTo(id: UUID)
    }

    /// Mirrored from the coordinator after every mutation so SwiftUI can
    /// observe count changes without reaching into AppKit state.
    private(set) var blockCount: Int = 0

    /// Pending request for the SwiftUI "show full user message" sheet,
    /// driven by chevron clicks inside `BlockCellView`. NSView-internal
    /// interactions (link click, selection drag, chevron tap) are normally
    /// AppKit-closed-loop; this is the one well-defined exit point because
    /// `.sheet(item:)` is a SwiftUI presentation primitive and has to live
    /// on the SwiftUI side. `NativeTranscript2View` binds against this
    /// field and clears it on dismiss.
    var pendingUserBubbleSheet: UserBubbleSheetRequest?

    /// Observable snapshot of the in-transcript search state. Mirrored
    /// from `Transcript2SearchCoordinator` after every state change so
    /// SwiftUI hosts (search bar count, prev/next button enablement)
    /// re-render without touching AppKit state. `currentIndex` is
    /// 0-based; the search-bar UI displays it as `currentIndex + 1`.
    private(set) var searchState: SearchState = SearchState(
        query: "", totalHits: 0, currentIndex: nil)

    struct SearchState: Equatable, Sendable {
        let query: String
        let totalHits: Int
        /// `nil` when there are no hits at all, or the search hasn't
        /// been seeded yet. Otherwise 0-based.
        let currentIndex: Int?
    }

    /// Module-internal: handed to `NativeTranscript2View.makeCoordinator`.
    let coordinator: Transcript2Coordinator

    /// Last `setLoading(_:)` intent. Source of truth for whether the
    /// trailing pill row should be present. The actual block id (if
    /// any) lives in `loadingPillId` — re-pinning the pill to the
    /// last row after each external `apply` is what
    /// `reconcileLoadingPill()` does.
    private(set) var loadingPillVisible: Bool = false

    /// Block id of the in-flight pill row, or `nil` when no pill is
    /// installed. Reissued whenever the pill is removed and re-
    /// inserted (e.g. an `applyAppend` from the bridge slipped real
    /// blocks in after the pill — the reconciler tears the pill
    /// down and re-installs it at the new tail).
    private var loadingPillId: UUID?

    /// Recursion guard for `reconcileLoadingPill()`. The reconciler
    /// itself triggers `coordinator.apply`, which fires the
    /// `onBlockCountChanged` hook that drives reconciliation again —
    /// short-circuit reentry so the recursion ends at one level.
    private var loadingPillReconciling: Bool = false

    /// In-flight debounce for `setLoading(false)`. Holding the pill
    /// briefly after `isRunning` flips false smooths the transition
    /// between two adjacent turns: the next `.send(...)` arrives a
    /// frame or two later, flips `isRunning` back true, and the
    /// in-flight hide is cancelled — no insert/remove flicker. The
    /// same task drives the eventual `loadingPillVisible = false`
    /// when no follow-up arrives.
    private var pendingHideTask: Task<Void, Never>?

    /// Debounce window for the running indicator's disappearance.
    /// 400 ms covers the typical pause between sending a follow-up
    /// message after the previous turn's `.result` lands without
    /// dragging the pill noticeably past the response.
    private static let loadingHideDebounceSeconds: Double = 0.4

    /// `syntaxEngine` enables async syntax highlighting for code blocks.
    /// Pass `nil` (the default) for previews / tests / hosts without an
    /// engine — code blocks render as plain monospaced text. Hosts that
    /// only have access to the engine through SwiftUI environment can
    /// late-bind via `attachSyntaxEngine(_:)`.
    init(syntaxEngine: SyntaxHighlightEngine? = nil) {
        coordinator = Transcript2Coordinator(syntaxEngine: syntaxEngine)
        coordinator.onBlockCountChanged = { [weak self] count in
            guard let self else { return }
            self.blockCount = count
            // Reconcile after every structural change so a bridge-
            // driven `.insert(after: lastRealBlock, ...)` that landed
            // *before* the pill re-pins the pill to the new tail.
            // The recursion guard inside ensures the pill insert /
            // remove that reconciliation itself emits doesn't loop.
            self.reconcileLoadingPill()
        }
        coordinator.onUserBubbleSheetRequested = { [weak self] id, text in
            self?.pendingUserBubbleSheet = UserBubbleSheetRequest(id: id, text: text)
        }
        coordinator.onLayoutReady = { [weak self] in
            self?.consumePendingInitial()
        }
        coordinator.search.onStateChanged = { [weak self] in
            self?.refreshSearchState()
        }
    }

    /// macOS 26 SDK workaround — see `Session.deinit` for the
    /// background. The default `@MainActor` deinit aborts inside
    /// `swift::TaskLocal::StopLookupScope::~StopLookupScope()` when the
    /// dealloc chain tears down our `Transcript2HighlightStorage`'s
    /// `TaskLocal` state. `nonisolated` skips the executor hop.
    nonisolated deinit {}

    /// Deferred scroll anchor when the coordinator's table isn't mounted
    /// (or hasn't been tiled to a positive width) at `loadInitial` time.
    /// Consumed by `consumePendingInitial`, which `coordinator.onLayoutReady`
    /// invokes on the first 0→positive `layoutWidth` transition.
    ///
    /// Blocks themselves are no longer cached here — they are inserted
    /// into `coordinator.blocks` immediately even in the deferred path,
    /// so subsequent `apply()` calls (e.g. live `.appended` events
    /// arriving on a session whose view isn't yet mounted) can resolve
    /// anchors correctly. Only the scroll/anchor intent has to wait for
    /// a real table.
    private struct PendingInitial {
        let anchor: InitialAnchor
    }
    private var pendingInitial: PendingInitial?

    /// Late-bind a syntax engine. Pass-through to the coordinator. Safe
    /// to call repeatedly (idempotent on the same instance) and safe
    /// regardless of `loadInitial` ordering — the coordinator
    /// retroactively schedules already-installed blocks on first attach.
    func attachSyntaxEngine(_ engine: SyntaxHighlightEngine?) {
        coordinator.attachSyntaxEngine(engine)
    }

    // MARK: - Mutation

    /// Sync apply: layouts compute lazily on `heightOfRow` queries. Use for
    /// incremental updates (single message arrives, tool result fills in,
    /// user deletes one).
    func apply(_ changes: Change..., scroll: ScrollState = .none) {
        coordinator.apply(changes, scroll: scroll)
    }

    // MARK: - Loading pill

    /// Toggle the trailing "running" pill row. Idempotent — setting
    /// the same value twice is a no-op.
    ///
    /// **Where the pill lives.** The pill is a regular `Block` in
    /// `Transcript2Coordinator.blocks` (kind `.loadingPill`) sitting
    /// at the last index. Routing through the normal `apply` /
    /// `Change.insert` / `Change.remove` keeps every invariant the
    /// coordinator relies on — single source of truth, `numberOfRows`
    /// derives from `blocks.count`, no `pendingBlocks` side channel.
    ///
    /// **Pinning to the tail.** External structural changes (live
    /// `.appended` blocks from the bridge, `loadInitial`'s viewport
    /// batch consumed off a `pendingInitial` race) may slip in
    /// *after* the pill if their `.insert(after:)` resolves to the
    /// pill's id or relies on `coordinator.blockIds.last`. Every
    /// `apply` fires `onBlockCountChanged` → `reconcileLoadingPill()`,
    /// which sees the pill is no longer at the tail and re-pins it
    /// by removing + re-inserting at the new tail in one beat.
    func setLoading(_ visible: Bool) {
        if visible {
            // A new turn is starting — drop any pending hide so the
            // currently-visible pill carries through into the next
            // turn instead of flickering off and back on within a
            // few hundred ms.
            pendingHideTask?.cancel()
            pendingHideTask = nil
            guard !loadingPillVisible else { return }
            loadingPillVisible = true
            reconcileLoadingPill()
        } else {
            // Already off (or already scheduled) — nothing to do.
            guard loadingPillVisible, pendingHideTask == nil else { return }
            pendingHideTask = Task { [weak self] in
                try? await Task.sleep(
                    nanoseconds: UInt64(
                        Self.loadingHideDebounceSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.pendingHideTask = nil
                self.loadingPillVisible = false
                self.reconcileLoadingPill()
            }
        }
    }

    /// Bring the pill into compliance with `loadingPillVisible`:
    ///   • visible = true and pill missing / mispositioned →
    ///     remove (if it exists somewhere else) and insert at the
    ///     tail with a fresh id.
    ///   • visible = false and pill present → remove.
    ///
    /// Reentrant: every `coordinator.apply` here fires
    /// `onBlockCountChanged` which calls back into this method.
    /// The `loadingPillReconciling` flag short-circuits the inner
    /// call so the outer call's remove-then-insert sequence runs
    /// once, atomically from the caller's POV.
    private func reconcileLoadingPill() {
        if loadingPillReconciling { return }
        loadingPillReconciling = true
        defer { loadingPillReconciling = false }

        let blockIds = coordinator.blockIds
        let pillIdSnapshot = loadingPillId
        let pillIsLast = pillIdSnapshot != nil && blockIds.last == pillIdSnapshot

        if loadingPillVisible {
            if pillIsLast { return }
            // Pill exists but isn't at the tail (a real-block insert
            // landed after it) — tear it out so the re-insert below
            // lands at the actual tail and the row identity refreshes
            // cleanly (no stale layout cache entry under the old id).
            if let id = pillIdSnapshot, blockIds.contains(id) {
                coordinator.apply([.remove(ids: [id])], scroll: .none)
            }
            let newId = UUID()
            loadingPillId = newId
            coordinator.apply(
                [.insert(after: coordinator.blockIds.last, [Block(id: newId, kind: .loadingPill)])],
                scroll: .none)
        } else {
            if let id = pillIdSnapshot, blockIds.contains(id) {
                coordinator.apply([.remove(ids: [id])], scroll: .none)
            }
            loadingPillId = nil
        }
    }

    // MARK: - Tool status

    /// Push a new runtime `ToolStatus` for a tool surface. `id` may be
    /// either a `toolGroup` host `Block.id` (group-level status — drives
    /// the group header's palette) or a nested `ToolGroupBlock.Child.id`
    /// (per-child status — drives one child header). The owning row is
    /// resolved on the coordinator side; callers don't need to know
    /// which tier they're addressing.
    ///
    /// Refresh is granular: only the host row reloads (single-row
    /// `reloadData(forRowIndexes:)`), and row height stays put (status
    /// only repaints header colour, never moves glyphs). Sibling rows
    /// are untouched.
    ///
    /// Idempotent: setting the same status twice is a no-op. Status for
    /// an unknown id is cached so a future insert carrying that id
    /// picks the value up via the next `makeLayout`.
    func setToolStatus(id: UUID, status: ToolStatus) {
        coordinator.setStatus(id: id, status: status)
    }

    // MARK: - First-screen load

    /// Two-phase initial load. Phase 1 (sync) inserts a viewport-covering
    /// slice so the user sees correct content immediately. Phase 2 (off-main
    /// layout, main-hop insert) installs the rest with `.saveVisible` to
    /// keep Phase 1 visually fixed.
    ///
    /// The vertical scroller is push-hidden across both phases — Phase 1's
    /// scroll-to-anchor and Phase 2's insert+saveVisible both perturb the
    /// scroll origin, and the overlay scroller's auto-flash on
    /// `contentSize` change would otherwise paint a bouncing knob across
    /// the cold-load. Popped after Phase 1 (no-Phase-2 branch) or from
    /// Phase 2's completion (which `applyInBackground` guarantees to fire).
    func loadInitial(_ blocks: [Block], anchor: InitialAnchor = .bottom) {
        guard !blocks.isEmpty else { return }

        let width = coordinator.layoutWidth
        let viewportHeight = coordinator.viewportHeight
        appLog(
            .info, "Transcript2Controller",
            "[scroll-bug] loadInitial blocks=\(blocks.count) anchor=\(anchor) "
                + "width=\(width) viewportH=\(viewportHeight) "
                + "tableBound=\(coordinator.debugHasTable) "
                + "deferred=\(!(width > 0 && viewportHeight > 0))")
        guard width > 0, viewportHeight > 0 else {
            // Table not mounted / not yet tiled. **Insert the blocks into
            // `coordinator.blocks` immediately** so subsequent `apply()`s
            // — live `.appended` events on background sessions whose view
            // hasn't been mounted yet — can resolve anchors against a
            // populated array. Only the scroll-to-anchor intent is
            // deferred: when the coordinator's `onLayoutReady` fires,
            // `consumePendingInitial` scrolls the (already-present)
            // anchor row into view.
            //
            // Idempotent on re-entry: if `coordinator.blocks` already
            // matches `blocks` (e.g. a second `loadInitial(same payload)`
            // — rare, mostly tests), skip the insert.
            if coordinator.blockIds != blocks.map(\.id) {
                let existing = coordinator.blockIds
                var changes: [Transcript2Controller.Change] = []
                if !existing.isEmpty {
                    changes.append(.remove(ids: existing))
                }
                changes.append(.insert(after: nil, blocks))
                coordinator.apply(changes, scroll: .none)
            }
            pendingInitial = PendingInitial(anchor: anchor)
            return
        }
        // Path reached the real-width branch — drop any stale pending so a
        // racing `onLayoutReady` after this point doesn't double-apply.
        pendingInitial = nil

        let slice = Self.sliceForViewport(
            blocks: blocks, anchor: anchor,
            width: width, viewportHeight: viewportHeight)

        let phase1Scroll: ScrollState
        let phase2Side: ScrollState.Side
        switch anchor {
        case .bottom:
            phase1Scroll = .bottom(id: blocks[slice.viewportRange.upperBound - 1].id)
            phase2Side = .visualBottom
        case .top(let id):
            phase1Scroll = .top(id: id)
            phase2Side = .visualTop
        case .bottomTo(let id):
            phase1Scroll = .bottom(id: id)
            phase2Side = .visualBottom
        }

        let viewportBatch = Array(blocks[slice.viewportRange])
        let above = Array(blocks[..<slice.viewportRange.lowerBound])
        let below =
            slice.viewportRange.upperBound < blocks.count
            ? Array(blocks[slice.viewportRange.upperBound...])
            : []

        coordinator.pushScrollerHidden()

        // Phase 1 — viewport batch, sync. heightOfRow lazy-computes layouts
        // for the visible rows; cost is bounded by viewport size.
        coordinator.apply(
            [.insert(after: coordinator.blockIds.last, viewportBatch)],
            scroll: phase1Scroll)

        // Phase 2 — the rest, off-main layout. ID-based anchors mean
        // ordering between the two inserts no longer matters: each anchor
        // resolves at apply-time independently of the other change.
        var phase2: [Change] = []
        if !below.isEmpty {
            phase2.append(.insert(after: viewportBatch.last?.id, below))
        }
        if !above.isEmpty {
            phase2.append(.insert(after: nil, above))
        }
        if phase2.isEmpty {
            coordinator.popScrollerHidden()
        } else {
            coordinator.applyInBackground(phase2, scroll: .saveVisible(phase2Side)) {
                [weak coordinator] in coordinator?.popScrollerHidden()
            }
        }
    }

    // MARK: - Search

    /// Re-run a literal, case-insensitive search across the
    /// transcript. Empty query clears state. Selecting a query of "x"
    /// then editing to "xy" is just another `runSearch("xy")` call —
    /// the coordinator drops the prior hit set and recomputes.
    func runSearch(_ query: String) {
        coordinator.search.runQuery(query)
    }

    /// Step the search cursor forward, wrapping past the end. No-op
    /// when there are no hits. Triggers auto-expand + scroll-into-view
    /// on the new current hit.
    func nextSearchHit() { coordinator.search.next() }

    /// Step the search cursor backward, wrapping past the start.
    func previousSearchHit() { coordinator.search.previous() }

    /// Drop the search session entirely. Clears all yellow rects and
    /// resets `searchState` to empty. Idempotent.
    func endSearch() { coordinator.search.clear() }

    private func refreshSearchState() {
        let s = coordinator.search
        searchState = SearchState(
            query: s.query,
            totalHits: s.totalHits,
            currentIndex: s.currentIndex)
    }

    // MARK: - Query

    var blockIds: [UUID] { coordinator.blockIds }

    /// Invoked by `coordinator.onLayoutReady` once the table tiles to a
    /// positive width. Blocks are already in `coordinator.blocks` (the
    /// `loadInitial` no-width branch pre-inserted them); this is purely
    /// the deferred scroll-to-anchor step. No-op when nothing is pending
    /// — `coordinator` may fire `onLayoutReady` on resize-time 0→positive
    /// sequences unrelated to a deferred initial load.
    private func consumePendingInitial() {
        guard let pending = pendingInitial else {
            appLog(
                .info, "Transcript2Controller",
                "[scroll-bug] consumePendingInitial NO-OP (no pending)")
            return
        }
        appLog(
            .info, "Transcript2Controller",
            "[scroll-bug] consumePendingInitial FIRES anchor=\(pending.anchor) "
                + "blocks=\(coordinator.blockIds.count)")
        pendingInitial = nil
        scrollToInitialAnchor(pending.anchor)
    }

    /// Apply the deferred scroll-to-anchor. Resolves `.bottom` against the
    /// current last block id (which may have grown past the original
    /// `loadInitial` payload — live `.appended` events arriving on a
    /// background session land here legitimately). For `.top(id:)` and
    /// `.bottomTo(id:)`, the anchor id is the original one supplied by
    /// the caller.
    private func scrollToInitialAnchor(_ anchor: InitialAnchor) {
        let scroll: ScrollState
        switch anchor {
        case .bottom:
            guard let lastId = coordinator.blockIds.last else {
                appLog(
                    .info, "Transcript2Controller",
                    "[scroll-bug] scrollToInitialAnchor(.bottom) NO-OP (blockIds empty)")
                return
            }
            scroll = .bottom(id: lastId)
        case .top(let id):
            scroll = .top(id: id)
        case .bottomTo(let id):
            scroll = .bottom(id: id)
        }
        appLog(
            .info, "Transcript2Controller",
            "[scroll-bug] scrollToInitialAnchor anchor=\(anchor) → \(scroll) "
                + "tableBound=\(coordinator.debugHasTable) "
                + "blocks=\(coordinator.blockIds.count)")
        coordinator.apply([], scroll: scroll)
    }

    /// Scroll the transcript to its last block. Called by view-mount paths
    /// that need to anchor a re-attached `NSTableView` to the conversation
    /// tail — `coordinator.tableView`'s `didSet` runs `reloadData()`
    /// automatically, but AppKit's default landing position after reload
    /// is the top of the document, which reads as "lost the chat" for a
    /// chat-style transcript.
    func scrollToBottom() {
        scrollToInitialAnchor(.bottom)
    }

    // MARK: - Slicing (private)

    private struct Slice {
        /// Range into the original `blocks` array covering the viewport.
        let viewportRange: Range<Int>
    }

    /// Walks `blocks` from the anchor outward, accumulating row heights
    /// until viewport is covered. Pure: only reads `Coordinator.makeLayout`
    /// (a `nonisolated static` function); does not mutate cache.
    private static func sliceForViewport(
        blocks: [Block],
        anchor: InitialAnchor,
        width: CGFloat,
        viewportHeight: CGFloat
    ) -> Slice {
        func rowHeight(_ block: Block) -> CGFloat {
            let pad = BlockStyle.blockPadding(for: block.kind)
            return Transcript2Coordinator.makeLayout(for: block, width: width).totalHeight
                + pad.top + pad.bottom
        }

        switch anchor {
        case .bottom:
            var height: CGFloat = 0
            var first = blocks.count
            for i in stride(from: blocks.count - 1, through: 0, by: -1) {
                height += rowHeight(blocks[i])
                first = i
                if height >= viewportHeight { break }
            }
            return Slice(viewportRange: first..<blocks.count)

        case .top(let id):
            guard let anchorIdx = blocks.firstIndex(where: { $0.id == id }) else {
                return sliceForViewport(
                    blocks: blocks, anchor: .bottom,
                    width: width, viewportHeight: viewportHeight)
            }
            var height: CGFloat = 0
            var last = anchorIdx
            for i in anchorIdx..<blocks.count {
                height += rowHeight(blocks[i])
                last = i
                if height >= viewportHeight { break }
            }
            return Slice(viewportRange: anchorIdx..<last + 1)

        case .bottomTo(let id):
            guard let anchorIdx = blocks.firstIndex(where: { $0.id == id }) else {
                return sliceForViewport(
                    blocks: blocks, anchor: .bottom,
                    width: width, viewportHeight: viewportHeight)
            }
            var height: CGFloat = 0
            var first = anchorIdx
            for i in stride(from: anchorIdx, through: 0, by: -1) {
                height += rowHeight(blocks[i])
                first = i
                if height >= viewportHeight { break }
            }
            return Slice(viewportRange: first..<anchorIdx + 1)
        }
    }
}

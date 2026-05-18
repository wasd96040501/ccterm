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
/// 1. **Mutation** — `apply(_:)` accepts one or more `Change` values
///    (insert / remove / update). Granular only; no diff, no `reloadData`
///    escape hatch. Each call reaffirms the coordinator's `scrollMode`
///    against the post-mutation geometry, so "sticky-bottom" stays
///    sticky as new blocks arrive and free-scroll anchors follow reflows.
/// 2. **First-screen load** — `loadInitial(_:)` is the dedicated cold-
///    load path. Splits into a viewport-covering Phase 1 (sync, main)
///    and a Phase 2 (off-main layout, main-hop insert) so 10k-row
///    initial loads don't block the main thread. Implicit chat-style
///    sticky-bottom scroll mode.
/// 3. **Scroll position** — `scrollToBottom()` re-enters sticky-bottom
///    mode. Position is otherwise *not* a caller concern: the coordinator
///    owns its own `ScrollMode`, persists it across view detach/re-attach
///    (because the coordinator is session-scoped), and reaffirms on
///    every layout-affecting event. Hosts never capture + restore.
/// 4. **Query** — read-only snapshot accessors.
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

    /// Late-bind a syntax engine. Pass-through to the coordinator. Safe
    /// to call repeatedly (idempotent on the same instance) and safe
    /// regardless of `loadInitial` ordering — the coordinator
    /// retroactively schedules already-installed blocks on first attach.
    func attachSyntaxEngine(_ engine: SyntaxHighlightEngine?) {
        coordinator.attachSyntaxEngine(engine)
    }

    // MARK: - Mutation

    /// Sync apply: layouts compute lazily on `heightOfRow` queries. Use
    /// for incremental updates (single message arrives, tool result
    /// fills in, user deletes one). Reaffirms the coordinator's
    /// `scrollMode` against the post-mutation geometry automatically —
    /// no scroll-state argument needed.
    func apply(_ changes: Change...) {
        coordinator.apply(changes)
    }

    // MARK: - Scroll position

    /// Re-enter sticky-bottom mode. Use for the explicit
    /// "scroll-to-bottom" affordance (floating button, ⌘↓ shortcut).
    /// Idempotent on already-sticky-bottom mode; if the user had
    /// free-scrolled, mode transitions back and the clip lands at the
    /// current document bottom.
    ///
    /// Coldload sites do **not** need to call this — `loadInitial`
    /// implicitly sets sticky-bottom mode before the insert.
    func scrollToBottom() {
        coordinator.setScrollMode(.stickyBottom)
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
                coordinator.apply([.remove(ids: [id])])
            }
            let newId = UUID()
            loadingPillId = newId
            coordinator.apply(
                [.insert(after: coordinator.blockIds.last, [Block(id: newId, kind: .loadingPill)])])
        } else {
            if let id = pillIdSnapshot, blockIds.contains(id) {
                coordinator.apply([.remove(ids: [id])])
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

    /// Two-phase initial load for chat-style sticky-bottom presentation.
    /// Phase 1 (sync) inserts a viewport-covering slice so the user sees
    /// correct content immediately. Phase 2 (off-main layout, main-hop
    /// insert) installs the rest above it; the coordinator's reaffirm
    /// keeps the bottom anchored across both phases.
    ///
    /// Sets `coordinator.scrollMode = .stickyBottom` before inserting,
    /// so even the no-width deferred branch (table not mounted yet)
    /// will land at bottom the moment the first `tableFrameDidChange`
    /// runs reaffirm.
    ///
    /// The vertical scroller is push-hidden across both phases —
    /// reaffirm perturbs the scroll origin twice (Phase 1 + Phase 2),
    /// and the overlay scroller's auto-flash on `contentSize` change
    /// would otherwise paint a bouncing knob across the cold-load.
    /// Popped after Phase 1 (no-Phase-2 branch) or from Phase 2's
    /// completion (which `applyInBackground` guarantees to fire).
    func loadInitial(_ blocks: [Block]) {
        guard !blocks.isEmpty else { return }

        // Setting the mode BEFORE the insert ensures the very first
        // post-insert reaffirm targets bottom. Reaffirm during `apply`
        // computes bottom relative to the last inserted row. Without
        // this, a session whose previous mount left scrollMode in
        // `.free(...)` would mis-anchor on cold-load.
        coordinator.setScrollMode(.stickyBottom)

        let width = coordinator.layoutWidth
        let viewportHeight = coordinator.viewportHeight
        guard width > 0, viewportHeight > 0 else {
            // Table not mounted / not yet tiled. Insert blocks into
            // `coordinator.blocks` immediately — subsequent `apply()`s
            // (live `.appended` events on background sessions whose view
            // hasn't been mounted yet) need a populated array. The
            // sticky-bottom scroll mode we just set above will be
            // reaffirmed on the first `tableFrameDidChange` after the
            // new table is attached.
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
                coordinator.apply(changes)
            }
            return
        }

        let slice = Self.sliceForViewportBottom(
            blocks: blocks, width: width, viewportHeight: viewportHeight)

        let viewportBatch = Array(blocks[slice.viewportRange])
        let above = Array(blocks[..<slice.viewportRange.lowerBound])

        coordinator.pushScrollerHidden()

        // Phase 1 — viewport batch, sync. heightOfRow lazy-computes
        // layouts for the visible rows; cost is bounded by viewport
        // size. The reaffirm inside `apply` lands the clip at bottom of
        // this slice (which is the document tail).
        coordinator.apply(
            [.insert(after: coordinator.blockIds.last, viewportBatch)])

        // Phase 2 — the rest, off-main layout. Prepended above the
        // viewport batch; the post-mutation reaffirm sees the last row
        // unchanged (still the same Phase-1 last block) and keeps the
        // clip at bottom.
        if above.isEmpty {
            coordinator.popScrollerHidden()
        } else {
            coordinator.applyInBackground([.insert(after: nil, above)]) {
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

    // MARK: - Slicing (private)

    private struct Slice {
        /// Range into the original `blocks` array covering the viewport.
        let viewportRange: Range<Int>
    }

    /// Walks `blocks` from the tail upward, accumulating row heights
    /// until viewport is covered. Returns the suffix range that should
    /// land in Phase 1 of `loadInitial`. Pure: only reads
    /// `Coordinator.makeLayout` (a `nonisolated static` function);
    /// does not mutate cache.
    private static func sliceForViewportBottom(
        blocks: [Block],
        width: CGFloat,
        viewportHeight: CGFloat
    ) -> Slice {
        func rowHeight(_ block: Block) -> CGFloat {
            let pad = BlockStyle.blockPadding(for: block.kind)
            return Transcript2Coordinator.makeLayout(for: block, width: width).totalHeight
                + pad.top + pad.bottom
        }
        var height: CGFloat = 0
        var first = blocks.count
        for i in stride(from: blocks.count - 1, through: 0, by: -1) {
            height += rowHeight(blocks[i])
            first = i
            if height >= viewportHeight { break }
        }
        return Slice(viewportRange: first..<blocks.count)
    }
}

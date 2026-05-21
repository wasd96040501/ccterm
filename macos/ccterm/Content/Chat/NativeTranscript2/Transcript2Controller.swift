import AppKit

/// Identifies the user bubble whose full text should be shown in a SwiftUI
/// modal sheet. `id` is the originating block's id; `text` is the
/// untruncated source. `Identifiable` so SwiftUI's `.sheet(item:)`
/// resolves presentation identity from this value alone.
struct UserBubbleSheetRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
}

/// Carries an attachment chip's `NSImage` from the AppKit click to the
/// SwiftUI `.sheet(item:)`. `id` is allocated per request so consecutive
/// taps on the **same** chip (NSImage instance) still re-present the
/// sheet — `.sheet(item:)` only re-fires when `id` changes. Equatable so
/// `@Observable` knows when to publish.
struct ImagePreviewRequest: Identifiable, Equatable {
    let id: UUID
    let image: NSImage

    init(image: NSImage) {
        self.id = UUID()
        self.image = image
    }
}

/// Public, imperative API for `NativeTranscript2`. Three orthogonal channels:
///
/// 1. **Mutation** — `apply(_:scroll:)` accepts one or more `Change` values
///    (insert / remove / update) and a `ScrollState`. Granular only; no
///    diff, no `reloadData` escape hatch.
/// 2. **History snapshot** — `setHistory(_:anchor:)` declares the whole
///    block list at once and an anchor. Idempotent and repeatable — every
///    call resets `isAnchorSettled` to false until the new anchor lands.
///    Internally splits large payloads into a viewport-covering Phase 1
///    (sync, main) and a Phase 2 (off-main layout, main-hop insert) so
///    10k-row snapshots don't block the main thread.
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

    /// "First-screen anchor has landed for the currently-attached
    /// `NSTableView`." Mirrors `Transcript2Coordinator.isAnchorSettled`
    /// so SwiftUI hosts can observe it directly — e.g. fade in the
    /// transcript or run any other "wait until first frame is stable"
    /// effect.
    ///
    /// Resets to false on every `setHistory` and on every fresh table
    /// attach (session switch / view rebuild). Flips to true once
    /// `setHistory`'s Phase 1 has scrolled to the requested anchor, or
    /// — for the deferred no-width branch — once `tableFrameDidChange`
    /// consumes the desired anchor on the first 0→positive transition.
    ///
    /// Routine `append` / `update` / `remove` traffic does **not** flip
    /// this back to false; streaming a new message into an already-
    /// stabilized transcript is not a first-screen event.
    private(set) var isAnchorSettled: Bool = false

    /// Pending request for the SwiftUI "show full user message" sheet,
    /// driven by chevron clicks inside `BlockCellView`. NSView-internal
    /// interactions (link click, selection drag, chevron tap) are normally
    /// AppKit-closed-loop; this is the one well-defined exit point because
    /// `.sheet(item:)` is a SwiftUI presentation primitive and has to live
    /// on the SwiftUI side. `NativeTranscript2View` binds against this
    /// field and clears it on dismiss.
    var pendingUserBubbleSheet: UserBubbleSheetRequest?

    /// Pending request for the SwiftUI image preview sheet, driven by
    /// chip clicks inside `BlockCellView`. Same escape-hatch contract as
    /// `pendingUserBubbleSheet`: NSView-internal interactions stay
    /// AppKit-closed-loop except for `.sheet(item:)` presentation, which
    /// SwiftUI owns. `NativeTranscript2View` binds against this field
    /// and clears it on dismiss.
    var pendingImagePreview: ImagePreviewRequest?

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

    /// First-tile work waiting for `layoutWidth > 0`. Set by `setHistory`
    /// when called before the table has tiled; drained by `handleFirstTile`
    /// on the next 0→positive transition. Survives `tableView` detach /
    /// re-attach so a user who navigates away mid-load returns to the
    /// requested anchor when they come back.
    private var pendingFirstTile: InitialAnchor?

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
        coordinator.onImagePreviewRequested = { [weak self] image in
            self?.pendingImagePreview = ImagePreviewRequest(image: image)
        }
        coordinator.onAnchorSettledChanged = { [weak self] settled in
            self?.isAnchorSettled = settled
        }
        coordinator.onTableDidTile = { [weak self] in
            self?.handleFirstTile()
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
    /// regardless of `setHistory` ordering — the coordinator
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
    /// `.appended` blocks from the bridge, `setHistory`'s viewport
    /// batch landing on a fresh attach) may slip in *after* the pill
    /// if their `.insert(after:)` resolves to the pill's id or relies
    /// on `coordinator.blockIds.last`. Every
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

    // MARK: - History snapshot

    /// Declare the transcript's contents as a snapshot — `blocks` becomes
    /// the new full block list, `anchor` is the scroll position the table
    /// must land at once layout settles. Resets `isAnchorSettled` to
    /// false; flips back to true after Phase 1 scrolls (real-width
    /// branch) or after `handleFirstTile` scrolls on the next 0→positive
    /// `tableFrameDidChange` transition (zero-width branch).
    ///
    /// Two-phase internally for large snapshots: Phase 1 (sync) inserts a
    /// viewport-covering slice so the user sees correct content
    /// immediately; Phase 2 (off-main layout, main-hop insert) installs
    /// the rest with `.saveVisible` to keep Phase 1 visually fixed.
    ///
    /// The vertical scroller is push-hidden across both phases — Phase 1's
    /// scroll-to-anchor and Phase 2's insert+saveVisible both perturb the
    /// scroll origin, and the overlay scroller's auto-flash on
    /// `contentSize` change would otherwise paint a bouncing knob across
    /// the cold-load. Popped after Phase 1 (no-Phase-2 branch) or from
    /// Phase 2's completion (which `applyInBackground` guarantees to fire).
    ///
    /// Repeatable: calling again replaces the snapshot. Idempotent in the
    /// degenerate case where the same id list comes back through
    /// (`coordinator.blockIds == blocks.map(\.id)` short-circuits).
    func setHistory(_ blocks: [Block], anchor: InitialAnchor = .bottom) {
        guard !blocks.isEmpty else { return }

        // Flip `isAnchorSettled` back to false up front. SwiftUI consumers
        // see false→true on every new snapshot landing; the eventual
        // `handleFirstTile` (deferred path) or our explicit call below
        // (real-width path) restores true via `markAnchorSettled`.
        coordinator.markAnchorUnsettled()

        let width = coordinator.layoutWidth
        let viewportHeight = coordinator.viewportHeight
        let canDriveImmediately = width > 0 && viewportHeight > 0

        if canDriveImmediately {
            // Real-width path: enter `.suppressed` BEFORE swapping data
            // so the upcoming `apply` routes through the no-AppKit
            // branch — AppKit never sees the intermediate
            // "old transcript empty, viewport-only inserted" state.
            // After the swap, `handleFirstTile` drives the same Phase 1
            // / Phase 2 rollout the reentry path uses, sharing the
            // exact downstream pipeline.
            coordinator.suppressForSetHistory()
        }

        // Data swap: replace the current `blocks` with the new payload.
        // While `gate` is `.suppressed` (either entered just above for
        // the real-width path, or already from `tableView.didSet`'s
        // re-entry branch for the deferred path), this routes through
        // the no-AppKit branch and only mutates `coordinator.blocks`.
        //
        // Idempotent on a same-payload re-call (rare, mostly tests):
        // if the id list already matches, skip the structural change
        // entirely.
        pendingFirstTile = anchor
        if coordinator.blockIds != blocks.map(\.id) {
            let existing = coordinator.blockIds
            var changes: [Transcript2Controller.Change] = []
            if !existing.isEmpty {
                changes.append(.remove(ids: existing))
            }
            changes.append(.insert(after: nil, blocks))
            coordinator.apply(changes, scroll: .none)
        }

        if canDriveImmediately {
            // Drive the phased rollout immediately. `handleFirstTile`
            // reads `pendingFirstTile` for the anchor, computes the
            // slice via `Transcript2ViewportSlicer`, and runs Phase 1
            // (`installPhase1Slice` + scroll + `markAnchorSettled`)
            // followed by Phase 2 (`runPhase2`'s off-main precompute
            // + main-hop `insertRows` of the rest under `.saveVisible`).
            handleFirstTile()
        }
        // Deferred path (`!canDriveImmediately`): `pendingFirstTile`
        // is set; the next `tableFrameDidChange` → `materializeFirstAppear`
        // → `onTableDidTile` → `handleFirstTile` picks it up when the
        // first positive-width transition lands.
    }

    /// Called by `Transcript2Coordinator.materializeFirstAppear` on
    /// the first 0→positive `tableFrameDidChange` transition after a
    /// `tableView` attach. Coordinator's gate is currently
    /// `.suppressed`; this handler decides between the phased
    /// materialize rollout (the normal path, when viewport geometry
    /// is available) and the all-or-nothing `materializeAsFull`
    /// fallback.
    ///
    /// **Phased rollout (Phase 1 + Phase 2):**
    /// 1. Compute the viewport-covering slice via
    ///    `Transcript2ViewportSlicer.slice`, anchored at
    ///    `pendingFirstTile` (or `.bottom` for a plain re-attach).
    /// 2. Phase 1: `coordinator.installPhase1Slice(slice)` flips the
    ///    gate to `.visible(slice)` and reloads — AppKit's first
    ///    layout pass typesets just `slice.count` rows synchronously.
    /// 3. Scroll to the anchor (within the slice), then
    ///    `markAnchorSettled` — first-screen contract fulfilled.
    /// 4. Phase 2: `coordinator.runPhase2(...)` precomputes layouts
    ///    for above + below on a detached task; main-hop installs the
    ///    rest under `.saveVisible(...)` so the visible anchor doesn't
    ///    move.
    ///
    /// **Fallback (`materializeAsFull`)** runs when:
    /// - viewport height is unknown (no scroll view, windowless test
    ///   harness), or
    /// - the controller has no blocks (`pendingFirstTile` is nil and
    ///   `blockIds.isEmpty`) — nothing to do at all in that case.
    ///
    /// `markAnchorSettled` runs in both phased and fallback branches
    /// so SwiftUI's `isAnchorSettled` observer flips on time.
    private func handleFirstTile() {
        let anchor: InitialAnchor? = {
            if let pending = pendingFirstTile { return pending }
            return coordinator.blockIds.isEmpty ? nil : .bottom
        }()
        pendingFirstTile = nil
        #if DEBUG
        Transcript2ReentryStats.recordHandleFirstTile()
        #endif
        guard let anchor else {
            // No anchor → empty session attach. Coordinator's gate
            // stayed `.full` (empty branch in `tableView.didSet`); no
            // materialize to drive. The `onTableDidTile` path only
            // fires for non-empty attaches anyway, but stay defensive.
            return
        }

        let width = coordinator.layoutWidth
        let viewportHeight = coordinator.viewportHeight
        if width > 0, viewportHeight > 0 {
            // Phased rollout: slice + install + scroll + Phase 2.
            let slice = Transcript2ViewportSlicer.slice(
                blocks: coordinator.blocksSnapshot(),
                anchor: anchor,
                width: width,
                viewportHeight: viewportHeight)
            coordinator.installPhase1Slice(slice)
            coordinator.scrollToInitialAnchor(anchor)
            coordinator.markAnchorSettled()
            coordinator.runPhase2()
        } else {
            // Fallback: no viewport geometry → can't slice. Issue the
            // single-step materialize matching PR #179's behavior.
            coordinator.materializeAsFull()
            coordinator.scrollToInitialAnchor(anchor)
            coordinator.markAnchorSettled()
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
}

import AppKit

/// Identifies the user bubble whose full text should be shown in a
/// modal sheet. `id` is the originating block's id; `text` is the
/// untruncated source. `Identifiable` so `Transcript2SheetPresenter`
/// can tag the open sheet against the request that opened it.
struct UserBubbleSheetRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
}

/// Carries an attachment chip's `NSImage` from the AppKit click to
/// `Transcript2SheetPresenter`. `id` is allocated per request so
/// consecutive taps on the **same** chip (NSImage instance) still
/// re-present the sheet — the presenter compares request ids to decide
/// whether the open sheet still matches. Equatable so `@Observable`
/// knows when to publish.
struct ImagePreviewRequest: Identifiable, Equatable {
    let id: UUID
    let image: NSImage

    init(image: NSImage) {
        self.id = UUID()
        self.image = image
    }
}

/// Public, imperative API for `NativeTranscript2`. Two orthogonal channels:
///
/// 1. **Mutation** — `apply(_:scroll:precomputed:)` accepts one or more
///    `Change` values (prepend / append / replace / remove / update) and a
///    `ScrollState`. Granular only; no diff, no `reloadData` escape hatch, no
///    whole-list `setHistory` snapshot (deleted — history load is the backfill
///    pipeline draining `.prepend` / `.append` through this same entry).
///    `precomputed` lets the pipeline land off-main-built
///    layouts as cache hits.
/// 2. **Query** — read-only snapshot accessors.
///
/// `@MainActor`-isolated. Background producers must hop before calling.
@MainActor
@Observable
final class Transcript2Controller {
    /// Structural mutation vocabulary. Position is **intrinsic** for the
    /// position-free cases — top (`prepend`), tail (`append`), or in place
    /// (`replace` / `update` / `remove`). `insert(after:)` is the **one**
    /// anchored case: the caller names the block to insert behind, used by the
    /// bridge's append-only growth so a settled block above the new tail is
    /// never removed/reinserted (no `.effectFade` flicker). The anchor is
    /// validated against live `blocks` — an unknown (or `nil`-but-no-head)
    /// anchor degrades to a no-op / head insert, the same posture as `.update`
    /// / `.remove` for unknown ids — so a stale anchor can never misplace a
    /// row. Scroll intent rides with the case: `append` sticks to the bottom,
    /// everything else preserves the visible viewport.
    enum Change: Sendable {
        /// Prepend `blocks` at the head (index 0). Drives backfill batches.
        case prepend(_ blocks: [Block])
        /// Append `blocks` at the tail. Drives live tail entries + the pill.
        case append(_ blocks: [Block])
        /// Insert `blocks` immediately **after** the block with id `after`
        /// (`after == nil` → head). Unknown `after` is a no-op. The anchored
        /// in-place insert: append-only entry growth re-states nothing, so the
        /// settled block above the new tail keeps its row (no fade churn).
        case insert(after: UUID?, _ blocks: [Block])
        /// Swap the contiguous run of `oldIds` for `with` **at the same start
        /// index**, atomically — the structure-changed segment swap. A
        /// degenerate `oldIds == []` (or none present) routes to `.append`.
        case replace(oldIds: [UUID], with: [Block])
        /// Remove every block whose id is in `ids`. Unknown ids are ignored.
        case remove(ids: [UUID])
        /// Replace the kind of an existing block, preserving its id. No-op
        /// if the id is unknown.
        case update(id: UUID, kind: Block.Kind)
    }

    /// Off-main-built `(id, RowLayout)` layouts to install as cache hits
    /// **before** a structural change, tagged with the `width` they were
    /// typeset at. The backfill pipeline's producer builds these so the
    /// `heightOfRow` query `insertRows` fires inside `endUpdates` is a cache
    /// hit, not an on-main CTLine pass. `width` is
    /// self-healing: an entry whose width doesn't match the table's current
    /// `layoutWidth` is simply a miss that lazy-recomputes, never a corruption,
    /// so there is no validate gate.
    struct PrecomputedLayouts: Sendable {
        let layouts: [(UUID, RowLayout)]
        let width: CGFloat
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

    /// Pending request for the "show full user message" sheet, driven
    /// by chevron clicks inside `BlockCellView`. NSView-internal
    /// interactions stay AppKit-closed-loop; this is one of two
    /// `@Observable` request fields `Transcript2SheetPresenter`
    /// observes and turns into an AppKit-native sheet
    /// (`view.window?.beginSheet`) wrapping a SwiftUI body
    /// (`UserBubbleSheetView`) hosted via `NSHostingController`. The
    /// presenter clears this field on dismiss.
    var pendingUserBubbleSheet: UserBubbleSheetRequest?

    /// Pending request for the attachment-image preview sheet, driven
    /// by chip clicks inside `BlockCellView`. Same observation +
    /// presentation contract as `pendingUserBubbleSheet`:
    /// `Transcript2SheetPresenter` opens a sheet via the host window
    /// with `ImagePreviewSheetView` as the SwiftUI body, and clears
    /// this field on dismiss.
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

    /// Module-internal: AppKit hosts read this via
    /// `TranscriptScrollViewFactory.bindData(_:controller:)` to wire
    /// it onto the `NSTableView`'s `dataSource` / `delegate`.
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
            // driven `.append(...)` that landed *before* the pill
            // re-pins the pill to the new tail.
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
    ///
    /// `precomputed` carries off-main-built layouts + the width they were
    /// typeset at (the backfill pipeline's producer — §4.3). They install into
    /// the layout cache before the structural change so the prepend/append tick
    /// is a cache **hit**, not an on-main CTLine pass. `nil` by default — every
    /// incremental-update caller is unaffected.
    func apply(
        _ changes: Change...,
        scroll: ScrollState = .none,
        precomputed: PrecomputedLayouts? = nil
    ) {
        coordinator.apply(changes, scroll: scroll, precomputed: precomputed)
    }

    /// Settled, clamped row width the table currently lays out at (forwards
    /// `coordinator.layoutWidth`). `0` when no table is bound. The backfill
    /// pipeline reads this once after attach settles to seed its off-main
    /// typeset; subsequent resizes ride the coordinator's
    /// `onLayoutWidthDidSettle` hook into `retarget(width:)`.
    var layoutWidth: CGFloat { coordinator.layoutWidth }

    /// Monotonic count of on-main `RowLayout` recomputes (cache misses typeset
    /// synchronously). Forwarded from the coordinator. Hosts read it as a
    /// *delta* around the attach-tick tile to log how many rows a reentry had
    /// to typeset on the main thread — never per row. See
    /// `Transcript2Coordinator.mainThreadLayoutComputes`.
    var mainThreadLayoutComputes: Int { coordinator.mainThreadLayoutComputes }

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
    /// `.appended` blocks from the bridge, a backfill `.prepend` /
    /// `.append`) may slip in *after* the pill if their tail-relative
    /// position resolves past it. Every
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
                [.append([Block(id: newId, kind: .loadingPill)])],
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

    /// Read the current `ToolStatus` for a tool surface. Defaults to
    /// `.completed` for ids the coordinator hasn't seen — matches the
    /// layout-side "absent = completed" convention.
    func toolStatus(for id: UUID) -> ToolStatus {
        coordinator.status(for: id)
    }

    /// Update the live turn token usage shown to the right of the running
    /// pill. Forwarded to the coordinator, which repaints the pill row (if
    /// present) with no height change. Idempotent.
    func setTurnUsage(_ usage: TurnTokenUsage) {
        coordinator.setTurnUsage(usage)
    }

    /// Update the running pill's elapsed-clock anchor (the turn's start
    /// instant). Forwarded to the coordinator, which repaints the pill row so
    /// the hosted `LoadingPillUsageView` picks up the new start and self-ticks.
    /// Idempotent — unchanged values are dropped coordinator-side.
    func setTurnStartedAt(_ date: Date?) {
        coordinator.setTurnStartedAt(date)
    }

    /// Sweep every `.running` entry to `.completed` in one pass. Wired
    /// up from `Transcript2EntryBridge.handleTurnFinished()`, which the
    /// runtime calls inside `finishTurn` (live `.result`). `.failed` /
    /// `.cancelled` survive — only the spinning-but-unresolved ones flip.
    func clearAllRunningStatuses() {
        coordinator.clearAllRunningStatuses()
    }

    /// Scroll the table so the tail (latest block) sits at the visual
    /// bottom. Used by the host (`TranscriptDetailVC`) immediately
    /// after `view.layoutSubtreeIfNeeded()` to anchor a re-attached
    /// session at its most recent message. No-op when there are no
    /// blocks or no table attached.
    func scrollToTail() {
        guard !coordinator.blockIds.isEmpty else { return }
        coordinator.scrollToInitialAnchor(.bottom)
    }

    /// Hide the vertical scroller while a cold history backfill streams
    /// `.prepend` pages, then restore it. The backfill pipeline drives this:
    /// `true` at `start`, `false` at `reportLoaded`. Only ever active during a
    /// cold load (the pipeline never runs on warm re-entry). Forwards to the
    /// coordinator, which owns the scroll view. See
    /// `Transcript2Coordinator.setHistoryBackfilling(_:)`.
    func setHistoryBackfilling(_ active: Bool) {
        coordinator.setHistoryBackfilling(active)
    }

    /// Fires **once** when the cold-load first screen is visually complete —
    /// either the rendered content covers the viewport, or the whole producer
    /// drained (a short session that never fills the screen). The backfill
    /// pipeline drives `notifyFirstScreenReady()`; this is the edge a future
    /// image-bake reveal hangs off (drop the outgoing session's frozen
    /// snapshot the moment the incoming cold session has real content).
    ///
    /// AppKit consumer → synchronous closure, not `@Observable` (the detail VC
    /// owns the bake overlay). No queryable latch is needed: a cold attach
    /// subscribes here before `loadHistory()` starts the pipeline, so the
    /// subscription always precedes the earliest possible fire.
    @ObservationIgnored var onFirstScreenReady: (() -> Void)?
    @ObservationIgnored private var didFireFirstScreenReady = false

    /// Latched, fire-once. Safe to call from every drain tick — the guard
    /// collapses the "viewport covered" and "fully drained" conditions into a
    /// single edge.
    func notifyFirstScreenReady() {
        guard !didFireFirstScreenReady else { return }
        didFireFirstScreenReady = true
        onFirstScreenReady?()
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

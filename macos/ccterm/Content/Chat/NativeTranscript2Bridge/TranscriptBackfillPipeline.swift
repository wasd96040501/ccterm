import AgentSDK
import AppKit
import Foundation

/// Source of raw history pages, read **reverse** (newest page first). The
/// reader abstraction is injected by initializer (REFACTOR-PLAN §12.3): the
/// production wiring supplies a JSONL reverse pager, Group B injects a fake
/// yielding canned pages. Each page is a contiguous slice of the file in
/// **document order**; `nextPage` returns the tail page first and walks toward
/// the file top, returning `nil` once the top is reached.
protocol ReversePageSource: AnyObject {
    func nextPage() async -> [Message2]?
}

/// The content pipeline (REFACTOR-PLAN §4.5): an off-main producer task
/// **builds** pre-typeset block pages and **pushes** them into a lock-guarded
/// `PipelineInbox`; the main thread **drains** them into the controller. The
/// producer never hops to (or blocks on) the main actor per page — it builds at
/// full speed and posts a single coalesced, fire-and-forget drain signal — so
/// throughput is bounded by `max(build rate, apply rate)` rather than serialized
/// through a main-actor round-trip per page. Async backpressure
/// (`inbox.waitForCapacity()`) caps resident pre-built pages so the decoupling
/// can't run the producer away into an unbounded memory spike.
///
/// - The first non-empty page is the tail page; it lands at the (empty)
///   tail via `.append`, then scrolls to tail (the attach tick's
///   `scrollToTail` was a no-op against the cold empty table — this is the
///   first content, so it owns the one-time scroll-to-tail).
/// - Every later page is older history; it `.prepend`s above with
///   viewport preservation.
/// - When the producer reaches the file top **and** the buffer empties,
///   `onLoaded` fires exactly once.
///
/// Both heavy costs run **off-main** inside the producer: markdown parsing
/// (`MarkdownDocument(parsing:)`) and per-row CTLine typesetting
/// (`Transcript2Coordinator.makeLayout` — `nonisolated static`, §2.5). Each
/// page carries its pre-built `(id, RowLayout)` layouts plus the
/// width they were typeset at; the drain installs them through the single
/// `apply(_:scroll:precomputed:)` entry, so the prepend's
/// in-`endUpdates` `heightOfRow` query is a cache **hit**, not a main-thread
/// CTLine pass (REFACTOR-PLAN §4.3 / §5.1). The off-main width comes from
/// `start(width:)` (once, after TICK-1 settle) and `retarget(width:)`
/// (at live-resize end); a width mismatch is self-healing (§4.4), never a gate.
@MainActor
final class TranscriptBackfillPipeline {

    private let source: ReversePageSource
    private weak var controller: Transcript2Controller?

    /// Thread-safe producer→drain hand-off (buffer + typeset width + drain-
    /// coalescing + async backpressure). The producer pushes here off-main; the
    /// drain consumes on main. Replaces the old per-page `await MainActor.run`.
    private let inbox: PipelineInbox

    /// Loose main-thread per-tick block cap (REFACTOR-PLAN §9.2): a safety
    /// valve, not a typeset budget. A single page exceeding it still lands
    /// whole — the cap bounds a batch, never splits a page (§9.3).
    private let budget: Int

    /// Fires once when the file top is reached and the buffer is drained.
    private let onLoaded: () -> Void

    /// Fires on the drain, per applied page, with the entries that produced it.
    /// Production routes these to historical tool-status derivation; tests
    /// ignore them. Runs after the blocks land so the ids exist.
    private let onApplied: ([MessageEntry]) -> Void

    // MARK: Main-owned buffer + drain bookkeeping

    /// One pre-built page: the entries, their blocks, the off-main `(id,
    /// RowLayout)` layouts, and the width those layouts were typeset at. Built
    /// entirely off-main by the producer and handed to the drain through
    /// `PipelineInbox` (the values are `@unchecked Sendable`).
    struct PendingPage {
        let entries: [MessageEntry]
        let blocks: [Block]
        let layouts: [(UUID, RowLayout)]
        let width: CGFloat

        /// The off-main layouts + width bundled for `Transcript2Controller.apply`.
        var precomputed: Transcript2Controller.PrecomputedLayouts {
            .init(layouts: layouts, width: width)
        }
    }

    private var didFirstApply = false
    private var didReportLoaded = false
    private var task: Task<Void, Never>?

    // MARK: Read-only debug probe (observation only, never gates behavior)

    var onDrainTickForDebug: ((_ appliedBlocks: Int) -> Void)?

    init(
        source: ReversePageSource,
        controller: Transcript2Controller,
        budget: Int = 40,
        bufferCapacity: Int = 8,
        onLoaded: @escaping () -> Void = {},
        onApplied: @escaping ([MessageEntry]) -> Void = { _ in }
    ) {
        self.source = source
        self.controller = controller
        self.budget = budget
        self.inbox = PipelineInbox(width: 0, capacity: bufferCapacity)
        self.onLoaded = onLoaded
        self.onApplied = onApplied
    }

    nonisolated deinit {}

    /// Start the off-main producer at `width` (the settled, clamped row width
    /// read from `controller.layoutWidth` after the attach tick settles —
    /// REFACTOR-PLAN §6 TICK 1). The ONE call that seeds the typeset width.
    /// Idempotent — a second call is a no-op. Also subscribes to the
    /// coordinator's `onLayoutWidthDidSettle` so a resize-end retargets future
    /// pages without the host having to wire anything. Paired with
    /// `retarget(width:)` (same shape) for the post-resize width update.
    func start(width: CGFloat) {
        guard task == nil else { return }
        inbox.setWidth(width)
        // Suppress the overlay scroller for the load window — every drain
        // `.prepend` grows the document and flashes the thumb in. Restored in
        // `reportLoaded` once the buffer is fully drained. Only ever runs on a
        // cold load (the pipeline is built once, never on warm re-entry).
        controller?.setHistoryBackfilling(true)
        controller?.coordinator.onLayoutWidthDidSettle = { [weak self] settled in
            self?.retarget(width: settled)
        }
        let source = self.source
        let inbox = self.inbox
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var builder = ReverseEntryBuilder()
            while let page = await source.nextPage() {
                // Feed the page's messages in reverse document order; collect
                // the entries finalized by this page (already document order).
                var finalized: [MessageEntry] = []
                for message in page.reversed() {
                    finalized = builder.ingest(message) + finalized
                }
                guard !finalized.isEmpty else { continue }
                // Markdown parse + CTLine typeset both happen here, off-main.
                let blocks = MessageEntryBlockBuilder.blocks(from: finalized)
                guard !blocks.isEmpty else { continue }
                let pageWidth = inbox.width  // lock-read, no main-actor hop
                let layouts = Self.typeset(blocks, width: pageWidth)
                inbox.push(
                    PendingPage(
                        entries: finalized, blocks: blocks,
                        layouts: layouts, width: pageWidth))
                self?.requestDrain()
                // Async backpressure: park the producer (off-main, no thread
                // blocked) when the buffer is full; the drain resumes it.
                if inbox.isAtCapacity { await inbox.waitForCapacity() }
            }
            // File top: flush the still-open group + true orphans.
            let tail = builder.finish()
            let tailBlocks = MessageEntryBlockBuilder.blocks(from: tail)
            if !tailBlocks.isEmpty {
                let tailWidth = inbox.width
                let tailLayouts = Self.typeset(tailBlocks, width: tailWidth)
                inbox.push(
                    PendingPage(
                        entries: tail, blocks: tailBlocks,
                        layouts: tailLayouts, width: tailWidth))
            }
            inbox.markFinished()
            self?.requestDrain()
        }
    }

    /// Update the width future pages typeset at (REFACTOR-PLAN §4.4). Called
    /// from the coordinator's `onLayoutWidthDidSettle` at live-resize **end**
    /// only — never per-frame during a drag. Pure perf: pages already built at
    /// the old width self-heal through the width-keyed cache on `heightOfRow`
    /// miss; skipping `retarget` stays correct, it just wastes one off-main
    /// typeset per stale page. Forwards to the inbox (read off-main by the
    /// producer on its next page).
    func retarget(width: CGFloat) {
        inbox.setWidth(width)
    }

    /// Off-main CTLine typeset of a page's blocks at `width`. `makeLayout` is
    /// `nonisolated static` (§2.5); the load-time `highlights` / `folds` /
    /// `statuses` snapshots are empty/default (fresh block ids carry no fold or
    /// status, and height is token-independent — §2.12), so the precomputed
    /// height matches what the lazy `heightOfRow` path would produce.
    private nonisolated static func typeset(
        _ blocks: [Block], width: CGFloat
    ) -> [(UUID, RowLayout)] {
        blocks.map { ($0.id, Transcript2Coordinator.makeLayout(for: $0, width: width)) }
    }

    /// Stop the producer (e.g. session torn down before load completes). Also
    /// resumes a producer parked on backpressure so the detached task isn't
    /// stranded on a never-resumed continuation.
    func cancel() {
        task?.cancel()
        task = nil
        inbox.cancelWaiter()
    }

    // MARK: - Drain (main)

    /// Post a coalesced, **non-blocking** drain. Called from the off-main
    /// producer after each `inbox.push` and from the drain's own reschedule, so
    /// it is `nonisolated` — it only touches the `Sendable` inbox and posts the
    /// main-queue block. `acquireDrainSlot` coalesces concurrent calls so only
    /// one drain is ever outstanding. This is the producer's entire interaction
    /// with main: a fire-and-forget post, never an `await`.
    nonisolated func requestDrain() {
        guard inbox.acquireDrainSlot() else { return }
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    private func drain() {
        inbox.releaseDrainSlot()
        var appliedBlocks = 0  // all applied this tick — the debug probe's view
        var typesetBlocks = 0  // miss-only — the real per-tick cost the cap bounds
        while let pageWidth = inbox.peekFirstWidth() {
            // A page whose precompute width matches the live table is a pure
            // cache-hit insert: `heightOfRow` is a dict lookup per row, no
            // CTLine pass (§2.6). Those cost ~nothing on the main thread, so
            // they drain without counting toward the budget — the first screen
            // lands in one tick. Only a width-mismatched page (resize during
            // load → cache miss → synchronous typeset) is budgeted, so the cap
            // splits exactly the path that can freeze the main thread, and
            // nothing else (REFACTOR-PLAN §9.2 "safety valve, not a typeset
            // budget"). `nil` width sentinel when no controller → treated as a
            // miss, but `applyPage` no-ops anyway. Peek the width first so a
            // budget-deferred miss page stays in the buffer for the next tick.
            let willHit = (controller?.layoutWidth ?? -1) == pageWidth
            if !willHit && typesetBlocks >= budget { break }
            guard let page = inbox.popFirst() else { break }
            applyPage(page)
            appliedBlocks += page.blocks.count
            if !willHit { typesetBlocks += page.blocks.count }
            // Fire the first-screen edge as soon as the viewport is covered.
            if controller?.coordinator.contentCoversViewport == true {
                controller?.notifyFirstScreenReady()
            }
        }
        if appliedBlocks > 0 { onDrainTickForDebug?(appliedBlocks) }
        if inbox.hasPending {
            requestDrain()
        } else if inbox.isFinished {
            reportLoaded()
        }
    }

    private func applyPage(_ page: PendingPage) {
        guard let controller else { return }
        // The off-main layouts install before the structural change so the
        // prepend/append tick is a cache hit, not an on-main CTLine pass.
        if didFirstApply {
            // Older history: stack above, keep the visible viewport fixed.
            controller.apply(
                .prepend(page.blocks), scroll: .saveVisible(.visualTop),
                precomputed: page.precomputed)
        } else {
            didFirstApply = true
            if controller.blockCount == 0 {
                // COLD table: this tail page IS the first content. The
                // view-lifecycle `scrollToTail` at the attach tick (TICK 1) ran
                // against an *empty* table, so it was a no-op — there was
                // nothing to anchor. So the one-time scroll-to-tail belongs
                // here, right after the tail lands. (Warm re-entry never reaches
                // this branch: `loadHistory` is an idempotent no-op once blocks
                // are already present, so the pipeline never runs.)
                controller.apply(.append(page.blocks), precomputed: page.precomputed)
                controller.scrollToTail()
            } else {
                // Live content streamed in before the first deposit (REFACTOR-PLAN
                // §7) — e.g. the user sent a message within the cold gap. That
                // live content is the *newest*, so the tail history page is older
                // and must land ABOVE it: prepend, not append. Keep the viewport
                // on the live tail the user is watching (no scroll-to-tail — they
                // are already at the bottom).
                controller.apply(
                    .prepend(page.blocks), scroll: .saveVisible(.visualTop),
                    precomputed: page.precomputed)
            }
        }
        // History tool statuses (failed-history color, etc.) ride on the
        // entries; production routes them to historical derivation.
        onApplied(page.entries)
    }

    private func reportLoaded() {
        guard !didReportLoaded else { return }
        didReportLoaded = true
        // Buffer fully drained + producer finished — the last `.prepend` landed
        // this same tick. Restore the scroller suppressed in `start`.
        controller?.setHistoryBackfilling(false)
        // Fully drained — the first screen is as complete as it will ever be,
        // even if the whole transcript is shorter than the viewport (the
        // "never fills the screen" case the viewport-covered edge can't catch).
        controller?.notifyFirstScreenReady()
        onLoaded()
    }
}

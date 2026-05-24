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

/// The content pipeline (REFACTOR-PLAN §4.5): an off-main task **produces and
/// deposits** pre-built block pages into a **main-owned buffer**; the main
/// thread **drains** them into the controller. No polling, no shared mutable
/// buffer, no lock — the off-main task touches the buffer only inside its main
/// hop, and the drain runs on main too, so the runloop serializes them.
///
/// - The first non-empty deposit is the tail page; it lands at the (empty)
///   tail via `.append`, then scrolls to tail (the attach tick's
///   `scrollToTail` was a no-op against the cold empty table — this is the
///   first content, so it owns the one-time scroll-to-tail).
/// - Every later deposit is older history; it `.prepend`s above with
///   viewport preservation.
/// - When the producer reaches the file top **and** the buffer empties,
///   `onLoaded` fires exactly once.
///
/// Both heavy costs run **off-main** inside the producer: markdown parsing
/// (`MarkdownDocument(parsing:)`) and per-row CTLine typesetting
/// (`Transcript2Coordinator.makeLayout` — `nonisolated static`, §2.5). Each
/// deposited page carries its pre-built `(id, RowLayout)` layouts plus the
/// width they were typeset at; the drain installs them through the single
/// `apply(_:scroll:precomputed:precomputedWidth:)` entry, so the prepend's
/// in-`endUpdates` `heightOfRow` query is a cache **hit**, not a main-thread
/// CTLine pass (REFACTOR-PLAN §4.3 / §5.1). The off-main width comes from
/// `trigger(width:)` (once, after TICK-1 settle) and `retarget(width:)`
/// (at live-resize end); a width mismatch is self-healing (§4.4), never a gate.
@MainActor
final class TranscriptBackfillPipeline {

    private let source: ReversePageSource
    private weak var controller: Transcript2Controller?

    /// Row width future pages typeset at. Seeded by `trigger(width:)` after the
    /// attach tick settles; updated by `retarget(width:)` at live-resize end.
    /// The producer reads this on each page-build hop, so a `retarget` between
    /// pages takes effect on the next page without disturbing in-flight ones.
    private var width: CGFloat = 0

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
    /// RowLayout)` layouts, and the width those layouts were typeset at.
    /// Constructed on the main actor inside `deposit` — only the individual
    /// values cross the producer → main hop (`blocks` / `layouts` are
    /// `@unchecked Sendable`), never a shared mutable buffer (§4.5).
    struct PendingPage {
        let entries: [MessageEntry]
        let blocks: [Block]
        let layouts: [(UUID, RowLayout)]
        let width: CGFloat
    }

    /// Pending pre-built pages, owned by the main actor. Appended only inside
    /// the producer's main hop; consumed only by `drain`.
    private var pendingPages: [PendingPage] = []
    private var producerFinished = false
    private var didFirstApply = false
    private var didReportLoaded = false
    private var drainScheduled = false
    private var task: Task<Void, Never>?

    // MARK: Read-only debug probes (observation only, never gate behavior)

    var onDepositForDebug: ((_ pageBlockCount: Int) -> Void)?
    var onDrainTickForDebug: ((_ appliedBlocks: Int) -> Void)?

    init(
        source: ReversePageSource,
        controller: Transcript2Controller,
        budget: Int = 40,
        onLoaded: @escaping () -> Void = {},
        onApplied: @escaping ([MessageEntry]) -> Void = { _ in }
    ) {
        self.source = source
        self.controller = controller
        self.budget = budget
        self.onLoaded = onLoaded
        self.onApplied = onApplied
    }

    nonisolated deinit {}

    /// Start the off-main producer at `width` (the settled, clamped row width
    /// read from `controller.layoutWidth` after the attach tick settles —
    /// REFACTOR-PLAN §6 TICK 1). The ONE call that seeds the typeset width.
    /// Idempotent — a second call is a no-op. Also subscribes to the
    /// coordinator's `onLayoutWidthDidSettle` so a resize-end retargets future
    /// pages without the host having to wire anything.
    func trigger(width: CGFloat) {
        guard task == nil else { return }
        self.width = width
        controller?.coordinator.onLayoutWidthDidSettle = { [weak self] settled in
            self?.retarget(width: settled)
        }
        let source = self.source
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
                let pageWidth = await self?.width ?? 0
                let layouts = Self.typeset(blocks, width: pageWidth)
                let entries = finalized
                await MainActor.run {
                    self?.deposit(
                        entries: entries, blocks: blocks,
                        layouts: layouts, width: pageWidth)
                }
            }
            // File top: flush the still-open group + true orphans.
            let tail = builder.finish()
            let tailBlocks = MessageEntryBlockBuilder.blocks(from: tail)
            let tailWidth = await self?.width ?? 0
            let tailLayouts = Self.typeset(tailBlocks, width: tailWidth)
            await MainActor.run {
                if !tailBlocks.isEmpty {
                    self?.deposit(
                        entries: tail, blocks: tailBlocks,
                        layouts: tailLayouts, width: tailWidth)
                }
                self?.finishProducing()
            }
        }
    }

    /// Update the width future pages typeset at (REFACTOR-PLAN §4.4). Called
    /// from the coordinator's `onLayoutWidthDidSettle` at live-resize **end**
    /// only — never per-frame during a drag, where intermediate widths are
    /// meaningless. Pure perf: pages already built at the old width self-heal
    /// through the width-keyed cache on `heightOfRow` miss; skipping `retarget`
    /// stays correct, it just wastes one off-main typeset per stale page.
    func retarget(width: CGFloat) {
        self.width = width
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

    /// Stop the producer (e.g. session torn down before load completes).
    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - Deposit (main hop) + drain (main)

    /// Producer main hop: append a pre-built page to the main-owned buffer and
    /// wake the drain. The deposit **is** the wake — main never polls.
    private func deposit(
        entries: [MessageEntry], blocks: [Block],
        layouts: [(UUID, RowLayout)], width: CGFloat
    ) {
        pendingPages.append(
            PendingPage(entries: entries, blocks: blocks, layouts: layouts, width: width))
        onDepositForDebug?(blocks.count)
        scheduleDrain()
    }

    private func finishProducing() {
        producerFinished = true
        // Ensure the terminal state is observed even if the buffer is already
        // empty (e.g. empty history).
        scheduleDrain()
    }

    /// Schedule a drain on the next runloop tick so each drained batch is its
    /// own source phase (the §5 recipe runs per tick). `drainScheduled`
    /// coalesces multiple deposits between ticks into one drain.
    private func scheduleDrain() {
        guard !drainScheduled else { return }
        drainScheduled = true
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    private func drain() {
        drainScheduled = false
        var applied = 0
        while !pendingPages.isEmpty {
            let page = pendingPages.removeFirst()
            applyPage(page)
            applied += page.blocks.count
            // Stop after the batch crosses the cap; a single oversized page
            // still lands whole (it was applied before this check).
            if applied >= budget { break }
        }
        if applied > 0 { onDrainTickForDebug?(applied) }
        if !pendingPages.isEmpty {
            scheduleDrain()
        } else if producerFinished {
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
                precomputed: page.layouts, precomputedWidth: page.width)
        } else {
            // First content: the tail page lands at the (empty) tail. On a COLD
            // open the view-lifecycle `scrollToTail` already ran at the attach
            // tick (TICK 1) against an *empty* table, so it was a no-op — there
            // was nothing to anchor yet. This deposit IS the first content, so
            // the scroll-to-tail belongs here, right after it lands. (Warm
            // re-entry never reaches this branch: `loadHistory` is an idempotent
            // no-op once blocks are already present, so the pipeline never runs.)
            didFirstApply = true
            controller.apply(
                .append(page.blocks),
                precomputed: page.layouts, precomputedWidth: page.width)
            controller.scrollToTail()
        }
        // History tool statuses (failed-history color, etc.) ride on the
        // entries; production routes them to historical derivation.
        onApplied(page.entries)
    }

    private func reportLoaded() {
        guard !didReportLoaded else { return }
        didReportLoaded = true
        onLoaded()
    }
}

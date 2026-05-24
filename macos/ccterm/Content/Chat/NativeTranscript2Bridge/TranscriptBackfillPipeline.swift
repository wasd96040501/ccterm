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
///   tail via `.append` (the view lifecycle owns the one-time scroll-to-tail).
/// - Every later deposit is older history; it `.prepend`s above with
///   viewport preservation.
/// - When the producer reaches the file top **and** the buffer empties,
///   `onLoaded` fires exactly once.
///
/// Markdown parsing (`MarkdownDocument(parsing:)`) — the dominant build cost —
/// runs off-main inside the producer. Per-row CTLine typesetting still lands
/// lazily on the main thread's `heightOfRow`; the off-main typeset + in-tick
/// install is layered on with the §5 anchor recipe.
@MainActor
final class TranscriptBackfillPipeline {

    private let source: ReversePageSource
    private weak var controller: Transcript2Controller?

    /// Loose main-thread per-tick block cap (REFACTOR-PLAN §9.2): a safety
    /// valve, not a typeset budget. A single page exceeding it still lands
    /// whole — the cap bounds a batch, never splits a page (§9.3).
    private let budget: Int

    /// Fires once when the file top is reached and the buffer is drained.
    private let onLoaded: () -> Void

    // MARK: Main-owned buffer + drain bookkeeping

    /// Pending pre-built pages, owned by the main actor. Appended only inside
    /// the producer's main hop; consumed only by `drain`.
    private var pendingPages: [[Block]] = []
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
        onLoaded: @escaping () -> Void = {}
    ) {
        self.source = source
        self.controller = controller
        self.budget = budget
        self.onLoaded = onLoaded
    }

    nonisolated deinit {}

    /// Start the off-main producer. Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
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
                // Markdown parse happens here, off-main.
                let blocks = MessageEntryBlockBuilder.blocks(from: finalized)
                guard !blocks.isEmpty else { continue }
                await MainActor.run { self?.deposit(blocks) }
            }
            // File top: flush the still-open group + true orphans.
            let tail = builder.finish()
            let tailBlocks = MessageEntryBlockBuilder.blocks(from: tail)
            await MainActor.run {
                if !tailBlocks.isEmpty { self?.deposit(tailBlocks) }
                self?.finishProducing()
            }
        }
    }

    /// Stop the producer (e.g. session torn down before load completes).
    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - Deposit (main hop) + drain (main)

    /// Producer main hop: append a pre-built page to the main-owned buffer and
    /// wake the drain. The deposit **is** the wake — main never polls.
    private func deposit(_ blocks: [Block]) {
        pendingPages.append(blocks)
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
            applied += page.count
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

    private func applyPage(_ blocks: [Block]) {
        guard let controller else { return }
        if didFirstApply {
            // Older history: stack above, keep the visible viewport fixed.
            controller.apply(.prepend(blocks), scroll: .saveVisible(.visualTop))
        } else {
            // First content (tail page): land at the empty tail. The one-time
            // scroll-to-tail is the view lifecycle's job, not a change.
            didFirstApply = true
            controller.apply(.append(blocks))
        }
    }

    private func reportLoaded() {
        guard !didReportLoaded else { return }
        didReportLoaded = true
        onLoaded()
    }
}

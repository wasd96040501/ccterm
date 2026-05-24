import AgentSDK
import XCTest

@testable import ccterm

/// Tier-1 Group B (REFACTOR-PLAN §12.1): the async deposit→drain lifecycle,
/// driven through `FakeReversePageSource` so order/timing is controlled, plus
/// the real main-owned buffer + drain. Synchronized with `XCTestExpectation` /
/// `fulfillment` — never `Task.sleep` (suite rule #6).
@MainActor
final class TranscriptBackfillPipelineTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func makeController() -> Transcript2Controller {
        Transcript2Controller()
    }

    /// Run a pipeline to completion (`onLoaded`) and return its controller.
    @discardableResult
    private func runToLoaded(
        pages: [[Message2]],
        budget: Int = 40,
        width: CGFloat = 0,
        configure: (TranscriptBackfillPipeline) -> Void = { _ in },
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Transcript2Controller {
        let controller = makeController()
        let loaded = expectation(description: "loaded")
        let pipeline = TranscriptBackfillPipeline(
            source: FakeReversePageSource(pages),
            controller: controller,
            budget: budget,
            onLoaded: { loaded.fulfill() })
        configure(pipeline)
        pipeline.start(width: width)
        await fulfillment(of: [loaded], timeout: 5)
        return controller
    }

    /// Comparable text token for a block, for order assertions.
    private func blockText(_ block: Block) -> String {
        switch block.kind {
        case .userBubble(let text, _): return text
        case .paragraph(let inlines), .heading(_, let inlines):
            return inlines.map { node in
                if case .text(let s) = node { return s }
                return ""
            }.joined()
        default: return "?"
        }
    }

    private func orderedTexts(_ controller: Transcript2Controller) -> [String] {
        controller.coordinator.blockIds.compactMap { id in
            controller.coordinator.block(forId: id).map(blockText)
        }
    }

    /// A standalone paragraph block, for simulating a live `.append`.
    private func para(_ tag: String) -> Block {
        Block(id: UUID(), kind: .paragraph(inlines: [.text(tag)]))
    }

    // MARK: - B1: cold attach — nothing deposited yet

    func testB1_coldAttachHasNoContentUntilFirstDeposit() async {
        let controller = makeController()
        let pipeline = TranscriptBackfillPipeline(
            source: FakeReversePageSource([[Message2Fixtures.userText("only")]]),
            controller: controller,
            onLoaded: {})
        pipeline.start(width: 0)
        // Synchronous main is still busy — the producer's main hop cannot have
        // landed a deposit yet.
        XCTAssertEqual(controller.blockCount, 0, "cold first tick is empty (§4.5)")
    }

    // MARK: - B2: every reported drain tick did real work (no empty drain)

    func testB2_neverReportsAnEmptyDrainTick() async {
        var drainTicks = 0
        var minAppliedPerTick = Int.max
        var totalApplied = 0
        let controller = await runToLoaded(
            pages: [
                [Message2Fixtures.assistantText("c")],
                [Message2Fixtures.assistantText("b")],
                [Message2Fixtures.assistantText("a")],
            ],
            configure: { pipeline in
                pipeline.onDrainTickForDebug = { applied in
                    drainTicks += 1
                    minAppliedPerTick = min(minAppliedPerTick, applied)
                    totalApplied += applied
                }
            })
        XCTAssertEqual(controller.blockCount, 3)
        XCTAssertEqual(totalApplied, 3, "every block landed across the drain ticks")
        XCTAssertGreaterThan(minAppliedPerTick, 0, "a reported drain tick always applied ≥1 block")
        XCTAssertLessThanOrEqual(drainTicks, 3, "drains coalesce — never more ticks than pages")
    }

    // MARK: - B3: reverse-read pages reassemble into document order

    func testB3_pagesReassembleIntoDocumentOrder() async {
        // tail-first: newest page first.
        let controller = await runToLoaded(pages: [
            [Message2Fixtures.userText("c"), Message2Fixtures.assistantText("d")],
            [Message2Fixtures.userText("a"), Message2Fixtures.assistantText("b")],
        ])
        XCTAssertEqual(
            orderedTexts(controller), ["a", "b", "c", "d"],
            "tail page sits at the bottom; each older page prepends above")
    }

    // MARK: - B4: the budget splits ONLY the cache-miss path

    /// The per-tick cap is a typeset safety valve, not a blanket batch limit
    /// (REFACTOR-PLAN §9.2). It bounds only pages whose precompute width
    /// mismatches the live table (cache miss → synchronous CTLine typeset on
    /// the main thread). Cache hits drain unbudgeted in one tick.
    ///
    /// Headless, the producer typesets at `width: 720` while the unmounted
    /// controller's `layoutWidth` is `0` — every page is a miss, so the cap is
    /// in force and a 12-page buffer drains across multiple budget-capped ticks.
    func testB4_budgetSplitsTheCacheMissPath() async {
        var drainTicks = 0
        var maxAppliedPerTick = 0
        // 12 single-block pages, budget 3, width-mismatch → at least 4 ticks.
        let pages = (0..<12).map { [Message2Fixtures.assistantText("m\($0)")] }
        let controller = await runToLoaded(
            pages: pages,
            budget: 3,
            width: 720,
            configure: { pipeline in
                pipeline.onDrainTickForDebug = { applied in
                    drainTicks += 1
                    maxAppliedPerTick = max(maxAppliedPerTick, applied)
                }
            })
        XCTAssertEqual(controller.blockCount, 12)
        XCTAssertGreaterThan(drainTicks, 1, "miss path drains across multiple self-rescheduled ticks")
        XCTAssertLessThanOrEqual(maxAppliedPerTick, 3, "each miss tick respects the budget cap (1-block pages)")
    }

    // MARK: - B5: file top + empty buffer → .loaded exactly once

    func testB5_loadedFiresExactlyOnce() async {
        var loadedCount = 0
        let controller = makeController()
        let done = expectation(description: "loaded")
        let pipeline = TranscriptBackfillPipeline(
            source: FakeReversePageSource([[Message2Fixtures.assistantText("x")]]),
            controller: controller,
            onLoaded: {
                loadedCount += 1
                done.fulfill()
            })
        pipeline.start(width: 0)
        await fulfillment(of: [done], timeout: 5)
        // Give the runloop a couple of extra turns to surface any stray
        // second drain/finish.
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(loadedCount, 1)
        XCTAssertEqual(controller.blockCount, 1)
    }

    // MARK: - B6: empty history → .loaded immediately, zero content

    func testB6_emptyHistoryLoadsImmediatelyWithNoContent() async {
        let controller = await runToLoaded(pages: [])
        XCTAssertEqual(controller.blockCount, 0, "no content applied, no crash")
    }

    // MARK: - B10: first-screen-ready edge fires exactly once

    /// `onFirstScreenReady` is the fire-once edge a future image-bake reveal
    /// hangs off. Headless there is no viewport to cover, so the viewport-
    /// covered branch never trips; the edge fires via the "fully drained"
    /// fallback (a short transcript that never fills the screen is still
    /// "first-screen complete"). Asserts it fires exactly once even though the
    /// pipeline polls the condition on every drain tick + at `reportLoaded`.
    func testB10_firstScreenReadyFiresExactlyOnce() async {
        var readyCount = 0
        let controller = makeController()
        let loaded = expectation(description: "loaded")
        let pipeline = TranscriptBackfillPipeline(
            source: FakeReversePageSource([
                [Message2Fixtures.assistantText("b")],
                [Message2Fixtures.assistantText("a")],
            ]),
            controller: controller,
            onLoaded: { loaded.fulfill() })
        controller.onFirstScreenReady = { readyCount += 1 }
        pipeline.start(width: 0)
        await fulfillment(of: [loaded], timeout: 5)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(readyCount, 1, "first-screen edge is latched, fires once")
    }

    // MARK: - B8: off-main typeset installs at the start width (§4.3/§5b)

    /// The producer typesets every block off-main at the width passed to
    /// `start`, and the drain installs those layouts through
    /// `apply(precomputed:)`. With no table bound there is no lazy `heightOfRow`
    /// path, so the layout-cache write trace is purely the off-main installs:
    /// every block id written **exactly once**, all at the start width — no
    /// double-typeset, no width drift.
    func testB8_offMainPrecomputeInstallsAtStartWidth() async {
        let startWidth: CGFloat = 720
        var writes: [(id: UUID, width: CGFloat)] = []
        let controller = makeController()
        controller.coordinator.onLayoutCacheWriteForDebug = { id, w in
            writes.append((id, w))
        }
        let loaded = expectation(description: "loaded")
        let pipeline = TranscriptBackfillPipeline(
            source: FakeReversePageSource([
                [Message2Fixtures.userText("c"), Message2Fixtures.assistantText("d")],
                [Message2Fixtures.userText("a"), Message2Fixtures.assistantText("b")],
            ]),
            controller: controller,
            onLoaded: { loaded.fulfill() })
        pipeline.start(width: startWidth)
        await fulfillment(of: [loaded], timeout: 5)

        XCTAssertEqual(controller.blockCount, 4)
        XCTAssertEqual(
            writes.count, controller.blockCount,
            "every block typeset exactly once — off-main install, no lazy re-typeset")
        XCTAssertEqual(Set(writes.map(\.id)).count, writes.count, "no id written twice")
        XCTAssertTrue(
            writes.allSatisfy { $0.width == startWidth },
            "all layouts installed at the start width")
    }

    // MARK: - B9: retarget changes the width future pages typeset at (§4.4/§5b)

    /// `retarget(width:)` between pages takes effect on the next page the
    /// producer builds (it reads the pipeline width per page). The earlier page
    /// stays at the original width; later pages land at the retargeted width.
    /// Each id is still typeset exactly once — the single-width-per-id contract
    /// holds across a retarget.
    func testB9_retargetChangesFuturePageWidth() async {
        let firstWidth: CGFloat = 720
        let retargetWidth: CGFloat = 500
        var writes: [(id: UUID, width: CGFloat)] = []
        let controller = makeController()
        controller.coordinator.onLayoutCacheWriteForDebug = { id, w in
            writes.append((id, w))
        }
        let loaded = expectation(description: "loaded")
        let source = FakeReversePageSource([
            [Message2Fixtures.assistantText("tail")],
            [Message2Fixtures.assistantText("older")],
        ])
        let pipeline = TranscriptBackfillPipeline(
            source: source,
            controller: controller,
            onLoaded: { loaded.fulfill() })
        // Simulate a resize-end (the production `onLayoutWidthDidSettle` hook)
        // landing right before the second page is produced.
        source.onBeforePage = { [weak pipeline] index in
            guard index == 1 else { return }
            await MainActor.run { pipeline?.retarget(width: retargetWidth) }
        }
        pipeline.start(width: firstWidth)
        await fulfillment(of: [loaded], timeout: 5)

        XCTAssertEqual(controller.blockCount, 2)
        XCTAssertEqual(Set(writes.map(\.id)).count, writes.count, "no id written twice")
        XCTAssertEqual(
            writes.filter { $0.width == firstWidth }.count, 1,
            "the tail page built before retarget stays at the original width")
        XCTAssertEqual(
            writes.filter { $0.width == retargetWidth }.count, 1,
            "the page built after retarget lands at the new width")
    }

    // MARK: - B7: many interleaved deposits — no lost/dup/reordered page

    func testB7_manyPagesNoLossOrReorder() async {
        // 6 pages, tail-first; each older page should stack above.
        let pages: [[Message2]] = (0..<6).reversed().map {
            [Message2Fixtures.assistantText("p\($0)")]
        }
        // pages[0] = p5 (newest) ... pages[5] = p0 (oldest)
        let controller = await runToLoaded(pages: pages, budget: 2)
        XCTAssertEqual(
            orderedTexts(controller), ["p0", "p1", "p2", "p3", "p4", "p5"],
            "document order preserved across interleaved deposits/drains")
        XCTAssertEqual(controller.blockCount, 6)
    }

    // MARK: - B10: live content before the first deposit lands above it (§7)

    /// A live `.append` can race ahead of the pipeline's first deposit — the
    /// user sends a message within the cold gap between attach and the first
    /// tail page landing. That live content is the *newest*, so the tail
    /// history page is older and must prepend ABOVE it, not append below.
    /// Guards the `applyPage` first-content ordering branch: an empty table
    /// appends + scrolls to tail, a non-empty one prepends.
    func testB10_liveContentBeforeFirstDepositLandsAboveIt() async {
        let controller = makeController()
        let loaded = expectation(description: "loaded")
        let pipeline = TranscriptBackfillPipeline(
            source: FakeReversePageSource([
                [Message2Fixtures.userText("c"), Message2Fixtures.assistantText("d")],
                [Message2Fixtures.userText("a"), Message2Fixtures.assistantText("b")],
            ]),
            controller: controller,
            onLoaded: { loaded.fulfill() })

        // Simulate the instant send: a live block lands in the controller
        // BEFORE start() lets the producer deposit its first page.
        controller.apply(.append([para("live")]))
        XCTAssertEqual(controller.blockCount, 1, "live content present before backfill")

        pipeline.start(width: 0)
        await fulfillment(of: [loaded], timeout: 5)

        // History (document order a,b,c,d) sits ABOVE the live message, which
        // stays pinned at the bottom.
        XCTAssertEqual(
            orderedTexts(controller), ["a", "b", "c", "d", "live"],
            "tail history prepends above live content that arrived first (§7)")
    }
}

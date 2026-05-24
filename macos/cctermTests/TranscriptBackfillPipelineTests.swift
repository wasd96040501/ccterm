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
        pipeline.start()
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

    // MARK: - B1: cold attach — nothing deposited yet

    func testB1_coldAttachHasNoContentUntilFirstDeposit() async {
        let controller = makeController()
        let pipeline = TranscriptBackfillPipeline(
            source: FakeReversePageSource([[Message2Fixtures.userText("only")]]),
            controller: controller,
            onLoaded: {})
        pipeline.start()
        // Synchronous main is still busy — the producer's main hop cannot have
        // landed a deposit yet.
        XCTAssertEqual(controller.blockCount, 0, "cold first tick is empty (§4.5)")
    }

    // MARK: - B2: drain only fires after a deposit (the deposit IS the wake)

    func testB2_neverDrainsAnEmptyBuffer() async {
        var deposits = 0
        var drainTicks = 0
        var minAppliedPerTick = Int.max
        let controller = await runToLoaded(
            pages: [
                [Message2Fixtures.assistantText("c")],
                [Message2Fixtures.assistantText("b")],
                [Message2Fixtures.assistantText("a")],
            ],
            configure: { pipeline in
                pipeline.onDepositForDebug = { _ in deposits += 1 }
                pipeline.onDrainTickForDebug = { applied in
                    drainTicks += 1
                    minAppliedPerTick = min(minAppliedPerTick, applied)
                }
            })
        XCTAssertEqual(deposits, 3)
        XCTAssertLessThanOrEqual(drainTicks, deposits, "drain invocations never exceed deposits")
        XCTAssertGreaterThan(minAppliedPerTick, 0, "no drain tick ever runs on an empty buffer")
        XCTAssertEqual(controller.blockCount, 3)
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

    // MARK: - B4: a large buffer drains over multiple budget-capped ticks

    func testB4_largeBufferDrainsOverMultipleTicks() async {
        var drainTicks = 0
        var maxAppliedPerTick = 0
        // 12 single-block pages, budget 3 → at least 4 ticks.
        let pages = (0..<12).map { [Message2Fixtures.assistantText("m\($0)")] }
        let controller = await runToLoaded(
            pages: pages,
            budget: 3,
            configure: { pipeline in
                pipeline.onDrainTickForDebug = { applied in
                    drainTicks += 1
                    maxAppliedPerTick = max(maxAppliedPerTick, applied)
                }
            })
        XCTAssertEqual(controller.blockCount, 12)
        XCTAssertGreaterThan(drainTicks, 1, "buffer drained across multiple self-rescheduled ticks")
        XCTAssertLessThanOrEqual(maxAppliedPerTick, 3, "each tick respects the budget cap (1-block pages)")
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
        pipeline.start()
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
}

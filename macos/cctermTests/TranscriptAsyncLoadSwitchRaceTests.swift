import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Acceptance gate (deferred-from-#224): switching sessions while a history
/// load is in flight must not desync the transcript.
///
/// ## What the old code got wrong, and why this is the gate for the fix
///
/// The pre-refactor `Transcript2Controller.setHistory` split a large history
/// into a sync Phase 1 (viewport batch) and an async Phase 2 whose main-hop
/// guarded on the live table:
///
/// ```
/// await MainActor.run {
///     guard let self, let table = self.tableView else { return }  // ← drops the batch
///     ... blocks.insert(...) ; table.insertRows(...) ...
/// }
/// ```
///
/// If the user switched away before Phase 2 landed, `dismantle` had nilled
/// `coordinator.tableView`, so the landing returned **without inserting the
/// Phase-2 blocks into `coordinator.blocks`** — they were silently lost.
/// `blocks.count` no longer matched the row count a rebuilt table tiled to, so
/// every `block.id → row` consumer (selection-highlight, search) pointed at the
/// wrong rows. The only thing that "fixed" it was a full re-attach.
///
/// ## What the merged refactor changed (the property under test)
///
/// `setHistory` + the two-phase apply are gone. History now loads through the
/// reverse-streaming `TranscriptBackfillPipeline`: an off-main producer builds
/// pre-typeset pages, and the main thread drains them through the single
/// `Transcript2Controller.apply` entry — the tail page as `.append`, every
/// older page as `.prepend`. Crucially, `apply` mutates `coordinator.blocks`
/// **regardless of whether a table is bound** (the headless drain in
/// `TranscriptBackfillPipelineTests` is the same path with no table at all). So
/// a mid-load table teardown can no longer truncate `blocks`.
///
/// This test pins that guarantee end-to-end: drive a real pipeline, land the
/// tail page with the table bound, tear the table down before the older
/// `.prepend` pages drain (the switch-away), let the rest land while detached,
/// then re-attach (the switch-back). `blocks` — and the rebuilt table's row
/// count — must survive intact.
@MainActor
final class TranscriptAsyncLoadSwitchRaceTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let pageCount = 6
    private static let perPage = 5
    private static var totalBlocks: Int { pageCount * perPage }

    /// Tail-first list of document-order message slices, one block per message.
    /// Each message carries a unique id so no two collapse into one entry.
    private func makePages() -> [[Message2]] {
        (0..<Self.pageCount).map { p in
            (0..<Self.perPage).map { i in
                Message2Fixtures.assistantText(
                    "page \(p) line \(i): the rain in spain falls mainly on the plain",
                    messageId: "m-\(p)-\(i)")
            }
        }
    }

    /// Mounts a bound table, drives a real backfill pipeline, tears the table
    /// down after the tail page lands but before the older pages drain (the
    /// switch-away), then re-attaches. The full history must survive in
    /// `coordinator.blocks` and the re-attached table must tile to it.
    func testHistorySurvivesTableTeardownMidBackfill() async throws {
        let controller = Transcript2Controller()

        // Mount + bind a real table, running the production attach order.
        let mounted = MountedTranscript.mount(controller: controller)
        addTeardownBlock {
            mounted.window.contentView = nil
            mounted.window.close()
        }
        XCTAssertNotNil(
            controller.coordinator.tableView, "fixture broke: table not bound after mount")

        // Gate the producer just before the FIRST older page (index 1): the
        // tail page (index 0) lands while the table is still bound, and every
        // older `.prepend` page is held until we've switched away.
        let gate = BackfillGate()
        let source = FakeReversePageSource(makePages())
        source.onBeforePage = { idx in
            if idx == 1 { await gate.wait() }
        }

        let tailApplied = expectation(description: "tail page applied")
        tailApplied.assertForOverFulfill = false
        let loaded = expectation(description: "backfill loaded")
        let pipeline = TranscriptBackfillPipeline(
            source: source,
            controller: controller,
            onLoaded: { loaded.fulfill() },
            onApplied: { _ in tailApplied.fulfill() })

        // Kick the backfill at the settled width production reads after attach.
        pipeline.start(width: controller.layoutWidth)

        // Tail page lands first (`.append`) with the table still bound. Only
        // that page is in `blocks` — the rest is gated behind the producer park.
        await fulfillment(of: [tailApplied], timeout: 5)
        XCTAssertEqual(
            controller.blockCount, Self.perPage,
            "only the tail page should have landed before the gate opens "
                + "(blockCount=\(controller.blockCount))")
        XCTAssertNotNil(controller.coordinator.tableView, "table should still be bound here")

        // SWITCH AWAY mid-load: tear the bound table down, exactly the state a
        // sidebar switch (`attachSession` → `dismantle`) leaves while the
        // detached producer is still building older pages.
        TranscriptScrollViewFactory.dismantle(mounted.scroll, controller: controller)
        XCTAssertNil(controller.coordinator.tableView)

        // Drain the rest WITHOUT a table — every older page `.prepend`s into
        // `coordinator.blocks` through the table-independent apply path.
        await gate.open()
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertEqual(
            controller.blockCount, Self.totalBlocks,
            "Phase-equivalent blocks were dropped when the table was torn down "
                + "mid-backfill: blockCount=\(controller.blockCount), "
                + "expected=\(Self.totalBlocks). This is the desync that breaks "
                + "selection-highlight / search row mapping until a full re-attach.")

        // SWITCH BACK: production rebuilds the scroll view on every swap. The
        // rebuilt table tiles off `blocks.count`; a truncated `blocks` would
        // tile short and the `block.id → row` mapping would be off.
        let reattached = MountedTranscript.mount(controller: controller)
        addTeardownBlock {
            reattached.window.contentView = nil
            reattached.window.close()
        }
        XCTAssertEqual(
            reattached.table.numberOfRows, Self.totalBlocks,
            "Re-attached table tiled to \(reattached.table.numberOfRows) rows, expected "
                + "\(Self.totalBlocks) — a truncated `blocks` tiles short here.")
        XCTAssertEqual(
            reattached.table.numberOfRows, controller.blockCount,
            "Re-attached table row count must equal blocks.count, or the "
                + "block.id → row mapping selection-highlight relies on is off "
                + "(numberOfRows=\(reattached.table.numberOfRows), "
                + "blocks=\(controller.blockCount)).")
    }
}

/// One-shot async gate: the off-main backfill producer parks on `wait()` until
/// the test calls `open()`. An actor so the producer task and the `@MainActor`
/// test can touch it without a data race. Records `open` so a producer that
/// reaches `wait()` *after* `open()` proceeds immediately (no lost wakeup).
private actor BackfillGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resume = waiters
        waiters.removeAll()
        resume.forEach { $0.resume() }
    }
}

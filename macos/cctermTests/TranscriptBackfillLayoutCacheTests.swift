import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Tier-2 probe **U1**: the single-width typeset contract
/// extended across the multi-tick backfill sequence. `TranscriptReentryLayoutCacheTests`
/// stops at re-entry (blocks already present); this drives a real
/// `TranscriptBackfillPipeline` cold — tail page `.append`, then several
/// `.prepend` ticks — on a mounted offscreen table, and asserts:
///
///   1. Every block id is typeset at **exactly one width** (the settled table
///      width) — no id straddles two widths inside the backfill.
///   2. The total write count equals the block count: each block typeset
///      **exactly once**. This is what 5b's off-main precompute buys — the
///      prepend ticks install precomputed layouts at the table width, so the
///      synchronous `heightOfRow` query inside `insertRows`' `endUpdates` is a
///      cache **hit**, not an on-main CTLine re-typeset. A 5b regression that
///      seeds the producer at a width different from the table's render width
///      would show up here as a miss → a second write at a second width,
///      failing both (1) and (2).
///
/// No `Snapshot` filename suffix — runs on the default `make test-unit` (CI
/// merge gate).
@MainActor
final class TranscriptBackfillLayoutCacheTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testU1_backfillTypesetsEachBlockAtExactlyOneWidth() async throws {
        let controller = Transcript2Controller()
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }

        // Cold: nothing loaded yet — TICK 1 is empty (§4.5).
        XCTAssertEqual(controller.blockCount, 0, "cold attach renders no content")

        // Install the probe AFTER the (empty) mount so it captures only the
        // backfill writes.
        var writes: [(id: UUID, width: CGFloat)] = []
        controller.coordinator.onLayoutCacheWriteForDebug = { id, w in
            writes.append((id, w))
        }
        defer { controller.coordinator.onLayoutCacheWriteForDebug = nil }

        // 12 single-message pages, tail-first. Producer width == table width,
        // so every page is a cache hit and drains unbudgeted (`budget: 2` only
        // gates the miss path now — see TranscriptBackfillPipelineTests.B4);
        // the single-width contract below holds regardless of tick count.
        let pages: [[Message2]] = (0..<12).reversed().map {
            [
                Message2Fixtures.assistantText(
                    "message \($0): the rain in spain falls mainly on the plain, "
                        + "and the quick brown fox jumps over the lazy dog.")
            ]
        }
        let loaded = expectation(description: "loaded")
        let pipeline = TranscriptBackfillPipeline(
            source: FakeReversePageSource(pages),
            controller: controller,
            budget: 2,
            onLoaded: { loaded.fulfill() })
        pipeline.start(width: controller.layoutWidth)
        await fulfillment(of: [loaded], timeout: 5)
        mounted.drain()

        let blockCount = controller.blockCount
        XCTAssertGreaterThanOrEqual(
            blockCount, 12, "fixture broke — expected ≥12 backfilled blocks")

        let settledWidth = controller.layoutWidth
        let widthsPerId = Dictionary(grouping: writes, by: \.id)
            .mapValues { Set($0.map(\.width)) }
        let offenders = widthsPerId.filter { $0.value.count > 1 }
        let distinctWidths = Set(writes.map(\.width)).sorted()

        let report = """
            backfill layoutCache write trace
            ────────────────────────────────────────────────────────────
            block count      = \(blockCount)
            total writes     = \(writes.count)
            unique ids       = \(widthsPerId.count)
            settled width    = \(settledWidth)
            distinct widths  = \(distinctWidths)
            multi-width ids  = \(offenders.count)
            """
        let attachment = XCTAttachment(string: report)
        attachment.name = "backfill-cache-writes"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(
            offenders.isEmpty,
            "backfill typeset \(offenders.count) block(s) at multiple widths. "
                + "distinctWidths=\(distinctWidths)")
        XCTAssertEqual(
            Set(writes.map(\.id)).count, blockCount,
            "every backfilled block typeset exactly once")
        XCTAssertEqual(
            writes.count, blockCount,
            "no block re-typeset on main — prepend ticks were cache hits (5b)")
        XCTAssertEqual(
            distinctWidths, [settledWidth],
            "all typeset at the settled table width — off-main width matched")
    }
}

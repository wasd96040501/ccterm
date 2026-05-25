import AppKit
import XCTest

@testable import ccterm

/// Tier-2 probes for the **detached layout warm**: a non-active session whose
/// `Transcript2Controller` has no bound table still pre-fills its layout cache
/// off-main as the bridge streams blocks in, so re-entry is a cache hit rather
/// than an O(streamed-rows) main-thread typeset during the attach tile.
///
/// Driven entirely through production surface — `controller.apply` (the bridge's
/// detached path), the resident `mainThreadLayoutComputes` counter (the same
/// telemetry the host logs per attach), the read-only `onLayoutCacheWriteForDebug`
/// probe, and a real `SyntaxHighlightEngine`. No test-only hooks.
///
/// No `Snapshot` suffix — CI merge gate.
@MainActor
final class TranscriptDetachedWarmTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Paragraphs of varied length so row heights differ (a real transcript,
    /// not uniform rows) — makes a recompute actually cost CTLine work.
    private func makeParagraphs(count: Int, prefix: String) -> [Block] {
        (0..<count).map { i in
            let filler = String(repeating: "the quick brown fox. ", count: (i % 4) + 1)
            return Block(
                id: UUID(),
                kind: .paragraph(inlines: [.text("\(prefix) \(i): \(filler)")]))
        }
    }

    // MARK: - Core: detached insert warms → re-entry recomputes nothing

    /// The headline benefit. A session is shown once (records its display
    /// width), switched away from, then streamed N more blocks while detached.
    /// The off-main warm must have typeset every streamed block at the display
    /// width, so re-attaching it recomputes **zero** rows on the main thread.
    func testDetachedInsertWarmsCacheSoReentryRecomputesNothing() async throws {
        let controller = Transcript2Controller()
        controller.apply(.append(makeParagraphs(count: 8, prefix: "seed")))

        // First mount records the display width (lastLayoutWidth) and warms
        // the seed cache through the attach tile; then detach.
        let first = MountedTranscript.mount(controller: controller)
        first.drain()
        let width = controller.layoutWidth
        XCTAssertGreaterThan(width, 0, "first mount settled a real display width")
        XCTAssertEqual(
            controller.coordinator.displayWidthForDebug, width,
            "attach records the settled width so the detached warm has one to use")
        first.teardown()  // detach: tableView nil, coordinator + layoutCache persist

        // Stream blocks into the now-detached session (the bridge keeps
        // applying while the user views another session). Expect the off-main
        // warm to write every new id at the last-displayed width.
        let streamed = makeParagraphs(count: 12, prefix: "streamed")
        let newIds = Set(streamed.map(\.id))
        var warmedAtWidth: [UUID: CGFloat] = [:]
        let warmed = expectation(description: "all streamed ids warmed off-main")
        controller.coordinator.onLayoutCacheWriteForDebug = { id, w in
            guard newIds.contains(id) else { return }
            warmedAtWidth[id] = w
            if Set(warmedAtWidth.keys) == newIds { warmed.fulfill() }
        }

        controller.apply(.append(streamed))  // detached → schedules the warm
        await fulfillment(of: [warmed], timeout: 5)
        controller.coordinator.onLayoutCacheWriteForDebug = nil

        // Warm typeset at the display width, not a stale / zero width.
        for id in newIds {
            XCTAssertEqual(
                warmedAtWidth[id], width,
                "streamed block warmed at the last-displayed width")
        }

        // Re-attach: the attach tile must be all cache hits — zero main-thread
        // typeset (the whole point — a long-detached session re-enters cheaply).
        let computesBefore = controller.mainThreadLayoutComputes
        let second = MountedTranscript.mount(controller: controller)
        defer { second.teardown() }
        second.drain()
        let recomputed = controller.mainThreadLayoutComputes - computesBefore

        XCTAssertEqual(controller.blockCount, 20, "seed + streamed all present")
        XCTAssertEqual(
            recomputed, 0,
            "warm re-entry typeset \(recomputed) row(s) on the main thread; the "
                + "detached warm should have made every block a cache hit")
    }

    // MARK: - Width contract: warm is width-tagged and self-heals

    /// The warm typesets at the last-displayed width. If the window is a
    /// different width on re-entry, those entries are misses that lazily
    /// recompute — a self-heal (§4.4), never a corruption. Proves the warm
    /// width is an honest cache tag, not a guard.
    func testDetachedWarmAtOldWidthSelfHealsWhenReentryWidthDiffers() async throws {
        let controller = Transcript2Controller()
        let seed = makeParagraphs(count: 6, prefix: "seed")
        controller.apply(.append(seed))

        let first = MountedTranscript.mount(
            controller: controller, size: CGSize(width: 720, height: 800))
        first.drain()
        XCTAssertEqual(controller.layoutWidth, 720)
        first.teardown()

        let streamed = makeParagraphs(count: 10, prefix: "streamed")
        let newIds = Set(streamed.map(\.id))
        let warmed = expectation(description: "streamed ids warmed at 720")
        var warmedIds = Set<UUID>()
        controller.coordinator.onLayoutCacheWriteForDebug = { id, w in
            guard newIds.contains(id), w == 720 else { return }
            warmedIds.insert(id)
            if warmedIds == newIds { warmed.fulfill() }
        }
        controller.apply(.append(streamed))
        await fulfillment(of: [warmed], timeout: 5)
        controller.coordinator.onLayoutCacheWriteForDebug = nil

        // Re-attach at a narrower width (still inside the [460,780] clamp band).
        // Every block was warmed at 720, so the 520-wide tile misses and
        // recomputes — observable, and correct (no stale-width layout is used).
        let computesBefore = controller.mainThreadLayoutComputes
        let second = MountedTranscript.mount(
            controller: controller, size: CGSize(width: 520, height: 800))
        defer { second.teardown() }
        second.drain()
        let recomputed = controller.mainThreadLayoutComputes - computesBefore

        XCTAssertEqual(second.controller.layoutWidth, 520, "re-mounted at a new width")
        XCTAssertGreaterThanOrEqual(
            recomputed, streamed.count,
            "warmed-at-720 entries are misses at 520 and recompute (self-heal), "
                + "not silently reused at the wrong width")
    }

    // MARK: - Highlight re-fill keeps the cache warm + coloured, not a hole

    /// The user's design point: a detached code block is insert-warmed plain
    /// (tokens haven't arrived yet), and when async highlight tokens land the
    /// fill path **re-warms off-main** instead of evicting. So the cache holds
    /// a coloured layout — re-entry is a hit, not a recompute of the hole that
    /// a bare evict-on-fill would leave.
    func testDetachedHighlightFillRewarmsInsteadOfLeavingAHole() async throws {
        let engine = SyntaxHighlightEngine()
        await engine.load()
        let controller = Transcript2Controller(syntaxEngine: engine)
        controller.apply(.append(makeParagraphs(count: 4, prefix: "seed")))

        let first = MountedTranscript.mount(controller: controller)
        first.drain()
        XCTAssertGreaterThan(controller.layoutWidth, 0)
        first.teardown()  // detach

        // Stream a code block into the detached session. Two cache writes must
        // land for it: the plain insert-warm, then the coloured fill re-warm
        // once tokens arrive. (A bare evict-on-fill would produce only the
        // first write, then drop it — leaving a re-entry miss.)
        let codeId = UUID()
        let code = Block(
            id: codeId,
            kind: .codeBlock(
                language: "swift",
                code: "func greet(_ name: String) -> String {\n"
                    + "    return \"hello, \\(name)\"\n}\n"))
        var codeWrites = 0
        let rewarmed = expectation(description: "code block written twice (plain, then coloured)")
        controller.coordinator.onLayoutCacheWriteForDebug = { id, _ in
            guard id == codeId else { return }
            codeWrites += 1
            if codeWrites >= 2 { rewarmed.fulfill() }
        }

        controller.apply(.append([code]))  // detached → insert-warm + async highlight
        await fulfillment(of: [rewarmed], timeout: 10)
        controller.coordinator.onLayoutCacheWriteForDebug = nil

        // The fill actually produced tokens (so the re-warm built a coloured
        // layout, not another plain one).
        XCTAssertNotNil(
            controller.coordinator.highlightStorage.tokens(blockId: codeId, scope: .codeBlock),
            "syntax tokens landed for the code block")

        // Re-attach: the code block is a warm hit (the re-warm filled it), so
        // the tile recomputes nothing.
        let computesBefore = controller.mainThreadLayoutComputes
        let second = MountedTranscript.mount(controller: controller)
        defer { second.teardown() }
        second.drain()
        let recomputed = controller.mainThreadLayoutComputes - computesBefore

        XCTAssertEqual(
            recomputed, 0,
            "re-entry recomputed \(recomputed) row(s); the detached fill should "
                + "have re-warmed the code block coloured, leaving no hole")
    }
}

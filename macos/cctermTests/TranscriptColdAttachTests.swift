import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Tier-2 cold/warm attach probes (REFACTOR-PLAN §12.2), measured on a mounted
/// offscreen table.
///
/// - **U4** cold-empty first tick — a never-loaded session renders
///   `numberOfRows == 0` at attach (no spinner / placeholder); the first
///   deposit then lands the tail content at the bottom of the document.
/// - **U5** block↔row alignment invariant — after **every** change in a mixed
///   `prepend`/`append`/`replace`/`remove`/`update` sequence,
///   `coordinator.blocks.count == tableView.numberOfRows`, index-for-index.
/// - **U6** warm re-entry — a populated, already-`.loaded` session re-attaches
///   with **zero** backfill: `loadHistory` short-circuits, so the layout-cache
///   write probe sees no new typeset after the mount settles.
///
/// No `Snapshot` suffix — CI merge gate.
@MainActor
final class TranscriptColdAttachTests: XCTestCase {

    private var tempFile: TempJSONLFile?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        tempFile?.remove()
        tempFile = nil
    }

    private func blockText(_ controller: Transcript2Controller, _ id: UUID) -> String {
        switch controller.coordinator.block(forId: id)?.kind {
        case .userBubble(let text, _): return text
        case .paragraph(let inlines), .heading(_, let inlines):
            return inlines.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
                .joined()
        default: return "?"
        }
    }

    // MARK: - U4: cold attach is empty, then the tail lands at the bottom

    func testU4_coldAttachEmptyThenTailContentAtBottom() async throws {
        let controller = Transcript2Controller()
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }

        // TICK 1 — cold, nothing loaded: blank surface, no rows.
        XCTAssertEqual(mounted.table.numberOfRows, 0, "cold attach renders 0 rows")
        XCTAssertEqual(controller.blockCount, 0)

        // Pages tail-first: pages[0] is the newest content.
        let loaded = expectation(description: "loaded")
        let pipeline = TranscriptBackfillPipeline(
            source: FakeReversePageSource([
                [Message2Fixtures.assistantText("newest")],
                [Message2Fixtures.assistantText("middle")],
                [Message2Fixtures.assistantText("oldest")],
            ]),
            controller: controller,
            budget: 1,
            onLoaded: { loaded.fulfill() })
        pipeline.start(width: controller.layoutWidth)
        await fulfillment(of: [loaded], timeout: 5)
        mounted.drain()

        // Content appeared; rows match blocks; newest sits at the bottom of
        // the document (older pages prepended above the tail page).
        XCTAssertEqual(controller.blockCount, 3)
        XCTAssertEqual(mounted.table.numberOfRows, 3)
        let ids = controller.blockIds
        XCTAssertEqual(blockText(controller, ids.first!), "oldest", "oldest at the top")
        XCTAssertEqual(blockText(controller, ids.last!), "newest", "tail content at the bottom")
    }

    // MARK: - U4b: cold first screen scrolls to the tail (viewport-exceeding)

    /// Regression for the cold-open landing bug: when the tail page is taller
    /// than the viewport, the first content must land the **newest** row at the
    /// viewport's visible bottom — not pinned to the top with `clip.origin.y ==
    /// 0`. The attach-tick `scrollToTail` is a no-op against the cold empty
    /// table, so the scroll-to-tail belongs to the first deposit
    /// (`TranscriptBackfillPipeline.applyPage`). U4 above uses 3 short rows that
    /// fit the viewport, where top and bottom landings are indistinguishable;
    /// this probe forces a tail page that overflows so the scroll position is
    /// observable.
    func testU4b_coldFirstScreenScrollsToTailWhenTailPageOverflowsViewport() async throws {
        let controller = Transcript2Controller()
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }

        XCTAssertEqual(mounted.table.numberOfRows, 0, "cold attach renders 0 rows")

        // Tail page (pages[0], newest) alone overflows the 800pt viewport;
        // a couple of older pages prepend above it.
        let tailPage = (0..<40).map { Message2Fixtures.assistantText("newest line \($0)") }
        let loaded = expectation(description: "loaded")
        let pipeline = TranscriptBackfillPipeline(
            source: FakeReversePageSource([
                tailPage,
                [Message2Fixtures.assistantText("older")],
                [Message2Fixtures.assistantText("oldest")],
            ]),
            controller: controller,
            budget: 1,
            onLoaded: { loaded.fulfill() })
        pipeline.start(width: controller.layoutWidth)
        await fulfillment(of: [loaded], timeout: 5)
        mounted.drain()

        XCTAssertEqual(mounted.table.numberOfRows, 42)

        // The fixture must overflow the viewport, else scroll-to-tail is a
        // trivial no-op and the test proves nothing.
        XCTAssertGreaterThan(
            mounted.table.frame.height, mounted.clip.bounds.height,
            "tail page must overflow the viewport for the scroll to be observable")

        // The newest row is on screen (the regression parks it far below the
        // fold, off-screen) and its bottom edge sits at the viewport's visible
        // bottom — i.e. content scrolled down to the tail, not stuck at top.
        let lastRow = mounted.table.numberOfRows - 1
        let visible = mounted.table.rows(in: mounted.table.visibleRect)
        XCTAssertTrue(
            NSLocationInRange(lastRow, visible),
            "newest row is visible after the cold first screen, not off-screen below")
        XCTAssertGreaterThan(
            mounted.clip.bounds.origin.y, 0,
            "document scrolled down to the tail (regression leaves it at the top)")
        let visibleBottom =
            mounted.clip.bounds.origin.y + mounted.clip.bounds.height
            - mounted.scroll.contentInsets.bottom
        XCTAssertEqual(
            mounted.table.rect(ofRow: lastRow).maxY, visibleBottom, accuracy: 2,
            "newest row's bottom edge lands at the viewport's visible bottom")
    }

    // MARK: - U5: blocks.count == numberOfRows after every change

    func testU5_blockRowAlignmentAcrossMixedSequence() throws {
        let controller = Transcript2Controller()
        let seed = (0..<10).map {
            Block(id: UUID(), kind: .paragraph(inlines: [.text("seed \($0)")]))
        }
        controller.apply(.append(seed))
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }
        mounted.drain()

        func assertAligned(_ label: String) {
            XCTAssertEqual(
                controller.blockCount, mounted.table.numberOfRows,
                "\(label): blocks.count (\(controller.blockCount)) != "
                    + "numberOfRows (\(mounted.table.numberOfRows))")
        }
        assertAligned("seed")

        controller.apply(
            .prepend([Block(id: UUID(), kind: .paragraph(inlines: [.text("p0")]))]),
            scroll: .saveVisible(.visualTop))
        assertAligned("after prepend")

        let appended = Block(id: UUID(), kind: .paragraph(inlines: [.text("a0")]))
        controller.apply(.append([appended]))
        assertAligned("after append")

        controller.apply(
            .update(id: seed[3].id, kind: .paragraph(inlines: [.text("seed 3 rewritten")])))
        assertAligned("after update")

        controller.apply(
            .replace(
                oldIds: [seed[5].id, seed[6].id],
                with: [Block(id: UUID(), kind: .paragraph(inlines: [.text("swap")]))]))
        assertAligned("after replace")

        controller.apply(.remove(ids: [seed[8].id, appended.id]))
        assertAligned("after remove")
    }

    // MARK: - U6: warm re-entry fires no backfill

    func testU6_warmReentryFiresNoBackfill() async throws {
        let file = try TempJSONLFile([
            Message2Fixtures.assistantTextJSONL("warm one"),
            Message2Fixtures.userTextJSONL("warm two"),
        ])
        tempFile = file

        // Cold-load a session to completion so it is `.loaded` and populated.
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString, repository: InMemorySessionRepository())
        let session = ccterm.Session(runtime: runtime, cliClientFactory: { _ in FakeCLIClient() })
        session.loadHistory(overrideURL: file.url)
        let loadedPredicate = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in session.historyLoadState == .loaded },
            object: nil)
        await fulfillment(of: [loadedPredicate], timeout: 5)
        let warmCount = session.controller.blockCount
        XCTAssertGreaterThan(warmCount, 0, "session populated before re-entry")

        // Re-attach: mount the existing controller (warm — blocks already
        // present). Install the probe AFTER the mount settles so it captures
        // only what a re-entry produces.
        let mounted = MountedTranscript.mount(controller: session.controller)
        defer { mounted.teardown() }
        mounted.drain()

        var backfillWrites = 0
        session.controller.coordinator.onLayoutCacheWriteForDebug = { _, _ in
            backfillWrites += 1
        }
        defer { session.controller.coordinator.onLayoutCacheWriteForDebug = nil }

        // Re-entry's history load — idempotent no-op on a `.loaded` session.
        session.loadHistory(overrideURL: file.url)
        mounted.drain(seconds: 0.15)

        XCTAssertEqual(
            session.controller.blockCount, warmCount,
            "warm re-entry adds no blocks")
        XCTAssertEqual(
            backfillWrites, 0,
            "warm re-entry fires no backfill typeset — loadHistory short-circuits")
    }
}

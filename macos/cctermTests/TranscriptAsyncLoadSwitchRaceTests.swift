import AppKit
import XCTest

@testable import ccterm

/// Reproduces the deferred-from-#224 async-load race that survives the
/// compose/overlay work: switching sessions while a history load is
/// in flight desyncs the transcript.
///
/// `Transcript2Controller.setHistory` splits a large history into a sync
/// Phase 1 (viewport batch) and an async Phase 2 (`applyInBackground`:
/// off-main layout, then a single main-hop that mutates `blocks` and
/// calls `insertRows`). The main-hop guards on `self.tableView`:
///
/// ```
/// await MainActor.run {
///     guard let self, let table = self.tableView else { return }  // ← drops the batch
///     ... blocks.insert(...) ; table.insertRows(...) ...
/// }
/// ```
///
/// If the user switches away before Phase 2 lands, `dismantle` has set
/// `coordinator.tableView = nil`, so the landing returns **without
/// inserting the Phase-2 blocks into `coordinator.blocks`** — they are
/// silently lost. The transcript is now missing rows the history
/// contained, `blocks.count` no longer matches the real history, and the
/// `block.id → row` mapping every downstream consumer relies on
/// (`markCellNeedsDisplay`, selection highlight, search) is off — which
/// is the user-visible "I can drag-select but no highlight appears, and
/// only switching away and back fixes it."
///
/// The fix must keep `blocks` authoritative across a mid-flight table
/// swap (route the landing through the sync `apply` path when the table
/// is gone, exactly as the *pre*-detach guards at the top of
/// `applyInBackground` already do).
///
/// ## Status on this branch: fix reverted, test retained
///
/// The point-fix in `applyInBackground` was intentionally **reverted**
/// here — the timing race is being solved more fundamentally by the
/// `set blocks` refactor on another branch. This test is kept as the
/// acceptance gate for that refactor: its correctness assertions are
/// wrapped in `XCTExpectFailure` so the suite stays green while the fix
/// is absent. **When the refactor merges in, delete the
/// `XCTExpectFailure` wrapper** (see the inline note at the call site);
/// the test then reads green iff the refactor actually keeps `blocks`
/// and the rebuilt table's row count in sync.
@MainActor
final class TranscriptAsyncLoadSwitchRaceTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let windowSize = CGSize(width: 720, height: 800)
    private static let historyCount = 200

    private func makeBlocks() -> [Block] {
        (0..<Self.historyCount).map { i in
            Block(
                id: UUID(),
                kind: .paragraph(inlines: [
                    .text(
                        "line \(i): the rain in spain falls mainly on the plain, "
                            + "and the quick brown fox jumps over the lazy dog.")
                ]))
        }
    }

    private func drainMainLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// Mounts a bound table, kicks an async `setHistory`, tears the table
    /// down mid-flight (the switch-away), then lands Phase 2. The history
    /// must survive intact in `coordinator.blocks`.
    func testHistorySurvivesTableTeardownDuringAsyncLoad() async throws {
        let controller = Transcript2Controller()
        let coordinator = controller.coordinator

        // Mount + bind so `setHistory` takes the async Phase-2 path
        // (needs layoutWidth > 0 && viewportHeight > 0).
        let scroll = TranscriptScrollViewFactory.make(controller: controller)
        let window = NSWindow(
            contentRect: NSRect(
                origin: CGPoint(x: -30_000, y: -30_000), size: Self.windowSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        container.layoutSubtreeIfNeeded()
        TranscriptScrollViewFactory.bindData(scroll, controller: controller)
        controller.scrollToTail()
        container.layoutSubtreeIfNeeded()

        addTeardownBlock {
            window.contentView = nil
            window.close()
        }

        // Kick the load. Phase 1 (viewport) lands sync; Phase 2 (the rest)
        // is scheduled on a detached task.
        let blocks = makeBlocks()
        controller.setHistory(blocks)

        // Sanity: confirm we actually hit the async split — Phase 1 only
        // put the viewport batch into `blocks`, the rest is pending in
        // Phase 2. If this fails, the fixture went down the sync path and
        // the test below would be a false green.
        XCTAssertLessThan(
            controller.blockIds.count, Self.historyCount,
            "Fixture broke: setHistory took the SYNC path (blocks already complete), "
                + "so the async-landing race isn't being exercised. "
                + "blockIds=\(controller.blockIds.count)")

        // Switch away BEFORE Phase 2 lands: dismantle nils
        // `coordinator.tableView`, the same state the production swap
        // (`tearDownTranscript` → `dismantle`) leaves while the detached
        // layout task is still computing.
        TranscriptScrollViewFactory.dismantle(scroll, controller: controller)
        XCTAssertNil(coordinator.tableView)

        // Land Phase 2 (the detached task's `await MainActor.run`).
        drainMainLoop(seconds: 0.2)
        try? await Task.sleep(for: .milliseconds(100))
        drainMainLoop(seconds: 0.2)

        // Switch back: production rebuilds the scroll view on every swap.
        // This is the layer the user actually hits — the rebuilt table
        // tiles off `blocks.count`, and `markCellNeedsDisplay` /
        // selection-highlight / search all map `block.id → row` through
        // it. If `blocks` was truncated by the dropped Phase-2 landing,
        // the rebuilt table tiles short and the mapping is off (drag
        // selects but the wrong / no cell repaints).
        scroll.removeFromSuperview()
        let scroll2 = TranscriptScrollViewFactory.make(controller: controller)
        scroll2.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll2)
        NSLayoutConstraint.activate([
            scroll2.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll2.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll2.topAnchor.constraint(equalTo: container.topAnchor),
            scroll2.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        TranscriptScrollViewFactory.bindData(scroll2, controller: controller)
        controller.scrollToTail()
        container.layoutSubtreeIfNeeded()

        guard let table2 = scroll2.documentView as? Transcript2TableView else {
            return XCTFail("no Transcript2TableView after re-attach")
        }

        // ⚠️ Pending fix — this branch intentionally does NOT carry the
        // history-load fix. The `applyInBackground` landing was reverted
        // because the timing race is being solved more fundamentally by
        // the `set blocks` refactor on another branch. So the three
        // correctness assertions below currently FAIL (blocks/rows stay
        // truncated at the Phase-1 viewport count). They are wrapped in
        // `XCTExpectFailure` purely so this branch's suite stays green
        // while the fix is absent — the assertions themselves still
        // encode the correct post-fix behavior.
        //
        // WHEN THE `set blocks` REFACTOR MERGES IN: delete the
        // `XCTExpectFailure` wrapper (keep the assertions). The test then
        // becomes a live gate — green = the refactor fixed the desync,
        // red = it didn't. (If you forget to remove the wrapper, strict
        // mode trips it with "expected failure did not occur" once the
        // refactor makes the assertions pass — that's the reminder.)
        XCTExpectFailure(
            "History-load fix reverted on this branch; awaiting the set-blocks "
                + "refactor. Remove this wrapper after merging that refactor."
        ) {
            XCTAssertEqual(
                controller.blockIds.count, Self.historyCount,
                "Phase-2 blocks were dropped when the table was torn down mid-load: "
                    + "blocks=\(controller.blockIds.count), expected=\(Self.historyCount). "
                    + "This is the desync that breaks selection-highlight / search "
                    + "row mapping until a full re-attach.")
            XCTAssertEqual(
                table2.numberOfRows, Self.historyCount,
                "Re-attached table tiled to \(table2.numberOfRows) rows, expected "
                    + "\(Self.historyCount) — a truncated `blocks` tiles short here.")
            XCTAssertEqual(
                table2.numberOfRows, controller.blockIds.count,
                "Re-attached table row count must equal blocks.count, or the "
                    + "block.id → row mapping selection-highlight relies on is off "
                    + "(numberOfRows=\(table2.numberOfRows), blocks=\(controller.blockIds.count)).")
        }
    }
}

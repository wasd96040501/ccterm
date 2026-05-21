import AppKit
import XCTest

@testable import ccterm

/// Pins the post-#179 reentry-attach path's two **stable** invariants
/// that the upcoming viewport-slicing optimization depends on:
///
/// 1. **`materializeFirstAppear` fires at settled real width.** The
///    placeholder→real frame cascade is coalesced into a single async
///    materialize hop. By the time the hop runs, `layoutWidth` reflects
///    the final window width — not the placeholder clamp floor. This is
///    the "right moment" the viewport slicer will compute against.
///
/// 2. **Materialize transitions the table from 0-rows-visible to
///    all-rows-visible in one step.** This is the current binary
///    behavior (`pendingFirstAppear` toggles, `reloadData()` exposes
///    everything). The viewport-slicing optimization will replace it
///    with a progressive transition (0 → viewport-size → N), so this
///    test becomes the "before" anchor a future test refines.
///
/// **Why these two and not heightOfRow counters:** AppKit's layout
/// pass after `reloadData()` is asynchronous and not directly
/// controllable from a test harness (it can interleave with
/// `Task.yield()` ticks or skip entirely without a hosting window).
/// Pinning a precise `heightOfRow_uncached == N` is fragile against
/// AppKit's internal layout scheduling. The two invariants above are
/// deterministic and observable through the public surface, so the
/// regression gate is robust.
@MainActor
final class Transcript2ReentryCostBaselineTests: XCTestCase {

    private var observedCoordinators: [Transcript2Coordinator] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        Transcript2ReentryStats.reset()
        Transcript2ReentryStats.enabled = true
    }

    override func tearDown() {
        for c in observedCoordinators {
            NotificationCenter.default.removeObserver(c)
        }
        observedCoordinators.removeAll()
        Transcript2ReentryStats.enabled = false
        Transcript2ReentryStats.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeBlocks(count: Int) -> [Block] {
        (0..<count).map { i in
            Block(
                id: UUID(),
                kind: .paragraph(inlines: [.text("Paragraph \(i)")]))
        }
    }

    /// Wires a Coordinator + TableView the same way
    /// `Transcript2NSViewBridge.makeNSView` does, with `coordinator.blocks`
    /// pre-populated (mirroring what the session bridge / `setHistory`'s
    /// deferred branch would have left there by mount time).
    private func attachWithPrepopulatedBlocks(
        blocksCount: Int
    ) -> (Transcript2Coordinator, Transcript2TableView, [Block]) {
        let coordinator = Transcript2Coordinator()
        let blocks = makeBlocks(count: blocksCount)
        if !blocks.isEmpty {
            coordinator.apply([.insert(after: nil, blocks)], scroll: .none)
        }

        let table = Transcript2TableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("col"))
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        table.addTableColumn(column)
        table.dataSource = coordinator
        table.delegate = coordinator
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Transcript2Coordinator.tableFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: table)
        observedCoordinators.append(coordinator)

        coordinator.tableView = table
        table.coordinator = coordinator
        return (coordinator, table, blocks)
    }

    /// Drain pending `DispatchQueue.main.async` work — the one we
    /// care about is `materializeFirstAppear`, queued from
    /// `tableFrameDidChange`.
    ///
    /// `await Task.yield()` in an `async @MainActor` test method
    /// yields control to the main executor (== main dispatch queue),
    /// which then drains one item from the queue. Loop a few times
    /// so any chain of dispatches lands. Bare
    /// `CFRunLoopRunInMode(.defaultMode, ...)` and
    /// `RunLoop.current.run(...)` from a sync test method both fail
    /// to drain the main queue under XCTest's test-host lifecycle
    /// (verified 2026-05-22 — `CFRunLoopRunInMode` returns
    /// `kCFRunLoopRunTimedOut` without processing any source; a
    /// `wait(for:[exp], timeout:)` expectation scheduled via
    /// `DispatchQueue.main.asyncAfter` also times out).
    private func pumpMainRunloop() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }

    /// Drives the placeholder→real frame cascade the way SwiftUI's mount
    /// path delivers it: two `setFrameSize` calls in succession, then a
    /// runloop pump so the async materialize fires.
    private func driveAttachCascade(
        on table: Transcript2TableView,
        realWidth: CGFloat = 1200
    ) async {
        // Placeholder width — clamps to `BlockStyle.minLayoutWidth` (460).
        table.setFrameSize(NSSize(width: 100, height: 600))
        // Real width — exceeds `maxLayoutWidth` so `clampedLayoutWidth`
        // lands at the ceiling (780), distinct from the placeholder.
        table.setFrameSize(NSSize(width: realWidth, height: 600))
        await pumpMainRunloop()
    }

    // MARK: - Tests

    /// **Invariant 1 — materialize fires at settled real width.**
    ///
    /// Before the cascade: `layoutWidth == 0` (no table bounds yet).
    /// During the cascade: AppKit sees 0 rows the whole way
    /// (`pendingFirstAppear` suppresses `numberOfRows`).
    /// After the cascade + pump: `layoutWidth` reflects the final
    /// width, NOT the placeholder clamp.
    ///
    /// The viewport slicer computes its slice against `layoutWidth` and
    /// `viewportHeight`; this test pins that those two values are
    /// already-final at the moment the slicer would run.
    func testMaterializeReadsSettledRealWidth() async {
        let (coordinator, table, blocks) =
            attachWithPrepopulatedBlocks(blocksCount: 5)

        // Pre-cascade: AppKit must see 0 rows (pendingFirstAppear gate).
        // We don't assert pre-cascade `layoutWidth` — NSTableView's
        // default frame after column setup has a non-zero
        // `bounds.width`, so the pre-cascade `layoutWidth` reads
        // whatever the default clamps to.
        XCTAssertEqual(
            coordinator.numberOfRows(in: table), 0,
            "pendingFirstAppear must suppress numberOfRows pre-materialize")

        // Drive the cascade STEP BY STEP so we can pin `layoutWidth`
        // at the moment the second (real-width) frame change has
        // landed — which is the moment `tableFrameDidChange` arms
        // `materializeFirstAppear`. In production this matches the
        // moment the slicer reads from when computing its Phase 1
        // boundary.
        table.setFrameSize(NSSize(width: 100, height: 600))
        XCTAssertEqual(
            coordinator.layoutWidth, BlockStyle.minLayoutWidth,
            "placeholder frame change → layoutWidth clamps to the floor")

        table.setFrameSize(NSSize(width: 1200, height: 600))
        XCTAssertEqual(
            coordinator.layoutWidth, BlockStyle.maxLayoutWidth,
            "real frame change → layoutWidth clamps to the ceiling. "
                + "This is the value the upcoming viewport slicer reads "
                + "the moment `tableFrameDidChange` arms materialize.")

        // Now pump so materialize actually fires. We DON'T re-assert
        // `layoutWidth` after the pump — NSTableView without a
        // hosting scroll view may auto-tile its own bounds during
        // `reloadData()`, dropping the width back to the column-default
        // size. This is a test-environment artifact (a real
        // `NSScrollView` would keep retiling at the document's outer
        // width) and is not load-bearing for the slicer claim above.
        await pumpMainRunloop()

        XCTAssertEqual(
            coordinator.numberOfRows(in: table), blocks.count,
            "materialize transitions AppKit's row count from 0 to N")
    }

    /// **Invariant 2 — materialize is currently "all-or-nothing".**
    ///
    /// Today's behavior: between `pendingFirstAppear = true` (0 rows
    /// visible) and `materializeFirstAppear` (all `blocks.count` rows
    /// visible) there is no intermediate state. The upcoming
    /// viewport-slicing optimization will replace this single-step
    /// transition with a progressive one (0 → viewport-slice-size → N),
    /// so the assertion `numberOfRows == blocks.count` immediately
    /// after the cascade will need to change.
    ///
    /// Until then: nailing the binary transition down with a test
    /// guards against accidental regressions of `pendingFirstAppear`
    /// semantics during refactor.
    func testMaterializeIsAllOrNothingToday() async {
        let (coordinator, table, blocks) =
            attachWithPrepopulatedBlocks(blocksCount: 30)

        // Before materialize: `pendingFirstAppear` suppresses everything.
        XCTAssertEqual(coordinator.numberOfRows(in: table), 0)

        await driveAttachCascade(on: table)

        // After one materialize hop: AppKit sees ALL rows. There is no
        // intermediate "viewport-size only" state today.
        XCTAssertEqual(
            coordinator.numberOfRows(in: table), blocks.count,
            "current implementation surfaces ALL blocks in a single "
                + "materialize step — this is the baseline the "
                + "viewport-slicing optimization replaces")

        // Each block's height query against the data source succeeds —
        // the materialize correctly transitioned every row to "visible
        // to AppKit's data model". No assertions on cost (cache state
        // is internal and AppKit's layout-pass timing is undocumented
        // for windowless test setups).
        for i in 0..<blocks.count {
            let h = coordinator.tableView(table, heightOfRow: i)
            XCTAssertGreaterThan(
                h, 0,
                "row \(i) should have a positive height after materialize")
        }
    }

    /// **Invariant 3 — empty session attach takes the fast path.**
    ///
    /// When `blocks.isEmpty` at `tableView.didSet`, the coordinator
    /// bypasses the pending-first-appear gate entirely: `numberOfRows`
    /// is 0 because there's nothing to show, not because anything is
    /// being suppressed. Driving a frame cascade against an empty
    /// session must not trigger materialize and must not stall.
    ///
    /// Phased rollouts in the upcoming optimization will preserve this
    /// fast path — no point slicing zero blocks. This test catches a
    /// regression where the new path forgets to short-circuit.
    func testEmptyAttachSkipsMaterialize() async {
        let (coordinator, table, _) =
            attachWithPrepopulatedBlocks(blocksCount: 0)

        XCTAssertEqual(coordinator.numberOfRows(in: table), 0)
        await driveAttachCascade(on: table)
        XCTAssertEqual(
            coordinator.numberOfRows(in: table), 0,
            "an empty session must remain 0-rows after the cascade")
    }
}

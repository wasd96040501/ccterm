import AppKit
import XCTest

@testable import ccterm

/// Verifies the session-switch attach path suppresses AppKit work at
/// SwiftUI's placeholder width and coalesces the placeholder→real
/// frame cascade into one `reloadData()` at the real width.
///
/// **Why a real `NSTableView` (no mock):** the contract we care about is
/// AppKit-facing — that `numberOfRows(in:)` returns 0 during the
/// pending-first-appear window, that the `frameDidChange` notification
/// is what arms materialize, and that `materializeFirstAppear` lands a
/// single `reloadData()` synchronously. Mocking the table view would
/// hide exactly the dispatch we want to verify.
///
/// **What the test reproduces:** SwiftUI's mount cascade gives our
/// `Transcript2ScrollView` a placeholder frame (`rawWidth ~100pt`)
/// synchronously followed by the real frame within the same event
/// cycle. We drive that pattern explicitly by calling
/// `table.setFrameSize` twice in succession on a freshly-attached
/// table — the `frameDidChange` notifications then flow into
/// `Transcript2Coordinator.tableFrameDidChange` exactly as production
/// would deliver them.
@MainActor
final class Transcript2CoordinatorAttachTests: XCTestCase {

    /// Coordinators observed across the test. `tearDown` removes them
    /// from `NotificationCenter.default` so the next test in this class
    /// starts with no inherited observers. The default center is the
    /// only valid target — `NSView.postsFrameChangedNotifications`
    /// posts there directly via AppKit and offers no API to redirect.
    /// Cross-class isolation is enforced at the process level
    /// (XCTest forks per class per `cctermTests/CLAUDE.md`).
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

    /// Wires a real `Transcript2Coordinator` + `Transcript2TableView`
    /// the same way `Transcript2NSViewBridge.makeNSView` does:
    /// dataSource/delegate set, frameChange notification observer
    /// registered, then the coordinator's `tableView` weak ref assigned
    /// (which fires `didSet` — the entry point for the fix).
    ///
    /// Returns both so the test can drive frame changes directly and
    /// observe the cumulative state.
    private func attachTable(
        blocksCount: Int
    ) -> (
        Transcript2Coordinator, Transcript2TableView, [Block]
    ) {
        let coordinator = Transcript2Coordinator()
        let blocks = makeBlocks(count: blocksCount)
        // Pre-populate `coordinator.blocks` the same way the bridge would
        // by the time the view re-mounts on session re-entry. We hit the
        // "no table" branch in `apply` because `tableView` hasn't been
        // assigned yet — pure data mutation.
        if !blocks.isEmpty {
            coordinator.apply([.insert(after: nil, blocks)], scroll: .none)
        }

        let table = Transcript2TableView()
        table.alphaValue = 0
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

        // The attach itself. After this, `pendingFirstAppear == true`
        // because blocks is non-empty.
        coordinator.tableView = table
        table.coordinator = coordinator
        return (coordinator, table, blocks)
    }

    /// Drain pending `DispatchQueue.main.async` work. `materializeFirstAppear`
    /// is queued from `tableFrameDidChange`; one or two yields is enough
    /// in practice but loop a few times for resilience under CI load.
    private func pumpMainRunloop() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }

    // MARK: - Tests

    /// The placeholder→real frame cascade fires `tableFrameDidChange`
    /// twice within a single event cycle. The coordinator should
    /// coalesce these into one async materialize: AppKit sees 0 rows
    /// throughout the cascade (no `heightOfRow` at the wrong width), no
    /// `invalidate(rows:)` runs, and the final state reflects the real
    /// `blocks.count` after one runloop tick.
    func testPlaceholderCascadeIsCoalescedIntoOneMaterialize() async {
        let (coordinator, table, blocks) = attachTable(blocksCount: 5)

        // 1. Post-attach, pre-frame: AppKit hasn't queried us yet, but
        //    our datasource shouldn't expose the rows. This is the gate
        //    that prevents AppKit from doing heightOfRow at the
        //    placeholder width once the first frame change arrives.
        XCTAssertEqual(
            coordinator.numberOfRows(in: table), 0,
            "numberOfRows must be suppressed during pendingFirstAppear")

        // 2. Reproduce the placeholder transition. rawWidth=100 clamps
        //    to `minLayoutWidth`. Verify the cascade-features signal —
        //    layoutWidth lands at the floor (460), not the raw value.
        table.setFrameSize(NSSize(width: 100, height: 600))
        XCTAssertEqual(
            coordinator.layoutWidth, BlockStyle.minLayoutWidth,
            "placeholder rawWidth clamps to layout floor")
        XCTAssertEqual(
            coordinator.numberOfRows(in: table), 0,
            "still suppressed — async materialize hasn't fired")

        // 3. Real transition — synchronously after, same event cycle in
        //    production. We use a width above `maxLayoutWidth` so
        //    `clampedLayoutWidth` lands at the ceiling, distinct from
        //    the placeholder's floor.
        table.setFrameSize(NSSize(width: 1200, height: 600))
        XCTAssertEqual(
            coordinator.layoutWidth, BlockStyle.maxLayoutWidth,
            "real rawWidth clamps to layout ceiling")
        XCTAssertEqual(
            coordinator.numberOfRows(in: table), 0,
            "still suppressed — async materialize is queued, not yet run")

        // 4. Counters at this point: both frame changes are observed
        //    (frameDidChangeReal=2). No invalidate has fired —
        //    `materializeFirstAppear` uses `reloadData()`, not
        //    `invalidate(rows:)`.
        let preSnap = Transcript2ReentryStats.snapshot()
        XCTAssertEqual(
            preSnap.frameDidChangeReal, 2,
            "both placeholder and real frame changes should reach our handler")
        XCTAssertEqual(
            preSnap.invalidateCount, 0,
            "the placeholder cascade must not trigger invalidate(rows:)")
        XCTAssertEqual(
            preSnap.heightOfRowUncached, 0,
            "AppKit cannot have computed heightOfRow — numberOfRows=0 the whole way")

        // 5. Pump one runloop tick so the queued async fires.
        await pumpMainRunloop()

        // 6. After materialize: rows are exposed to AppKit at the real
        //    width.
        XCTAssertEqual(
            coordinator.numberOfRows(in: table), blocks.count,
            "post-materialize numberOfRows must report the real count")
        XCTAssertEqual(
            coordinator.blockIds.count, blocks.count,
            "block storage is unchanged by the materialize path")

        // 7. Final counters: still no invalidate(rows:) — the materialize
        //    path used reloadData() instead.
        let postSnap = Transcript2ReentryStats.snapshot()
        XCTAssertEqual(
            postSnap.invalidateCount, 0,
            "still zero — materialize uses reloadData(), not invalidate")
    }

    /// A bridge-driven `.insert` arriving during the pending-first-appear
    /// window (the brief gap between attach and materialize) must update
    /// `blocks` but not touch AppKit. The next materialize's `reloadData()`
    /// folds the new block in.
    func testApplyDuringPendingWindowMutatesBlocksOnly() async {
        let (coordinator, table, initial) = attachTable(blocksCount: 3)

        // Sanity: we're in the pending window.
        XCTAssertEqual(coordinator.numberOfRows(in: table), 0)

        // A new block from the bridge mid-window. Goes through
        // `apply` → no-AppKit branch (we'd crash AppKit otherwise
        // because its row count is 0).
        let newBlock = Block(
            id: UUID(),
            kind: .paragraph(inlines: [.text("mid-window")]))
        coordinator.apply(
            [.insert(after: initial.last?.id, [newBlock])],
            scroll: .none)

        // `blocks` array reflects the new block; AppKit isn't told yet
        // (numberOfRows still suppressed to 0).
        XCTAssertEqual(coordinator.blockIds.count, initial.count + 1)
        XCTAssertEqual(coordinator.numberOfRows(in: table), 0)

        // Drive the placeholder→real cascade.
        table.setFrameSize(NSSize(width: 100, height: 600))
        table.setFrameSize(NSSize(width: 1200, height: 600))
        await pumpMainRunloop()

        // After materialize: AppKit sees all blocks including the
        // mid-window insert.
        XCTAssertEqual(
            coordinator.numberOfRows(in: table), initial.count + 1,
            "materialize's reloadData() must surface the mid-window insert")
        let snap = Transcript2ReentryStats.snapshot()
        XCTAssertEqual(snap.invalidateCount, 0)
    }

    /// Empty session attach (no blocks at didSet) takes the alpha=1
    /// fast-path and does NOT enter the pending window. `numberOfRows`
    /// reports 0 because blocks is empty, not because we're suppressing.
    func testEmptyAttachSkipsPendingFirstAppear() async {
        let (coordinator, table, _) = attachTable(blocksCount: 0)

        XCTAssertEqual(coordinator.numberOfRows(in: table), 0)

        // Frame changes on an empty table should take the regular
        // (non-pending) path. With blocks empty the regular path also
        // doesn't invalidate anything (the `!blocks.isEmpty` guard).
        table.setFrameSize(NSSize(width: 100, height: 600))
        table.setFrameSize(NSSize(width: 1200, height: 600))
        await pumpMainRunloop()

        let snap = Transcript2ReentryStats.snapshot()
        // Empty attach doesn't call `recordAttachStart` (DEBUG path
        // gated on `!blocks.isEmpty`), so the counters we read reflect
        // whatever the prior cycle left behind. We only assert: no
        // pendingFirstAppear was entered, no invalidate fired.
        XCTAssertEqual(snap.invalidateCount, 0)
        XCTAssertEqual(
            coordinator.numberOfRows(in: table), 0,
            "still zero — but because blocks is empty, not because of suppression")
    }

    /// A detach (`tableView = nil`) followed by a re-attach to a
    /// different table should start a fresh pending cycle. The first
    /// attach's queued materialize must not affect the second attach.
    func testDetachClearsPendingState() async {
        let (coordinator, firstTable, _) = attachTable(blocksCount: 5)

        // Mid-pending detach. After this, materialize should no-op
        // even if its async closure runs.
        coordinator.tableView = nil

        // Pump — materialize closure may have been queued from the
        // first attach's frame change observer. Let it run; the guard
        // in `materializeFirstAppear` (`guard pendingFirstAppear,
        // let table = tableView`) ensures it doesn't crash and doesn't
        // touch the gone table.
        NotificationCenter.default.removeObserver(
            coordinator,
            name: NSView.frameDidChangeNotification, object: firstTable)
        table_setFrameAndPump(firstTable)
        await pumpMainRunloop()

        // Re-attach to a fresh table: pending cycle restarts.
        let secondTable = Transcript2TableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("col"))
        secondTable.addTableColumn(column)
        secondTable.dataSource = coordinator
        secondTable.delegate = coordinator
        secondTable.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Transcript2Coordinator.tableFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: secondTable)
        // (coordinator already tracked in `observedCoordinators` from
        //  the first attach; one removeObserver on tearDown drops both.)
        coordinator.tableView = secondTable
        secondTable.coordinator = coordinator

        XCTAssertEqual(
            coordinator.numberOfRows(in: secondTable), 0,
            "fresh attach should re-enter pendingFirstAppear")

        secondTable.setFrameSize(NSSize(width: 100, height: 600))
        secondTable.setFrameSize(NSSize(width: 1200, height: 600))
        await pumpMainRunloop()

        XCTAssertEqual(
            coordinator.numberOfRows(in: secondTable), 5,
            "second materialize lands correctly")
    }

    /// `table_setFrameAndPump` simulates a frame change on a no-longer-attached
    /// table — useful to push notifications through that the production
    /// dismantle path would consume. Used in `testDetachClearsPendingState`
    /// to ensure the first table's deferred materialize doesn't crash.
    private func table_setFrameAndPump(_ table: Transcript2TableView) {
        // Trigger any deferred work that was queued against the old
        // table. We don't assert here; just make sure no exception
        // bubbles up.
        table.setFrameSize(NSSize(width: 800, height: 600))
    }
}

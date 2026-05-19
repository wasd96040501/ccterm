import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Exercises the `isAnchorSettled` state machine on the real
/// `NativeTranscript2View` mounted through `NSHostingController` into a
/// hidden offscreen window — the same scaffold the snapshot tests use to
/// drive SwiftUI's real layout pipeline. No mocked `NSTableView`, no fake
/// frame-change notifications: production code paths run end-to-end and
/// the assertions read the resulting `Transcript2Controller` /
/// `NSScrollView` state directly.
///
/// Three scenarios:
///  - **Cold mount race**: `setHistory` arrives while the view is not
///    yet on the screen (width == 0). After the offscreen layout pass
///    settles, `isAnchorSettled` must be `true` and the last block
///    must be visually anchored at the bottom.
///  - **Re-attach (session switch / view rebuild)**: a fresh
///    `NSHostingController` mounts the same controller, replacing the
///    coordinator's `tableView`. The flag must drop to `false` on
///    re-attach and recover to `true` once the new table tiles.
///  - **Routine append**: streaming `apply(.insert(...))` traffic on
///    an already-stabilized transcript must **not** reset the flag.
@MainActor
final class Transcript2AnchorSettledTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Cold mount

    func testColdMountSettlesAndAnchorsAtBottom() throws {
        let controller = Transcript2Controller()
        XCTAssertFalse(
            controller.isAnchorSettled,
            "fresh controller starts unsettled")

        // Seed BEFORE mounting — this is the deferred branch:
        // coordinator.layoutWidth == 0, blocks pre-insert, anchor pends.
        let blocks = Self.makeParagraphBlocks(count: 60)
        controller.setHistory(blocks, anchor: .bottom)
        XCTAssertEqual(
            controller.blockCount, 60,
            "setHistory deferred branch must still pre-insert blocks")
        XCTAssertFalse(
            controller.isAnchorSettled,
            "no table mounted → anchor still pending")

        let host = mount(controller: controller)
        defer { teardown(host) }

        settle(host: host)

        XCTAssertTrue(
            controller.isAnchorSettled,
            "tableFrameDidChange 0→positive must consume the deferred anchor")
        assertLastRowVisible(
            in: host,
            "last block must be visible at the bottom of the scroll view")
    }

    // MARK: - Re-attach

    func testReAttachResetsAndReSettlesAtBottom() throws {
        let controller = Transcript2Controller()
        let blocks = Self.makeParagraphBlocks(count: 60)
        controller.setHistory(blocks, anchor: .bottom)

        let host1 = mount(controller: controller)
        settle(host: host1)
        XCTAssertTrue(
            controller.isAnchorSettled,
            "first mount must settle the anchor")
        assertLastRowVisible(
            in: host1, "first mount must anchor at the bottom")

        // Tear down the first host, then mount the same controller on a
        // fresh hosting / window. SwiftUI builds a new NSViewRepresentable
        // → new `makeNSView` → `coordinator.tableView` reassigned → `didSet`
        // flips `isAnchorSettled` to false.
        teardown(host1)

        let host2 = mount(controller: controller)
        defer { teardown(host2) }

        // Without intervening settle, the re-attach has already happened
        // (makeNSView ran during SwiftUI commit) and didSet flipped the
        // flag back. The new table's frame is still being tiled though, so
        // the second settle is required to let `tableFrameDidChange`
        // consume the anchor and flip back to true.
        settle(host: host2)

        XCTAssertTrue(
            controller.isAnchorSettled,
            "re-attach must re-settle after the new table tiles")
        assertLastRowVisible(
            in: host2, "re-attached table must land at the bottom anchor")
    }

    // MARK: - Dismount contract

    /// `isAnchorSettled` is documented as "first-screen anchor has
    /// landed for the **currently-attached** `NSTableView`." When the
    /// view is dismounted (sidebar switch, `.id`-driven SwiftUI
    /// rebuild), no NSTableView is attached — the flag must reflect
    /// that and read `false`.
    ///
    /// **Why this is load-bearing.** `RootView2` observes this flag
    /// through `.onChange(of: currentController?.isAnchorSettled,
    /// initial: true)` to drive the sidebar-switch bake-clear. If the
    /// flag stays stale-`true` across a dismount, on re-entry the
    /// watcher sees `true → true` (no transition) at body re-eval, so
    /// the bake-clear can fire on a body pass where the new
    /// NSTableView either isn't attached yet or hasn't tiled. The
    /// user-visible symptom is the "瞬间看到 transcript 开头的内容"
    /// flicker on re-entry into a previously visited history session.
    ///
    /// **Why `weak var tableView` alone isn't enough.** Swift `willSet`
    /// / `didSet` do **not** fire when a weak reference goes to nil
    /// via the referent's dealloc — only on explicit assignment. The
    /// `Transcript2Coordinator.tableView.didSet` reset path therefore
    /// only fires on attach, not on detach. The fix lives in
    /// `Transcript2NSViewBridge.dismantleNSView`: explicitly nil the
    /// `coordinator.tableView` so `didSet` runs on the detach leg too,
    /// resetting `isAnchorSettled` to `false`.
    ///
    /// Test mechanics: drive the lifecycle through the SAME path
    /// production uses — `Transcript2NSViewBridge.makeNSView` +
    /// `dismantleNSView`. Mount once, mark anchor settled (the
    /// post-Phase-1 entry to the `setAnchorSettled(true)` state),
    /// then call `dismantleNSView` and assert. No SwiftUI hosting, no
    /// runloop wait — the contract is fundamentally about whether
    /// `dismantleNSView` resets the flag, period.
    func testDismountResetsIsAnchorSettled() throws {
        let controller = Transcript2Controller()
        let coordinator = controller.coordinator

        // Attach a fresh NSTableView the way `makeNSView` would.
        let table = NSTableView()
        coordinator.tableView = table
        XCTAssertFalse(
            coordinator.isAnchorSettled,
            "didSet on attach must reset settled (fresh attach is not yet anchored)")

        // Simulate Phase 1 completing: setHistory's `markAnchorSettled`
        // path. The coordinator now reports settled=true.
        coordinator.markAnchorSettled()
        XCTAssertTrue(
            controller.isAnchorSettled,
            "markAnchorSettled must flip the flag")

        // Dismount via the production codepath. This is the exact
        // entry point SwiftUI invokes during `.id`-driven rebuilds
        // and view teardown — we don't mock the SwiftUI side because
        // we're testing the bridge's own contract.
        let scroll = Transcript2ScrollView()
        scroll.documentView = table
        Transcript2NSViewBridge.dismantleNSView(
            scroll, coordinator: coordinator)

        // ── THE CONTRACT ──
        // No table attached → "first-screen anchor has landed for the
        // currently-attached NSTableView" is not satisfied (there is
        // no current table). Must be false.
        XCTAssertNil(
            coordinator.tableView,
            "dismantleNSView must explicitly clear tableView")
        XCTAssertFalse(
            controller.isAnchorSettled,
            "dismount contract: isAnchorSettled must be false after dismantle")
    }

    // MARK: - Snapshot replacement

    /// `setHistory` is a snapshot setter — calling it again replaces the
    /// transcript's contents and re-anchors. This locks in the "history
    /// snapshot is repeatable" half of the API contract that the rename
    /// from `loadInitial` makes explicit. The first snapshot stabilizes;
    /// the second snapshot must replace the block list and re-settle the
    /// anchor against the new tail.
    func testSecondSetHistoryReplacesContentsAndReAnchors() throws {
        let controller = Transcript2Controller()
        controller.setHistory(
            Self.makeParagraphBlocks(count: 6), anchor: .bottom)

        let host = mount(controller: controller)
        defer { teardown(host) }
        settle(host: host)
        XCTAssertTrue(controller.isAnchorSettled)
        XCTAssertEqual(controller.blockCount, 6)

        // Second snapshot — fresh ids, larger payload. Must replace
        // (no leftover ids from the first snapshot), re-anchor, and end
        // up settled. Phase 2 lands async; the assertions after
        // `settle()` see the final post-Phase-2 state.
        let secondBlocks = Self.makeParagraphBlocks(count: 80)
        controller.setHistory(secondBlocks, anchor: .bottom)

        settle(host: host)

        XCTAssertEqual(
            controller.blockCount, 80,
            "second setHistory must replace the block list once Phase 2 lands")
        XCTAssertEqual(
            controller.blockIds, secondBlocks.map(\.id),
            "block ids must match the second snapshot exactly — no first-snapshot leftovers")
        XCTAssertTrue(
            controller.isAnchorSettled,
            "second setHistory must re-settle once Phase 1 / deferred scroll runs")
        assertLastRowVisible(
            in: host,
            "second setHistory must land at the bottom of the new snapshot")
    }

    // MARK: - Append does not reset

    func testRoutineAppendDoesNotResetSettled() throws {
        let controller = Transcript2Controller()
        controller.setHistory(
            Self.makeParagraphBlocks(count: 8), anchor: .bottom)

        let host = mount(controller: controller)
        defer { teardown(host) }
        settle(host: host)
        XCTAssertTrue(controller.isAnchorSettled)

        // Streaming-style append after stabilization. Settled flag must
        // stay true — appending one assistant message into an already-
        // anchored transcript is not a first-screen event.
        let tailId = controller.blockIds.last
        let appended = Block(
            id: UUID(),
            kind: .paragraph(inlines: [.text("streamed reply")]))
        controller.apply(.insert(after: tailId, [appended]))

        XCTAssertTrue(
            controller.isAnchorSettled,
            "single-message append must not reset isAnchorSettled")

        // A second append, prepend-style (after: nil) — same rule.
        let prepended = Block(
            id: UUID(),
            kind: .paragraph(inlines: [.text("backfill")]))
        controller.apply(.insert(after: nil, [prepended]))
        XCTAssertTrue(
            controller.isAnchorSettled,
            "prepend on a settled transcript must not reset isAnchorSettled")
    }

    // MARK: - Helpers (real component fixture)

    private struct Host {
        let window: NSWindow
        let hosting: NSHostingController<AnyView>
    }

    /// Mount `NativeTranscript2View` for `controller` inside a hidden
    /// offscreen window, the same way `ViewSnapshot.render` does. Uses
    /// the test-only `ccterm_orderFrontForTesting` so the window never
    /// becomes visible.
    private func mount(
        controller: Transcript2Controller,
        size: CGSize = CGSize(width: 600, height: 600)
    ) -> Host {
        let view = NativeTranscript2View(controller: controller)
            .environment(\.syntaxEngine, SyntaxHighlightEngine())
        let hosting = NSHostingController(rootView: AnyView(view))
        hosting.view.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(
                origin: CGPoint(x: -30_000, y: -30_000),
                size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0.01
        window.contentViewController = hosting
        window.ccterm_orderFrontForTesting()
        return Host(window: window, hosting: hosting)
    }

    private func teardown(_ host: Host) {
        host.window.contentViewController = nil
        host.window.close()
    }

    /// Drain the runloop so SwiftUI commits the view tree and AppKit's
    /// deferred layout (frame-change notifications, `noteHeightOfRows`,
    /// etc.) lands before the assertions run.
    private func settle(host: Host, duration: TimeInterval = 0.6) {
        host.hosting.view.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.02))
        }
        host.hosting.view.layoutSubtreeIfNeeded()
    }

    /// Walks the host view hierarchy, finds the embedded `NSTableView`,
    /// and asks the enclosing scroll view which rows are within
    /// `documentVisibleRect` (inset-aware). The failure message carries
    /// the geometry numbers verbatim so a regression reports the actual
    /// scroll / row state without the next person having to re-add print
    /// statements.
    private func assertLastRowVisible(
        in host: Host,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let result = visibilityProbe(in: host)
        XCTAssertTrue(
            result.matched, "\(message); \(result.summary)",
            file: file, line: line)
    }

    private func visibilityProbe(in host: Host) -> (matched: Bool, summary: String) {
        guard let table = findTableView(in: host.hosting.view) else {
            return (false, "no NSTableView in host")
        }
        guard let scrollView = table.enclosingScrollView else {
            return (false, "no scroll view")
        }
        if table.numberOfRows == 0 {
            return (false, "numberOfRows == 0")
        }
        let documentVisible = scrollView.documentVisibleRect
        let visible = table.rows(in: documentVisible)
        let lastRowRect = table.rect(ofRow: table.numberOfRows - 1)
        let lastVisibleRow =
            (visible.location == NSNotFound)
            ? -1 : visible.location + visible.length - 1
        let matched =
            visible.location != NSNotFound && visible.length > 0
            && lastVisibleRow == table.numberOfRows - 1
        let summary =
            "scrollOrigin=\(scrollView.contentView.bounds.origin) "
            + "documentVisible=\(documentVisible) "
            + "numberOfRows=\(table.numberOfRows) "
            + "visibleRows={loc:\(visible.location), len:\(visible.length)} "
            + "lastVisibleRow=\(lastVisibleRow) "
            + "lastRowRect=\(lastRowRect) "
            + "tableFrame=\(table.frame) "
            + "clipBounds=\(scrollView.contentView.bounds) "
            + "contentInsets={t:\(scrollView.contentInsets.top), b:\(scrollView.contentInsets.bottom)}"
        return (matched, summary)
    }

    private func findTableView(in view: NSView) -> NSTableView? {
        if let t = view as? NSTableView { return t }
        for sub in view.subviews {
            if let t = findTableView(in: sub) { return t }
        }
        return nil
    }

    private static func makeParagraphBlocks(count: Int) -> [Block] {
        (0..<count).map { i in
            Block(
                id: UUID(),
                kind: .paragraph(inlines: [.text("paragraph \(i)")]))
        }
    }
}

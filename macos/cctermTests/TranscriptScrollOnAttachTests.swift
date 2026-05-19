import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Regression net for "open a session with a long history → land at
/// the tail, not the top." Covers both failure modes captured in
/// `fix(transcript): anchor to tail on (re-)attach`:
///
/// 1. **Cold open** — first time a session's `ChatHistoryView` mounts,
///    Phase A's parse takes long enough that `loadInitial` runs while
///    `layoutWidth == 0`, so the controller defers via `pendingInitial`.
///    The deferred scroll has to land *after* AppKit finishes inserting
///    the table into the clip view (`enclosingScrollView != nil`).
///
/// 2. **Re-entry** — a `.loaded` session whose view is mounted a
///    second time. The bridge no longer re-fires `.reset`, so
///    `loadInitial` is never re-invoked and `pendingInitial` is never
///    set. The only scroll signal is `ChatHistoryView.task`'s direct
///    `controller.scrollToBottom()`, which runs *before* SwiftUI
///    commits the new NSView tree — `tableView` is still nil at that
///    moment, and any scroll-state passed through `apply(_:scroll:)`
///    is silently dropped.
///
/// Both bugs land the user near the top of the transcript instead of
/// the bottom. The assertion below pins the last block's `maxY` to the
/// scroll view's visible-content-area bottom (`clip.bounds.maxY -
/// contentInsets.bottom`), which is exactly where
/// `Coordinator.scrollRowToBottom` aligns it.
///
/// ### Test infrastructure ###
///
/// Tests render through the same offscreen path `ViewSnapshot` uses —
/// `NSHostingController` parked in a borderless `alphaValue=0.01`
/// window at (-30_000, -30_000), with the `ccterm_orderFrontForTesting`
/// swizzle keeping the window off the visible space. SwiftUI body
/// evaluation, `.task` execution, `NSViewRepresentable.makeNSView`,
/// AppKit's view-install pipeline, `frameDidChange` notifications, and
/// `onLayoutReady` all run for real — the only thing missing relative
/// to a real app launch is window visibility, which has nothing to do
/// with the bugs under test.
///
/// History data comes from `LargeJSONLFixture` — a self-contained
/// generator that writes a 400-entry alternating user/assistant
/// transcript to a temp file. The test injects the path via
/// `session.loadHistory(overrideURL:)` *before* mounting; the
/// `ChatHistoryView.task`'s default-path `loadHistory()` call then
/// hits the idempotent guard and is a no-op. Production's
/// `~/.claude/projects` is never touched.
@MainActor
final class TranscriptScrollOnAttachTests: XCTestCase {

    private var fixtureA: LargeJSONLFixture!
    private var fixtureB: LargeJSONLFixture?
    private var sidA: String!
    private var sidB: String?
    private var repository: InMemorySessionRepository!
    private var manager: SessionManager!

    private static let viewSize = CGSize(width: 720, height: 720)

    override func setUpWithError() throws {
        continueAfterFailure = false
        sidA = UUID().uuidString
        fixtureA = try LargeJSONLFixture(sessionId: sidA)
        repository = InMemorySessionRepository()
        // Persisted record makes `prepareDraftSession(sid)` land in
        // `.active` phase (the `record:` init branch); without one it
        // would default to `.draft` and `loadHistory` would no-op.
        repository.save(
            SessionRecord(
                sessionId: sidA,
                title: "fixture-A",
                cwd: "/tmp/ccterm-test-\(UUID().uuidString)",
                status: .created))
        manager = SessionManager(
            repository: repository,
            cliClientFactory: { _ in FakeCLIClient() })
    }

    override func tearDown() async throws {
        fixtureA?.remove()
        fixtureA = nil
        fixtureB?.remove()
        fixtureB = nil
    }

    // MARK: - Tests

    /// Cold open: mount once, settle, last row should sit at the
    /// visible-content-area bottom. Fails on un-fixed code when the
    /// `loadInitial`'s deferred-branch scroll target lands at the top.
    func testColdOpenAnchorsToTail() throws {
        let session = manager.prepareDraftSession(sidA)
        // Override path before mount so the view's `.task`-driven
        // `loadHistory()` finds a runtime already past `.notLoaded` and
        // no-ops. The view path otherwise resolves through
        // `~/.claude/projects`, which the test must not depend on.
        session.loadHistory(overrideURL: fixtureA.url, tailTarget: 80)

        let host = mountChatHistory(sessionId: sidA)
        defer { teardownHost(host) }

        waitUntilLoaded(session: session)
        drainMainRunLoop(seconds: 0.6)

        assertLastRowAtVisibleBottom(controller: session.controller)
    }

    /// Re-entry: mount session A, switch to session B (so SwiftUI tears
    /// down A's NSView tree but the `Session` / `controller` survive in
    /// `SessionManager`), switch back to A. A's `historyLoadState` is
    /// `.loaded` by then, so `.task`'s `loadHistory()` no-ops and only
    /// `controller.scrollToBottom()` is available to anchor — exactly
    /// the path the original bug missed.
    func testReEntryAnchorsToTail() throws {
        let sidBLocal = UUID().uuidString
        sidB = sidBLocal
        let fb = try LargeJSONLFixture(sessionId: sidBLocal)
        fixtureB = fb
        repository.save(
            SessionRecord(
                sessionId: sidBLocal,
                title: "fixture-B",
                cwd: "/tmp/ccterm-test-\(UUID().uuidString)",
                status: .created))

        let sessionA = manager.prepareDraftSession(sidA)
        let sessionB = manager.prepareDraftSession(sidBLocal)
        sessionA.loadHistory(overrideURL: fixtureA.url, tailTarget: 80)
        sessionB.loadHistory(overrideURL: fb.url, tailTarget: 80)

        let nav = TestNavBox(sid: sidA)
        let host = mountChatHistory(navBox: nav)
        defer { teardownHost(host) }

        waitUntilLoaded(session: sessionA)
        drainMainRunLoop(seconds: 0.6)
        // Sanity: cold A landed at tail. If this fails the re-entry
        // assertion below is meaningless (it would be testing a stuck
        // state, not a re-entry regression).
        assertLastRowAtVisibleBottom(
            controller: sessionA.controller,
            label: "cold A baseline")

        // Switch to B: SwiftUI's `.id(sid)` modifier tears down A's
        // NSView tree (calls `dismantleNSView`) and mounts B's. A's
        // controller stays alive on `Session`.
        nav.sid = sidBLocal
        waitUntilLoaded(session: sessionB)
        drainMainRunLoop(seconds: 0.4)

        // Switch back to A — this is the path the bug fires on. A's
        // history is already `.loaded`; only `scrollToBottom()` runs.
        nav.sid = sidA
        drainMainRunLoop(seconds: 0.6)

        assertLastRowAtVisibleBottom(
            controller: sessionA.controller,
            label: "re-entry into A")
    }

    /// First-screen load is two-phase by design: Phase 1 sync-applies a
    /// viewport-covering slice (`controller.apply`, `.bottom` scroll),
    /// then Phase 2 off-main precomputes the rest and lands it in a
    /// single main hop under `.saveVisible(.visualBottom)`. The
    /// performance contract is that the user sees correct content the
    /// moment Phase 1 returns — Phase 2 is purely a fill-in that must
    /// not disturb visible geometry.
    ///
    /// Captures three states:
    ///
    /// 1. *Phase 1 boundary*. Hooked through `session.onMessagesChange`,
    ///    which `wireRuntimeMessagesSink` fires *after* the bridge has
    ///    consumed the same `.reset` event. By that point
    ///    `bridge.applyReset` has called `controller.loadInitial`, which
    ///    ran Phase 1 sync and dispatched Phase 2 as a detached task.
    ///    The detached task's `MainActor.run` hop is queued on the main
    ///    runloop but cannot execute until our listener returns control —
    ///    so this is the deterministic "Phase 1 applied, Phase 2 not yet
    ///    landed" window.
    ///
    /// 2. *Phase 2 settled*. After waiting for `historyLoadState ==
    ///    .loaded` (covers both Phase 2 and the separate history Phase
    ///    B prepend) and draining the runloop.
    ///
    /// Assertions:
    ///
    /// - Phase 1: a viewport-sized prefix of blocks is in the
    ///   coordinator, document height matches that prefix only, and the
    ///   last row sits at the visible-content-area bottom.
    /// - Phase 2: every block is in, the last block id from Phase 1 is
    ///   still the last block, the last row still sits at the visible
    ///   bottom (i.e. `.saveVisible(.visualBottom)` honored the
    ///   anchor), and the document height has grown to the full
    ///   transcript size.
    func testPhase1ContentImmediateAndPhase2NoDisturbance() throws {
        let session = manager.prepareDraftSession(sidA)

        // Bypass `ChatHistoryView` — its `.task` would race us by calling
        // `s.loadHistory()` (no override) the moment the view mounts,
        // flipping `historyLoadState` past `.notLoaded` and locking out
        // the fixture-pointing `loadHistory(overrideURL:)` we want to
        // exercise. This test still goes through the production NSView
        // representable (`NativeTranscript2View`), so `makeNSView` /
        // `setDocumentView` / `frameDidChange` / `onLayoutReady` all run
        // for real — we just don't want the auto-load.
        let transcriptHost = mountTranscriptOnly(controller: session.controller)
        defer { teardownHost(transcriptHost) }
        // Settle the view tree so the table has a real width and
        // viewport — `loadInitial`'s phase-split branch needs both.
        drainMainRunLoop(seconds: 0.3)
        XCTAssertGreaterThan(
            session.controller.coordinator.layoutWidth, 0,
            "view must be tiled before reset fires; otherwise loadInitial "
                + "takes the deferred branch and there are no phases to test")

        // Capture Phase 1 boundary via the external-observer hook on
        // `Session.onMessagesChange`. `wireRuntimeMessagesSink` calls
        // `bridge.apply(change)` first (which routes `.reset` through
        // `loadInitial`'s phase 1) and then `session.onMessagesChange?(change)`
        // — so by the time this closure runs, phase 1 is on the table
        // and phase 2's main hop is queued but blocked behind us.
        var phase1: PhaseSnapshot?
        session.onMessagesChange = { [weak session] change in
            guard case .reset = change, phase1 == nil else { return }
            guard let coord = session?.controller.coordinator,
                let table = coord.tableView,
                let scroll = table.enclosingScrollView,
                !coord.blockIds.isEmpty
            else { return }
            let lastRow = coord.blockIds.count - 1
            phase1 = PhaseSnapshot(
                blockCount: coord.blockIds.count,
                lastBlockId: coord.blockIds[lastRow],
                lastRowMaxY: table.rect(ofRow: lastRow).maxY,
                visibleBottomInClip: scroll.contentView.bounds.maxY
                    - scroll.contentInsets.bottom,
                documentHeight: table.frame.height)
        }

        session.loadHistory(overrideURL: fixtureA.url, tailTarget: 80)

        let captured = runLoopUntil(timeout: 10) { phase1 != nil }
        XCTAssertTrue(captured, "phase 1 snapshot was never taken")
        guard let p1 = phase1 else { return }

        // ── Phase 1 assertions ─────────────────────────────────────
        XCTAssertGreaterThan(
            p1.blockCount, 0,
            "phase 1 should have inserted the viewport-covering slice")
        XCTAssertLessThan(
            p1.blockCount, fixtureA.entryCount,
            "phase 2's main hop must not have run yet — if blockCount equals "
                + "the full entry count, the test's phase-1 capture window "
                + "is bogus")
        XCTAssertEqual(
            p1.lastRowMaxY, p1.visibleBottomInClip,
            accuracy: 8.0,
            "phase 1's `.bottom` scroll must already anchor the last row "
                + "to the visible-content-area bottom — that's the whole "
                + "point of the viewport-first ordering")
        // Document height at Phase 1 is the viewport slice only — orders
        // of magnitude smaller than the full transcript. The exact value
        // depends on row heights; pin a loose ceiling that's still well
        // below the full transcript's ~47kpt.
        XCTAssertLessThan(
            p1.documentHeight, 5_000,
            "phase 1's documentView should span only the viewport slice, "
                + "not the full transcript (\(p1.documentHeight)pt)")

        // ── Phase 2 + history Phase B settle ──────────────────────
        waitUntilLoaded(session: session)
        drainMainRunLoop(seconds: 0.5)

        // ── Phase 2 assertions ────────────────────────────────────
        let coord = session.controller.coordinator
        guard let table = coord.tableView,
            let scroll = table.enclosingScrollView
        else {
            XCTFail("table or scroll view missing after phase 2")
            return
        }
        XCTAssertEqual(
            coord.blockIds.count, fixtureA.entryCount,
            "phase 2 + history phase B must bring in every block")
        XCTAssertEqual(
            coord.blockIds.last, p1.lastBlockId,
            "the last block id from phase 1 must still be the last block "
                + "after phase 2 — phase 2 only prepends, never appends, "
                + "to a `.bottom`-anchored cold load")
        let lastRow = coord.blockIds.count - 1
        let lastRectAfter = table.rect(ofRow: lastRow)
        let visibleBottomAfter =
            scroll.contentView.bounds.maxY - scroll.contentInsets.bottom
        XCTAssertEqual(
            lastRectAfter.maxY, visibleBottomAfter,
            accuracy: 8.0,
            "phase 2's `.saveVisible(.visualBottom)` must keep the last row "
                + "pinned to the visible-content-area bottom — anything else "
                + "is a visible jump")
        // Document grew to full transcript — confirms phase 2 actually
        // prepended every block, not a degenerate no-op that would also
        // satisfy the "last row stable" check above.
        XCTAssertGreaterThan(
            table.frame.height, p1.documentHeight * 3,
            "documentView height after phase 2 (\(table.frame.height)pt) "
                + "should be much larger than at phase 1 (\(p1.documentHeight)pt) "
                + "— same-height would mean phase 2 didn't actually prepend")
    }

    private struct PhaseSnapshot {
        let blockCount: Int
        let lastBlockId: UUID
        let lastRowMaxY: CGFloat
        let visibleBottomInClip: CGFloat
        let documentHeight: CGFloat
    }

    // MARK: - Mount

    /// Mount a `ChatHistoryView` in an offscreen hosting controller +
    /// window. Returns the controller so the test can keep it alive
    /// across the run-loop drain and tear it down explicitly.
    private func mountChatHistory(sessionId: String) -> NSHostingController<TestRoot> {
        let nav = TestNavBox(sid: sessionId)
        return mountChatHistory(navBox: nav)
    }

    /// Mount the production `NativeTranscript2View` directly against a
    /// supplied controller — no `ChatHistoryView`, no auto-`loadHistory`.
    /// For tests that need to drive `loadHistory(overrideURL:)`
    /// themselves and capture intermediate states the auto-load path
    /// would race past.
    private func mountTranscriptOnly(
        controller: Transcript2Controller
    ) -> NSHostingController<TranscriptOnlyRoot> {
        let root = TranscriptOnlyRoot(
            controller: controller,
            syntaxEngine: SyntaxHighlightEngine())
        let host = NSHostingController(rootView: root)
        host.view.frame = CGRect(origin: .zero, size: Self.viewSize)
        let window = NSWindow(
            contentRect: CGRect(
                origin: CGPoint(x: -30_000, y: -30_000),
                size: Self.viewSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0.01
        window.contentViewController = host
        window.ccterm_orderFrontForTesting()
        host.view.layoutSubtreeIfNeeded()
        host.testWindow = window
        return host
    }

    private func teardownHost<R: View>(_ host: NSHostingController<R>) {
        host.testWindow?.contentViewController = nil
        host.testWindow?.close()
        host.testWindow = nil
    }

    private func mountChatHistory(navBox: TestNavBox) -> NSHostingController<TestRoot> {
        let root = TestRoot(
            nav: navBox,
            manager: manager,
            searchBus: TranscriptSearchBus(),
            syntaxEngine: SyntaxHighlightEngine())
        let controller = NSHostingController(rootView: root)
        controller.view.frame = CGRect(origin: .zero, size: Self.viewSize)

        let window = NSWindow(
            contentRect: CGRect(
                origin: CGPoint(x: -30_000, y: -30_000),
                size: Self.viewSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0.01
        window.contentViewController = controller
        window.ccterm_orderFrontForTesting()
        controller.view.layoutSubtreeIfNeeded()
        // Hang the window off the controller so the defer in the test
        // method tears down both together. NSHostingController has no
        // built-in window field, so use objc associated storage via an
        // extension below.
        controller.testWindow = window
        return controller
    }

    // MARK: - Wait helpers

    /// Block until `historyLoadState == .loaded` (Phase B done) or
    /// `timeout` elapses. Drives `RunLoop.main.run` rather than
    /// `Task.sleep` so MainActor hops scheduled by `loadHistory`'s
    /// detached task actually execute.
    private func waitUntilLoaded(
        session: Session,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let arrived = runLoopUntil(timeout: timeout) {
            if case .loaded = session.historyLoadState { return true }
            return false
        }
        XCTAssertTrue(
            arrived,
            "historyLoadState never reached .loaded "
                + "(stuck at \(session.historyLoadState))",
            file: file, line: line)
    }

    /// Drain the main run loop for `seconds`. Used after a load
    /// completes to give AppKit's view-install pipeline
    /// (`setDocumentView`, `frameDidChange` notification dispatch,
    /// deferred `onLayoutReady` consumers) time to settle.
    private func drainMainRunLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func runLoopUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }

    // MARK: - Assertion

    /// Pin the last block's `maxY` to the scroll view's visible-content-area
    /// bottom. `Coordinator.scrollRowToBottom` aligns the last row's
    /// `maxY` to `clip.bounds.maxY - contentInsets.bottom`; both bugs
    /// under test leave that delta on the order of the document
    /// height, far outside the 8pt slack below.
    private func assertLastRowAtVisibleBottom(
        controller: Transcript2Controller,
        label: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let table = controller.coordinator.tableView else {
            XCTFail(
                "\(label): coordinator has no tableView (NSView never mounted)",
                file: file, line: line)
            return
        }
        guard let scroll = table.enclosingScrollView else {
            XCTFail(
                "\(label): tableView has no enclosingScrollView",
                file: file, line: line)
            return
        }
        let rowCount = table.numberOfRows
        XCTAssertGreaterThan(
            rowCount, 0,
            "\(label): table is empty",
            file: file, line: line)

        let lastRow = rowCount - 1
        let lastRect = table.rect(ofRow: lastRow)
        let clip = scroll.contentView
        let visibleBottomInClip = clip.bounds.maxY - scroll.contentInsets.bottom

        // 8pt slack: row-height rounding plus a tolerance for the
        // half-pixel `>0.5` threshold inside `applyAnchor`. The actual
        // delta on the buggy paths is the document height minus one
        // viewport — orders of magnitude larger than this slack.
        XCTAssertEqual(
            lastRect.maxY, visibleBottomInClip,
            accuracy: 8.0,
            "\(label): last row's maxY=\(lastRect.maxY) "
                + "does not align with visible bottom=\(visibleBottomInClip). "
                + "documentView.frame=\(table.frame), "
                + "clip.bounds=\(clip.bounds), "
                + "contentInsets.bottom=\(scroll.contentInsets.bottom)",
            file: file, line: line)
    }
}

// MARK: - Test view tree

/// Test root view. Owns the `sid` switch (via `TestNavBox`) so the
/// test can drive re-entry by mutating `nav.sid`. Mirrors the
/// environment that `RootView2` injects in production — `SessionManager`
/// for `prepareDraftSession`, `TranscriptSearchBus` for ⌘F focus
/// routing, and `\.syntaxEngine` for the code-block highlight engine.
struct TestRoot: View {
    var nav: TestNavBox
    let manager: SessionManager
    let searchBus: TranscriptSearchBus
    let syntaxEngine: SyntaxHighlightEngine

    var body: some View {
        ChatHistoryView(sessionId: nav.sid)
            .id(nav.sid)
            .environment(manager)
            .environment(searchBus)
            .environment(\.syntaxEngine, syntaxEngine)
    }
}

@Observable
@MainActor
final class TestNavBox {
    var sid: String
    init(sid: String) { self.sid = sid }
    nonisolated deinit {}
}

/// Minimal SwiftUI root that mounts the production
/// `NativeTranscript2View` against a caller-supplied controller. No
/// `.task` body, no environment side effects — exists so tests can
/// observe a `Transcript2Controller`'s reaction to `loadHistory`
/// without `ChatHistoryView`'s auto-kick racing the test setup.
struct TranscriptOnlyRoot: View {
    let controller: Transcript2Controller
    let syntaxEngine: SyntaxHighlightEngine

    var body: some View {
        NativeTranscript2View(controller: controller)
            .environment(\.syntaxEngine, syntaxEngine)
    }
}

// MARK: - Associated-storage seam for the offscreen window

private var testWindowKey: UInt8 = 0

extension NSHostingController {
    fileprivate var testWindow: NSWindow? {
        get { objc_getAssociatedObject(self, &testWindowKey) as? NSWindow }
        set {
            objc_setAssociatedObject(
                self, &testWindowKey, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

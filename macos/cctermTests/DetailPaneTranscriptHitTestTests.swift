import AgentSDK
import AppKit
import Observation
import SwiftUI
import XCTest

@testable import ccterm

/// Gate for the "can't select the transcript after a fast sidebar
/// switch" report. It mounts the production detail pane
/// (`DetailRouterViewController`) in an offscreen window, drives session
/// switches through the model (the same writes the sidebar makes), and
/// **synthesises the actual selection gesture**: a triple-click
/// `mouseDown` routed through the real `hitTest` path. Triple-click takes
/// the `selectUnit` branch in `Transcript2TableView.mouseDown`, which
/// selects synchronously without entering the drag event loop — so the
/// outcome ("did text get selected") is observable offscreen as
/// `coordinator.selection.isEmpty`.
///
/// What it asserts: across session↔session switches the transcript stays
/// (a) hit-test reachable (clicks resolve to `BlockCellView`, not to an
/// overlay) and (b) selectable (the gesture populates the selection).
///
/// What it has established: the reported bug does **NOT** reproduce here.
/// Both invariants hold in steady state and after rapid switching. That
/// refutes the "a full-bleed overlay covers the transcript" hypothesis
/// the earlier bottom-anchor fix (3828e51) was built on. Whatever remains
/// lives in machinery this headless harness can't exercise — live
/// key-window event delivery (`NSTrackingArea` hover is `.activeInKeyWindow`;
/// selection-highlight color is key-window-gated) and the
/// `NSApp.nextEvent(inMode:.eventTracking)` drag-select loop — none of
/// which fire without a real key window + hardware mouse stream. Kept as
/// a regression gate so a future change that DOES break hit-test
/// reachability or selection wiring trips here.
///
/// ## Fixture invariant — arm the observation BEFORE the first switch
///
/// The router/VC observe `model.selection` via a one-shot
/// `withObservationTracking` Task created in `viewDidLoad`. That Task only
/// starts tracking once the MainActor executor runs it. So the FIRST
/// selection must be set BEFORE the view loads (so `viewDidLoad`'s
/// synchronous `installChildForCurrentSelection` mounts it directly), and
/// every subsequent flip must be followed by enough `Task.sleep` +
/// runloop draining for the observation hop to fire. Skip this and the
/// flip goes untracked, no child mounts, and the harness reports a false
/// "dead selection" that's really just an un-armed observer.
@MainActor
final class DetailPaneTranscriptHitTestTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let windowSize = CGSize(width: 1000, height: 800)
    private static let blockCount = 60

    private func makeBlocks() -> [Block] {
        (0..<Self.blockCount).map { i in
            Block(
                id: UUID(),
                kind: .paragraph(inlines: [
                    .text(
                        "line \(i): the rain in spain falls mainly on the plain, "
                            + "and the quick brown fox jumps over the lazy dog.")
                ]))
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        let router: DetailRouterViewController
        let model: MainSelectionModel
        let container: NSView
        let window: NSWindow
        let sessionIds: [String]
    }

    /// `initialSessionIndex` selects which session is shown at mount.
    /// It is set on the model BEFORE the view loads, so `viewDidLoad`'s
    /// synchronous `handleSelectionChanged` attaches it directly — the
    /// only reliable way to arm the first attach without racing the
    /// async observation hop (see the fixture-invariant note above).
    private func makeFixture(sessionCount: Int, initialSessionIndex: Int?) -> Fixture {
        let repo = InMemorySessionRepository()
        var ids: [String] = []
        for i in 0..<sessionCount {
            let sid = UUID().uuidString
            ids.append(sid)
            repo.save(
                SessionRecord(
                    sessionId: sid, title: "S\(i)", cwd: "/tmp/s\(i)", status: .created))
        }
        let manager = SessionManager(
            repository: repo,
            cliClientFactory: { _ in FakeCLIClient() })
        for sid in ids {
            manager.session(sid)?.controller.apply(.append(makeBlocks()))
        }
        let initialSelection: MainSelection =
            initialSessionIndex.map { .session(ids[$0]) } ?? .none

        let suite = "ccterm-hittest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let recentProjects = RecentProjectsStore(defaults: defaults)
        let activation = AppActivationTracker()
        let notifications = NotificationService(activation: activation)
        let syntaxEngine = SyntaxHighlightEngine()
        let searchBus = TranscriptSearchBus()
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-hittest-\(UUID().uuidString)", isDirectory: true)
        let inputDraftStore = InputDraftStore(directory: draftDir, debounceInterval: 0.05)

        let model = MainSelectionModel()
        // Arm BEFORE mount — viewDidLoad installs this selection directly.
        model.selection = initialSelection

        let router = DetailRouterViewController(
            model: model,
            sessionManager: manager,
            recentProjects: recentProjects,
            notifications: notifications,
            syntaxEngine: syntaxEngine,
            searchBus: searchBus,
            inputDraftStore: inputDraftStore)

        let window = NSWindow(
            contentRect: NSRect(
                origin: CGPoint(x: -30_000, y: -30_000), size: Self.windowSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01

        let container = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        window.contentView = container
        window.ccterm_orderFrontForTesting()

        router.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(router.view)
        NSLayoutConstraint.activate([
            router.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            router.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            router.view.topAnchor.constraint(equalTo: container.topAnchor),
            router.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()

        addTeardownBlock {
            window.contentView = nil
            window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: draftDir)
        }

        return Fixture(
            router: router, model: model, container: container,
            window: window, sessionIds: ids)
    }

    // MARK: - Helpers

    private func drainMainLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func settle(_ fx: Fixture, rounds: Int = 12) async {
        for _ in 0..<rounds {
            try? await Task.sleep(for: .milliseconds(40))
            drainMainLoop(seconds: 0.02)
        }
        fx.container.layoutSubtreeIfNeeded()
    }

    private func findSubview<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let found = findSubview(type, in: sub) { return found }
        }
        return nil
    }

    /// Walk up from `view` to the enclosing `permissionCardHost`
    /// (`PassthroughHostingView`), or nil if the hit landed outside it.
    private func enclosingPassthroughHost(_ view: NSView?) -> PassthroughHostingView? {
        var node = view
        while let cur = node {
            if let host = cur as? PassthroughHostingView { return host }
            node = cur.superview
        }
        return nil
    }

    /// Seed a pending permission onto the shown session's runtime, the same
    /// way the production CLI sink does (`pendingPermissions.append`). The
    /// `permissionCardHost`'s `PermissionCardOverlay` observes
    /// `session.pendingPermissions`, so after a runloop drain the card
    /// subtree mounts inside the passthrough host.
    @discardableResult
    private func seedPermission(_ fx: Fixture, sessionId: String, requestId: String) -> Bool {
        guard let session = fx.router.sessionManager.session(sessionId),
            case .active(let runtime) = session.phase
        else { return false }
        let request = PermissionRequest.makePreview(
            requestId: requestId, toolName: "Bash", input: ["command": "rm -rf build"])
        runtime.pendingPermissions.append(
            PendingPermission(id: requestId, request: request, respond: { _ in }))
        return true
    }

    private struct SelectionAttempt {
        let selected: Bool
        let diag: String
    }

    /// Synthesise the user's ACTUAL failing gesture — a left-button
    /// **drag** across text — on the currently-shown transcript, routed
    /// through the real `hitTest` path, and report whether any text ended
    /// up selected.
    ///
    /// A single-click drag takes the `trackSelection` branch in
    /// `Transcript2TableView.mouseDown`, which spins a private
    /// `NSApp.nextEvent(inMode: .eventTracking)` loop consuming
    /// `.leftMouseDragged` / `.leftMouseUp`. We pre-post those two events
    /// so the loop drains them synchronously (and always terminates on the
    /// `.leftMouseUp`), then drive the `.leftMouseDown` through hitTest.
    private func attemptSelection(_ fx: Fixture, label: String) -> SelectionAttempt {
        guard let chatVC = fx.router.currentChild as? ChatSessionViewController else {
            return SelectionAttempt(
                selected: false,
                diag: "[\(label)] currentChild=\(type(of: fx.router.currentChild as Any)) — not chat VC")
        }
        guard let table = findSubview(Transcript2TableView.self, in: chatVC.view) else {
            return SelectionAttempt(selected: false, diag: "[\(label)] no Transcript2TableView mounted")
        }
        let coord = table.coordinator
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else {
            return SelectionAttempt(
                selected: false,
                diag: "[\(label)] no visible rows; visibleRect=\(table.visibleRect) "
                    + "numberOfRows=\(table.numberOfRows)")
        }
        let row = visible.location + visible.length / 2
        let rowRect = table.rect(ofRow: row)
        let yMid = rowRect.midY
        let startInTable = CGPoint(x: rowRect.minX + 120, y: yMid)
        let endInTable = CGPoint(x: max(rowRect.minX + 200, rowRect.maxX - 120), y: yMid)
        let startWin = table.convert(startInTable, to: nil)
        let endWin = table.convert(endInTable, to: nil)

        func mk(_ type: NSEvent.EventType, _ loc: NSPoint, clicks: Int) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: loc, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: fx.window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clicks,
                pressure: type == .leftMouseUp ? 0.0 : 1.0)
        }
        guard let down = mk(.leftMouseDown, startWin, clicks: 1),
            let dragged = mk(.leftMouseDragged, endWin, clicks: 1),
            let up = mk(.leftMouseUp, endWin, clicks: 1)
        else {
            return SelectionAttempt(selected: false, diag: "[\(label)] could not synthesise events")
        }
        // Queue the drag + up so `trackSelection`'s eventTracking pull
        // drains them without blocking. `up` guarantees loop exit.
        NSApp.postEvent(dragged, atStart: false)
        NSApp.postEvent(up, atStart: false)

        let hit = fx.router.view.hitTest(startWin)
        let before = coord?.selection.isEmpty ?? true
        hit?.mouseDown(with: down)
        let after = coord?.selection.isEmpty ?? true

        // Draw side: did the actual VISIBLE cell receive the selection
        // (i.e. would it repaint the highlight)? The user's symptom is
        // "state selected but no highlight", so this is the dimension
        // that matters — `selection.isEmpty` alone (the dict) isn't.
        let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? BlockCellView
        let cellGotSelection = cell?.selection != nil
        // A drag that legitimately selected the dict entry but never
        // reached the visible cell == the reported "no highlight" bug.
        let highlightVisible = !after && cellGotSelection

        let diag = """
            [\(label)] kind=\(String(describing: fx.router.currentKind)) \
            tbl.coord=\(coord != nil) coord.tbl=\(coord?.tableView != nil) \
            coord.tbl===tbl=\(coord?.tableView === table) \
            rows=\(table.numberOfRows) visible=\(visible.length) row=\(row) \
            hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") \
            adapter(row)=\(coord?.selectionAdapter(atRow: row) != nil) \
            selBefore=\(before) selAfter=\(after) cellGotSel=\(cellGotSelection) \
            → highlightVisible=\(highlightVisible)
            """
        return SelectionAttempt(selected: highlightVisible, diag: diag)
    }

    // MARK: - Tests

    /// Baseline: with the observation armed before mount, a freshly
    /// attached session must be selectable. Proves the harness is sound.
    func testSelectsOnInitialSession() async throws {
        let fx = makeFixture(sessionCount: 3, initialSessionIndex: 0)
        await settle(fx)

        let attempt = attemptSelection(fx, label: "initial")
        add(attachment(attempt.diag, "initial-attach"))
        XCTAssertTrue(attempt.selected, "Baseline broke:\n\(attempt.diag)")
    }

    /// The repro. Switch between normal sessions, and after each switch
    /// probe selection at INCREASING delays (0 → many runloop turns). The
    /// "fast sidebar switch → can't select" bug is a window after the
    /// switch where the gesture lands but selection is dead. We assert
    /// that by the time the attach pipeline has had a fair chance to
    /// settle (a handful of turns), selection works — and we record the
    /// full delay→selectable timeline so a regression in how long the
    /// dead window lasts is visible in the attachment.
    func testSelectsPromptlyAfterSessionSwitch() async throws {
        let fx2 = makeFixture(sessionCount: 3, initialSessionIndex: 0)
        await settle(fx2)

        var report: [String] = []
        var anyPersistentDead = false

        for switchIdx in 0..<5 {
            let target = fx2.sessionIds[(switchIdx + 1) % 3]
            // Route through `select(_:)` so the router (the sole
            // structural observer) runs the switch synchronously.
            fx2.model.select(.session(target))

            // Probe at increasing delays: capture how long, if at all,
            // selection stays dead right after the switch.
            var timeline: [(turn: Int, selected: Bool)] = []
            var diagAtEnd = ""
            for turn in 0..<10 {
                let a = attemptSelection(fx2, label: "switch#\(switchIdx) turn=\(turn)")
                timeline.append((turn, a.selected))
                diagAtEnd = a.diag
                try? await Task.sleep(for: .milliseconds(20))
                drainMainLoop(seconds: 0.01)
            }
            // After a fair settle the session MUST be selectable.
            await settle(fx2, rounds: 6)
            let settled = attemptSelection(fx2, label: "switch#\(switchIdx) settled")
            if !settled.selected { anyPersistentDead = true }

            let line =
                "switch#\(switchIdx)→\(target.prefix(4)): "
                + timeline.map { "\($0.turn):\($0.selected ? "Y" : "n")" }.joined(separator: " ")
                + "  | settled=\(settled.selected)\n      lastTurnDiag: \(diagAtEnd)\n      settledDiag: \(settled.diag)"
            report.append(line)
        }

        add(attachment(report.joined(separator: "\n\n"), "switch selection timeline"))
        XCTAssertFalse(
            anyPersistentDead,
            "Transcript selection stayed dead even after settling post-switch:\n\n"
                + report.joined(separator: "\n\n"))
    }

    /// PR5 passthrough regression net. With a permission card mounted in
    /// the full-pane `permissionCardHost` (`PassthroughHostingView`), the
    /// card must NOT swallow transcript clicks: a point in the open
    /// transcript band still hit-tests to a `BlockCellView` (transcript
    /// selectable — M4/M5: the full-pane host doesn't occlude the table),
    /// while a point inside the floating card resolves into the
    /// passthrough host (the card's buttons stay clickable).
    func testPermissionCardPassesTranscriptClicksThrough() async throws {
        let fx = makeFixture(sessionCount: 1, initialSessionIndex: 0)
        await settle(fx)

        // Seed the permission, then drain so `PermissionCardOverlay`
        // (observing `session.pendingPermissions`) mounts the card subtree
        // inside the passthrough host.
        XCTAssertTrue(
            seedPermission(fx, sessionId: fx.sessionIds[0], requestId: "perm-hit"),
            "could not seed a pending permission on the shown session")
        await settle(fx, rounds: 8)

        guard let chatVC = fx.router.currentChild as? ChatSessionViewController else {
            XCTFail("currentChild is not a ChatSessionViewController")
            return
        }
        guard let host = chatVC.permissionCardHost else {
            XCTFail("permissionCardHost is nil")
            return
        }
        guard let table = findSubview(Transcript2TableView.self, in: chatVC.view) else {
            XCTFail("no Transcript2TableView mounted")
            return
        }

        // The card mounted: probe a grid of points across the host for the
        // first one whose `hitTest` lands on a card subview
        // (PassthroughHostingView maps non-card points to nil). Scan the full
        // height so the search is independent of the host's flipped-ness —
        // the card sits at one vertical extreme (bottom-pinned) either way.
        // `NSView.hitTest` takes a point in the receiver's SUPERVIEW coords,
        // so each candidate (built in host bounds) is converted up to the
        // host's superview before probing, and we record the window point so
        // the real router-level hitTest can be replayed below.
        guard let hostSuper = host.superview else {
            XCTFail("permissionCardHost has no superview")
            return
        }
        let hostBounds = host.bounds
        var cardPointInWindow: NSPoint?
        let xs = stride(from: hostBounds.midX - 200, through: hostBounds.midX + 200, by: 40)
        let ys = stride(from: hostBounds.minY + 8, through: hostBounds.maxY - 8, by: 12)
        outer: for y in ys {
            for x in xs {
                let pInHost = NSPoint(x: x, y: y)
                let pInSuper = host.convert(pInHost, to: hostSuper)
                if let hit = host.hitTest(pInSuper), enclosingPassthroughHost(hit) === host {
                    cardPointInWindow = host.convert(pInHost, to: nil)
                    break outer
                }
            }
        }
        XCTAssertNotNil(
            cardPointInWindow,
            "permission card never became hit-eligible inside the passthrough host")

        // (a) Outside the card → through to the transcript. Pick a point in
        // the middle of a visible row, well above the bottom card band.
        let visible = table.rows(in: table.visibleRect)
        XCTAssertGreaterThan(visible.length, 0, "no visible transcript rows")
        let row = visible.location + visible.length / 2
        let rowRect = table.rect(ofRow: row)
        let transcriptPointInTable = CGPoint(x: rowRect.minX + 120, y: rowRect.midY)
        let transcriptPointInWindow = table.convert(transcriptPointInTable, to: nil)
        let transcriptHit = fx.router.view.hitTest(transcriptPointInWindow)
        let resolvedToCell = findEnclosing(BlockCellView.self, transcriptHit) != nil
        let leakedToCard = enclosingPassthroughHost(transcriptHit) != nil

        // (b) Inside the card → the passthrough host (buttons clickable).
        var cardHit: NSView?
        if let cardPointInWindow {
            cardHit = fx.router.view.hitTest(cardPointInWindow)
        }
        let resolvedToCard = enclosingPassthroughHost(cardHit) != nil

        let diag = """
            host.bounds=\(hostBounds) \
            cardPointInWindow=\(String(describing: cardPointInWindow)) \
            transcriptHit=\(transcriptHit.map { String(describing: type(of: $0)) } ?? "nil") \
            resolvedToCell=\(resolvedToCell) leakedToCard=\(leakedToCard) \
            cardHit=\(cardHit.map { String(describing: type(of: $0)) } ?? "nil") \
            resolvedToCard=\(resolvedToCard)
            """
        add(attachment(diag, "permission-card passthrough"))

        XCTAssertFalse(
            leakedToCard,
            "transcript-band click leaked into the permission card host:\n\(diag)")
        XCTAssertTrue(
            resolvedToCell,
            "transcript-band click did not reach a BlockCellView:\n\(diag)")
        XCTAssertTrue(
            resolvedToCard,
            "in-card click did not resolve to the passthrough host:\n\(diag)")
    }

    /// Walk up from `view` to the first enclosing `T`, or nil.
    private func findEnclosing<T: NSView>(_ type: T.Type, _ view: NSView?) -> T? {
        var node = view
        while let cur = node {
            if let match = cur as? T { return match }
            node = cur.superview
        }
        return nil
    }

    private func attachment(_ s: String, _ name: String) -> XCTAttachment {
        let a = XCTAttachment(string: s)
        a.name = name
        a.lifetime = .keepAlways
        return a
    }
}

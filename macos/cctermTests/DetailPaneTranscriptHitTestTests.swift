import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Gate for the "can't select the transcript after a fast sidebar
/// switch" report — **migrated onto the `AppKitStage` harness**. The
/// original (pre-harness) version of this file hand-rolled ~160 lines of
/// fixture: an offscreen window, a seeded `SessionManager`, isolated
/// `UserDefaults` / draft-dir, the `DetailRouterViewController` wiring,
/// recursive subview search, synthesized `NSEvent`s, and a `Task.sleep` +
/// `RunLoop.run` settle loop. All of that is now `AppKitStage.detailRouter`
/// + `InteractionDriver` + `stage.settle()`, so this file is just the
/// scenario.
///
/// It mounts the production detail pane (`DetailRouterViewController`) over
/// a real seeded `SessionManager`, drives session switches through the
/// model (the same writes the sidebar makes), and **synthesises the actual
/// failing gesture** — a left-button drag across text, routed through the
/// real `hitTest` → `mouseDown` path.
///
/// What it asserts: across session↔session switches the transcript stays
/// (a) hit-test reachable (clicks resolve to `BlockCellView`, not an
/// overlay) and (b) selectable (the gesture populates the selection).
///
/// What it has established: the reported bug does **NOT** reproduce here.
/// Both invariants hold in steady state and after rapid switching. That
/// refutes the "a full-bleed overlay covers the transcript" hypothesis.
/// Whatever remains lives in machinery this headless harness can't
/// exercise — live key-window event delivery (`NSTrackingArea` hover is
/// `.activeInKeyWindow`; selection-highlight color is key-window-gated) and
/// the real `NSApp.nextEvent(.eventTracking)` drag loop. Kept as a
/// regression gate so a future change that DOES break hit-test reachability
/// or selection wiring trips here.
///
/// ## Fixture invariant — the initial selection is set before mount
///
/// `AppKitStage.detailRouter(initialIndex:)` sets `model.selection` before
/// the router's view loads, so `viewDidLoad`'s synchronous
/// `installChildForCurrentSelection` mounts it directly. Every subsequent
/// flip goes through `model.select(_:)` (the structural observer runs it
/// synchronously) followed by `stage.settle()` for the attach pipeline to
/// land.
@MainActor
final class DetailPaneTranscriptHitTestTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let windowSize = CGSize(width: 1000, height: 800)
    private static let sessionCount = 3

    /// Build N sessions, each with a paragraph-heavy transcript (the
    /// harness default) so there are real selectable rows.
    private func makeSessions() -> [AppKitStage.SessionSpec] {
        (0..<Self.sessionCount).map { AppKitStage.SessionSpec(title: "S\($0)") }
    }

    // MARK: - Permission seeding

    /// Seed a pending permission onto the shown session's runtime, the same
    /// way the production CLI sink does (`pendingPermissions.append`). The
    /// `permissionCardHost`'s `PermissionCardOverlay` observes
    /// `session.pendingPermissions`, so after a settle the card subtree
    /// mounts inside the passthrough host.
    @discardableResult
    private func seedPermission(
        _ fx: AppKitStage.Fixture, sessionId: String, requestId: String
    ) -> Bool {
        guard let session = fx.sessionManager.session(sessionId),
            case .active(let runtime) = session.phase
        else { return false }
        let request = PermissionRequest.makePreview(
            requestId: requestId, toolName: "Bash", input: ["command": "rm -rf build"])
        runtime.pendingPermissions.append(
            PendingPermission(id: requestId, request: request, respond: { _ in }))
        return true
    }

    private func attachment(_ s: String, _ name: String) -> XCTAttachment {
        let a = XCTAttachment(string: s)
        a.name = name
        a.lifetime = .keepAlways
        return a
    }

    /// The visible transcript table in the currently-mounted chat VC, or nil.
    private func visibleTable(_ fx: AppKitStage.Fixture) -> Transcript2TableView? {
        guard fx.stage.router?.currentChild is ChatSessionViewController else { return nil }
        return fx.stage.find(Transcript2TableView.self)
    }

    // MARK: - Tests

    /// Baseline: with the selection armed before mount, a freshly attached
    /// session must be selectable. Proves the harness is sound.
    func testSelectsOnInitialSession() async throws {
        let fx = AppKitStage.detailRouter(
            sessions: makeSessions(), initialIndex: 0, size: Self.windowSize)
        defer { fx.teardown() }
        await fx.stage.settle()

        guard let table = visibleTable(fx) else {
            XCTFail("no transcript table mounted on initial session")
            return
        }
        let outcome = fx.stage.driver.dragSelectVisibleRow(in: table)
        add(attachment(outcome?.diagnostic ?? "nil", "initial-attach"))
        XCTAssertTrue(
            outcome?.cellHighlighted ?? false,
            "Baseline broke:\n\(outcome?.diagnostic ?? "nil")")
    }

    /// The repro. Switch between normal sessions and, after each switch,
    /// probe selection at increasing delays. The "fast sidebar switch →
    /// can't select" bug is a window after the switch where the gesture
    /// lands but selection is dead. We assert that after a fair settle the
    /// session is selectable, and record the full timeline so a regression
    /// in how long the dead window lasts is visible in the attachment.
    func testSelectsPromptlyAfterSessionSwitch() async throws {
        let fx = AppKitStage.detailRouter(
            sessions: makeSessions(), initialIndex: 0, size: Self.windowSize)
        defer { fx.teardown() }
        await fx.stage.settle()

        var report: [String] = []
        var anyPersistentDead = false

        for switchIdx in 0..<5 {
            let target = fx.sessionIds[(switchIdx + 1) % Self.sessionCount]
            // Route through `select(_:)` so the router (the sole structural
            // observer) runs the switch synchronously.
            fx.model.select(.session(target))

            var timeline: [(turn: Int, selected: Bool)] = []
            var lastDiag = ""
            for turn in 0..<10 {
                if let table = visibleTable(fx),
                    let outcome = fx.stage.driver.dragSelectVisibleRow(in: table)
                {
                    timeline.append((turn, outcome.cellHighlighted))
                    lastDiag = outcome.diagnostic
                } else {
                    timeline.append((turn, false))
                    lastDiag = "no table at turn \(turn)"
                }
                try? await Task.sleep(for: .milliseconds(20))
                fx.stage.drain(seconds: 0.01)
            }

            await fx.stage.settle(rounds: 6)
            let settledOutcome = visibleTable(fx).flatMap {
                fx.stage.driver.dragSelectVisibleRow(in: $0)
            }
            let settled = settledOutcome?.cellHighlighted ?? false
            if !settled { anyPersistentDead = true }

            report.append(
                "switch#\(switchIdx)→\(target.prefix(4)): "
                    + timeline.map { "\($0.turn):\($0.selected ? "Y" : "n")" }
                    .joined(separator: " ")
                    + "  | settled=\(settled)\n      lastTurnDiag: \(lastDiag)"
                    + "\n      settledDiag: \(settledOutcome?.diagnostic ?? "nil")")
        }

        add(attachment(report.joined(separator: "\n\n"), "switch selection timeline"))
        XCTAssertFalse(
            anyPersistentDead,
            "Transcript selection stayed dead even after settling post-switch:\n\n"
                + report.joined(separator: "\n\n"))
    }

    /// Passthrough regression net. With a permission card mounted in the
    /// full-pane `permissionCardHost` (`PassthroughHostingView`), the card
    /// must NOT swallow transcript clicks: a point in the open transcript
    /// band still hit-tests to a `BlockCellView` (transcript selectable —
    /// the full-pane host doesn't occlude the table), while a point inside
    /// the floating card resolves into the passthrough host (the card's
    /// buttons stay clickable).
    func testPermissionCardPassesTranscriptClicksThrough() async throws {
        let fx = AppKitStage.detailRouter(
            sessions: [AppKitStage.SessionSpec(title: "S0")],
            initialIndex: 0, size: Self.windowSize)
        defer { fx.teardown() }
        await fx.stage.settle()

        XCTAssertTrue(
            seedPermission(fx, sessionId: fx.sessionIds[0], requestId: "perm-hit"),
            "could not seed a pending permission on the shown session")
        await fx.stage.settle(rounds: 8)

        guard let chatVC = fx.stage.router?.currentChild as? ChatSessionViewController else {
            XCTFail("currentChild is not a ChatSessionViewController")
            return
        }
        guard let host = chatVC.permissionCardHost else {
            XCTFail("permissionCardHost is nil")
            return
        }
        guard let table = fx.stage.find(Transcript2TableView.self) else {
            XCTFail("no Transcript2TableView mounted")
            return
        }
        let driver = fx.stage.driver

        // Probe a grid of points across the host for the first one whose
        // `hitTest` lands on a card subview (PassthroughHostingView maps
        // non-card points to nil). Scan the full height so the search is
        // independent of the host's flipped-ness — the card sits at one
        // vertical extreme (bottom-pinned) either way.
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
                if let hit = host.hitTest(pInSuper),
                    driver.enclosing(PassthroughHostingView.self, of: hit) === host
                {
                    cardPointInWindow = host.convert(pInHost, to: nil)
                    break outer
                }
            }
        }
        XCTAssertNotNil(
            cardPointInWindow,
            "permission card never became hit-eligible inside the passthrough host")

        // (a) Outside the card → through to the transcript.
        let visible = table.rows(in: table.visibleRect)
        XCTAssertGreaterThan(visible.length, 0, "no visible transcript rows")
        let row = visible.location + visible.length / 2
        let rowRect = table.rect(ofRow: row)
        let transcriptPointInTable = CGPoint(x: rowRect.minX + 120, y: rowRect.midY)
        let transcriptHit = driver.hitTest(at: transcriptPointInTable, from: table)
        let resolvedToCell = driver.enclosing(BlockCellView.self, of: transcriptHit) != nil
        let leakedToCard = driver.enclosing(PassthroughHostingView.self, of: transcriptHit) != nil

        // (b) Inside the card → the passthrough host (buttons clickable).
        var cardHit: NSView?
        if let cardPointInWindow {
            cardHit = fx.stage.rootView.hitTest(cardPointInWindow)
        }
        let resolvedToCard = driver.enclosing(PassthroughHostingView.self, of: cardHit) != nil

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
}

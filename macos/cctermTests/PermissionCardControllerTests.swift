import AgentSDK
import AppKit
import Observation
import XCTest

@testable import ccterm

/// CI-gate tests for `PermissionCardController` driven through the REAL
/// production surface: `ChatSessionViewController.present(sessionId:)` (which
/// resolves the `Session` once and calls `permissionCardController.rebind(for:)`)
/// and the chat VC's `prepareForRemoval`. No test-only seams — the controller
/// is reached exactly as the router reaches it, and assertions read the
/// controller's read-only observation points (`currentCard`,
/// `currentBoundSession`, `currentMountedPendingId`).
///
/// Parallel-safe per `cctermTests/CLAUDE.md`: in-memory repository, fresh
/// manager, unique temp draft dir, suite-scoped `UserDefaults`, no `.shared` /
/// `NotificationCenter.default` / `sleep` — runloop drains + predicate waits.
@MainActor
final class PermissionCardControllerTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let windowSize = CGSize(width: 1000, height: 800)

    // MARK: - Fixture (real chat VC mounted in an offscreen window)

    private struct Fixture {
        let chatVC: ChatSessionViewController
        let manager: SessionManager
        let window: NSWindow
        let sessionIds: [String]
    }

    private func makeFixture(sessionCount: Int) -> Fixture {
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
            repository: repo, cliClientFactory: { _ in FakeCLIClient() })

        let suite = "ccterm-permcard-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let recentProjects = RecentProjectsStore(defaults: defaults)
        let syntaxEngine = SyntaxHighlightEngine()
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-permcard-\(UUID().uuidString)", isDirectory: true)
        let inputDraftStore = InputDraftStore(directory: draftDir, debounceInterval: 0.05)

        let model = MainSelectionModel()
        let context = DetailContext(
            model: model,
            sessionManager: manager,
            recentProjects: recentProjects,
            inputDraftStore: inputDraftStore,
            syntaxEngine: syntaxEngine)
        let chatVC = ChatSessionViewController(context: context)

        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: Self.windowSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01

        let container = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        window.contentView = container
        window.ccterm_orderFrontForTesting()

        chatVC.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chatVC.view)
        NSLayoutConstraint.activate([
            chatVC.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chatVC.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chatVC.view.topAnchor.constraint(equalTo: container.topAnchor),
            chatVC.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()

        addTeardownBlock {
            chatVC.prepareForRemoval()
            window.contentView = nil
            window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: draftDir)
        }

        return Fixture(chatVC: chatVC, manager: manager, window: window, sessionIds: ids)
    }

    // MARK: - Helpers

    private func drainMainLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    /// Drain until `predicate` is true or the deadline elapses.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 2.0, _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
            drainMainLoop(seconds: 0.01)
        }
        return predicate()
    }

    /// Append a pending permission directly onto the session's runtime — the
    /// same path the production CLI sink uses. Returns the `requestId`.
    @discardableResult
    private func seedPermission(
        _ session: ccterm.Session, requestId: String
    ) -> String {
        guard case .active(let runtime) = session.phase else {
            XCTFail("expected an active session to seed a permission")
            return requestId
        }
        let request = PermissionRequest.makePreview(
            requestId: requestId, toolName: "Bash", input: ["command": "rm -rf build"])
        runtime.pendingPermissions.append(
            PendingPermission(id: requestId, request: request, respond: { _ in }))
        return requestId
    }

    // MARK: - Tests

    /// Steady-state mount/dismiss: present a session, seed a pending
    /// permission → a card mounts; clear the pending → the card dismisses.
    func testCardMountsOnPendingAndDismissesWhenCleared() async throws {
        let fx = makeFixture(sessionCount: 1)
        fx.chatVC.present(sessionId: fx.sessionIds[0])
        let session = fx.manager.session(fx.sessionIds[0])!

        XCTAssertNil(
            fx.chatVC.permissionCardController.currentCard,
            "no card should mount before any pending permission")

        let reqId = seedPermission(session, requestId: "perm-mount")
        let mounted = await waitUntil {
            fx.chatVC.permissionCardController.currentCard != nil
        }
        XCTAssertTrue(mounted, "a card should mount when a permission is pending")
        XCTAssertEqual(
            fx.chatVC.permissionCardController.currentMountedPendingId, reqId,
            "the mounted card should be built for the seeded pending id")

        // Clear the pending → the card dismisses (the fade completes after the
        // observation wake; the card is removed in the animation completion).
        if case .active(let runtime) = session.phase {
            runtime.pendingPermissions.removeAll()
        }
        let dismissed = await waitUntil {
            fx.chatVC.permissionCardController.currentCard == nil
                && fx.chatVC.permissionCardHost.subviews.isEmpty
        }
        XCTAssertTrue(dismissed, "the card should dismiss when the pending permission clears")
    }

    /// MISSED-FIRST-EDGE (§4.4-3 stranded-card gate). Pre-seed a pending
    /// permission on the session BEFORE `present` arms the observation, then
    /// assert exactly one card mounts — the construction-time synchronous
    /// reconcile, not a stranded loop that suspends on the pending value and
    /// never wakes.
    func testConstructionTimeReconcileMountsAlreadyPendingCard() async throws {
        let fx = makeFixture(sessionCount: 1)
        let session = fx.manager.prepareDraftSession(fx.sessionIds[0])
        // Seed BEFORE present (the session is already pending when bound).
        seedPermission(session, requestId: "perm-pre-seeded")

        fx.chatVC.present(sessionId: fx.sessionIds[0])

        // The construction-time reconcile mounts the card synchronously inside
        // `present`, with NO observation wake — assert immediately (no drain).
        XCTAssertNotNil(
            fx.chatVC.permissionCardController.currentCard,
            "a session re-entered with an already-pending permission must mount "
                + "its card via the construction-time reconcile (§4.4-3)")
        XCTAssertEqual(
            fx.chatVC.permissionCardController.currentMountedPendingId, "perm-pre-seeded")
        XCTAssertEqual(
            fx.chatVC.permissionCardHost.subviews.count, 1,
            "exactly one card should mount, not zero (stranded) or many")
    }

    /// CROSS-SESSION SYNCHRONOUS TEARDOWN (§4.0). present(A pending) → card
    /// mounts → present(B, no pending) → A's card is gone SYNCHRONOUSLY (no
    /// animation tick) and `boundSession === B`.
    func testCrossSessionSwitchSynchronouslyDropsPriorCard() async throws {
        let fx = makeFixture(sessionCount: 2)
        let sessionA = fx.manager.prepareDraftSession(fx.sessionIds[0])
        seedPermission(sessionA, requestId: "perm-A")

        fx.chatVC.present(sessionId: fx.sessionIds[0])
        XCTAssertNotNil(
            fx.chatVC.permissionCardController.currentCard, "A's card should mount")

        // Switch to B (no pending). The cross-session dismiss is SYNCHRONOUS —
        // assert immediately, no drain.
        fx.chatVC.present(sessionId: fx.sessionIds[1])
        XCTAssertNil(
            fx.chatVC.permissionCardController.currentCard,
            "A's card must be gone synchronously on cross-session switch (§4.0)")
        XCTAssertTrue(
            fx.chatVC.permissionCardHost.subviews.isEmpty,
            "no card subview should linger after the synchronous teardown")
        let sessionB = fx.manager.session(fx.sessionIds[1])!
        XCTAssertTrue(
            fx.chatVC.permissionCardController.currentBoundSession === sessionB,
            "the controller should be bound to B after the switch")
    }

    /// IDENTITY GUARD. After present(B), mutate A's pendingPermissions to fire
    /// a STALE wake → NO card mounts for A (the `boundSession === session`
    /// guard on every observation wake, mirroring InputBarController).
    func testStaleWakeFromPriorSessionIsIgnored() async throws {
        let fx = makeFixture(sessionCount: 2)
        let sessionA = fx.manager.prepareDraftSession(fx.sessionIds[0])
        fx.chatVC.present(sessionId: fx.sessionIds[0])
        fx.chatVC.present(sessionId: fx.sessionIds[1])

        // A is no longer bound. A late enqueue on A must NOT mount a card.
        seedPermission(sessionA, requestId: "perm-stale-A")
        // Give any (incorrectly-armed) stale observation a chance to fire.
        let mountedForA = await waitUntil(timeout: 0.6) {
            fx.chatVC.permissionCardController.currentMountedPendingId == "perm-stale-A"
        }
        XCTAssertFalse(
            mountedForA, "a stale wake from the prior session A must not mount its card")
        XCTAssertNil(
            fx.chatVC.permissionCardController.currentCard,
            "no card should be mounted for the unbound prior session")
    }

    /// clearBinding on `.none`: present(A pending) → card mounts → present(nil)
    /// → card gone + observation cancelled (a subsequent enqueue on A does not
    /// re-mount).
    func testClearBindingOnNoneSelectionDismissesAndCancels() async throws {
        let fx = makeFixture(sessionCount: 1)
        let sessionA = fx.manager.prepareDraftSession(fx.sessionIds[0])
        seedPermission(sessionA, requestId: "perm-clear")
        fx.chatVC.present(sessionId: fx.sessionIds[0])
        XCTAssertNotNil(fx.chatVC.permissionCardController.currentCard)

        fx.chatVC.present(sessionId: nil)
        XCTAssertNil(
            fx.chatVC.permissionCardController.currentCard,
            "the card should be gone synchronously on the .none selection")
        XCTAssertNil(
            fx.chatVC.permissionCardController.currentBoundSession,
            "clearBinding should drop the bound session")

        // Observation cancelled — a late enqueue does not re-mount.
        seedPermission(sessionA, requestId: "perm-clear-2")
        let reMounted = await waitUntil(timeout: 0.6) {
            fx.chatVC.permissionCardController.currentCard != nil
        }
        XCTAssertFalse(reMounted, "a cleared controller must not re-mount on a late enqueue")
    }

    /// stop() on prepareForRemoval: present(A pending) → card mounts →
    /// prepareForRemoval → card dismissed, no orphan subview.
    func testStopOnPrepareForRemovalDismisses() async throws {
        let fx = makeFixture(sessionCount: 1)
        let sessionA = fx.manager.prepareDraftSession(fx.sessionIds[0])
        seedPermission(sessionA, requestId: "perm-stop")
        fx.chatVC.present(sessionId: fx.sessionIds[0])
        XCTAssertNotNil(fx.chatVC.permissionCardController.currentCard)

        fx.chatVC.prepareForRemoval()
        XCTAssertNil(
            fx.chatVC.permissionCardController.currentCard,
            "prepareForRemoval should synchronously dismiss the card")
        XCTAssertTrue(
            fx.chatVC.permissionCardHost.subviews.isEmpty,
            "no orphan card subview should remain after stop()")
    }

    /// SAME-ID-CHANGE INTERLEAVE + FADE CLEANLINESS (timing findings #1, #2).
    /// Two real-reconcile checks that survive the offscreen `NSAnimationContext`
    /// completing near-instantly (no live display link to pace 0.25s):
    ///
    /// (a) With A's card mounted, swap the pending to a DIFFERENT id B in one
    ///     mutation. `reconcile` takes the "different id while a card is mounted"
    ///     branch → `dismissCardSynchronously()` then `mountCard(B)`. Assert
    ///     exactly ONE card subview (B), B is the mounted card, and the host is
    ///     hit-eligible (`isDismissing == false`) — the finding #2 stacking bug
    ///     would leave two subviews, the finding #1 leak would leave
    ///     `isDismissing` stuck true.
    ///
    /// (b) Dequeue B (it fades out and the completion removes it), let the fade
    ///     settle, then enqueue a third id C. Assert the controller comes to rest
    ///     with exactly one card (C), no orphaned fading card, and the host
    ///     hit-eligible — the generation guard / `cancelInFlightFade` must leave
    ///     no stray subview or stuck `isDismissing` behind a completed fade.
    func testInterleavedReconcileMountsExactlyOneHitEligibleCard() async throws {
        let fx = makeFixture(sessionCount: 1)
        fx.chatVC.present(sessionId: fx.sessionIds[0])
        let session = fx.manager.session(fx.sessionIds[0])!
        let host = fx.chatVC.permissionCardHost!

        // Mount A.
        seedPermission(session, requestId: "perm-int-A")
        let mountedA = await waitUntil {
            fx.chatVC.permissionCardController.currentMountedPendingId == "perm-int-A"
        }
        XCTAssertTrue(mountedA, "A's card should mount")

        guard case .active(let runtime) = session.phase else {
            XCTFail("expected active session")
            return
        }

        // (a) Swap A → B in one mutation; reconcile drops A synchronously and
        // mounts B. Exactly one card, B mounted, host hit-eligible.
        runtime.pendingPermissions.removeAll()
        seedPermission(session, requestId: "perm-int-B")
        let mountedB = await waitUntil {
            fx.chatVC.permissionCardController.currentMountedPendingId == "perm-int-B"
        }
        XCTAssertTrue(mountedB, "B's card should mount after the id swap")
        XCTAssertEqual(
            host.subviews.count, 1,
            "exactly one card subview — A must be dropped before B mounts (finding #2)")
        XCTAssertNil(
            fx.chatVC.permissionCardController.currentFadingOutCard,
            "no orphaned fading card after the synchronous id-swap drop")
        XCTAssertFalse(
            host.isDismissing,
            "the swapped-in card must be hit-eligible — isDismissing cleared (finding #1)")

        // (b) Dequeue B → it fades out; let the fade complete and the card leave
        // the tree.
        runtime.pendingPermissions.removeAll()
        let bGone = await waitUntil {
            fx.chatVC.permissionCardController.currentCard == nil && host.subviews.isEmpty
        }
        XCTAssertTrue(bGone, "B should fade out and be removed when its pending clears")
        XCTAssertNil(
            fx.chatVC.permissionCardController.currentFadingOutCard,
            "no orphaned fading card after B's fade completes")
        XCTAssertFalse(
            host.isDismissing,
            "isDismissing must be cleared once B's fade completes (finding #1 guard)")

        // Enqueue C → comes to rest as exactly one hit-eligible card.
        seedPermission(session, requestId: "perm-int-C")
        let mountedC = await waitUntil {
            fx.chatVC.permissionCardController.currentMountedPendingId == "perm-int-C"
        }
        XCTAssertTrue(mountedC, "C's card should mount after B is gone")
        XCTAssertEqual(host.subviews.count, 1, "exactly one card subview at rest (C)")
        XCTAssertFalse(host.isDismissing, "C must be hit-eligible — isDismissing cleared")
    }

    /// decisionHandlers wiring through the card's real Deny button: firing the
    /// production `onClick` clears the pending entry (the card's deny routes to
    /// `session.respond` → the seeded `respond` closure removes it).
    func testCardDenyButtonDispatchesToSessionRespond() async throws {
        let fx = makeFixture(sessionCount: 1)
        let session = fx.manager.prepareDraftSession(fx.sessionIds[0])
        // Seed a permission whose respond closure records the decision and pops
        // its own entry (the production sink shape).
        let captured = CapturedDecision()
        guard case .active(let runtime) = session.phase else {
            XCTFail("expected active session")
            return
        }
        let request = PermissionRequest.makePreview(
            requestId: "perm-deny", toolName: "Bash", input: ["command": "ls"])
        runtime.pendingPermissions.append(
            PendingPermission(
                id: "perm-deny", request: request,
                respond: { [captured] decision in
                    captured.decision = decision
                    Task { @MainActor [weak runtime] in
                        runtime?.pendingPermissions.removeAll { $0.id == "perm-deny" }
                    }
                }))

        fx.chatVC.present(sessionId: fx.sessionIds[0])
        guard let card = fx.chatVC.permissionCardController.currentCard,
            let denyButton = card.decisionButtons.first
        else {
            XCTFail("the card / its deny button never mounted")
            return
        }
        // The card's first decision button is Deny (.destructive).
        XCTAssertEqual(denyButton.role, .destructive)
        denyButton.onClick?()

        let delivered = await waitUntil { captured.decision != nil }
        XCTAssertTrue(delivered, "the deny decision should reach session.respond")
        guard case .deny(let reason, let interrupt) = captured.decision else {
            XCTFail("expected a .deny decision, got \(String(describing: captured.decision))")
            return
        }
        XCTAssertTrue(reason.contains("User rejected"))
        XCTAssertTrue(interrupt)
    }
}

/// Reference wrapper so the seeded `respond` closure can record the decision
/// without `inout` capture.
private final class CapturedDecision {
    var decision: PermissionDecision?
}

import AgentSDK
import XCTest

@testable import ccterm

/// Verifies that the four decision handlers `PermissionCardOverlay` builds
/// for a `PermissionCardView` — via `decisionHandlers(for:session:)` — route
/// to the right `PermissionDecision` at the `Session.respond(to:decision:)`
/// boundary with the right pending `id`, and that the runtime pops the entry
/// off `pendingPermissions` once a decision has been delivered. We build the
/// SAME `Handlers` the body builds and invoke each closure (per
/// `cctermTests/CLAUDE.md` § What goes here — drive the underlying method the
/// button invokes), so a regression that swaps Allow-once ↔ Allow-always,
/// drops the deny reason, loses the `updatedInput` payload, or routes a
/// handler to the wrong card's `id` trips here.
@MainActor
final class PermissionCardWiringTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAllowOnceDeliversAllowDecisionAndClearsPending() async throws {
        let (session, runtime, captured, pending) = Self.seedSession(requestId: "perm-allow-once")
        let handlers = PermissionCardOverlay.decisionHandlers(for: pending, session: session)

        handlers.onAllowOnce()
        await Self.drainPendingRemoval()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.ids.first, "perm-allow-once")
        guard case .allow(let updatedInput) = captured[0] else {
            XCTFail("expected .allow decision, got \(captured[0])")
            return
        }
        XCTAssertNil(updatedInput)
        XCTAssertTrue(runtime.pendingPermissions.isEmpty)
    }

    func testAllowAlwaysDeliversAllowAlwaysAndClearsPending() async throws {
        let (session, runtime, captured, pending) = Self.seedSession(
            requestId: "perm-allow-always")
        let handlers = PermissionCardOverlay.decisionHandlers(for: pending, session: session)

        handlers.onAllowAlways()
        await Self.drainPendingRemoval()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.ids.first, "perm-allow-always")
        guard case .allowAlways = captured[0] else {
            XCTFail("expected .allowAlways decision, got \(captured[0])")
            return
        }
        XCTAssertTrue(runtime.pendingPermissions.isEmpty)
    }

    func testDenyDeliversDenyWithReasonAndInterrupt() async throws {
        let (session, runtime, captured, pending) = Self.seedSession(requestId: "perm-deny")
        let handlers = PermissionCardOverlay.decisionHandlers(for: pending, session: session)

        handlers.onDeny()
        await Self.drainPendingRemoval()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.ids.first, "perm-deny")
        guard case .deny(let reason, let interrupt) = captured[0] else {
            XCTFail("expected .deny decision, got \(captured[0])")
            return
        }
        XCTAssertTrue(reason.contains("User rejected"))
        XCTAssertTrue(interrupt)
        XCTAssertTrue(runtime.pendingPermissions.isEmpty)
    }

    /// `onAllowWithInput` must carry the edited payload through to an
    /// `.allow(updatedInput:)` — the askUserQuestion path. Guards against a
    /// regression that drops `updatedInput` (the answer dict) on the floor.
    func testAllowWithInputCarriesUpdatedInput() async throws {
        let (session, runtime, captured, pending) = Self.seedSession(requestId: "perm-allow-input")
        let handlers = PermissionCardOverlay.decisionHandlers(for: pending, session: session)

        handlers.onAllowWithInput(["answers": ["yes"]])
        await Self.drainPendingRemoval()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.ids.first, "perm-allow-input")
        guard case .allow(let updatedInput) = captured[0] else {
            XCTFail("expected .allow decision, got \(captured[0])")
            return
        }
        XCTAssertEqual(updatedInput?["answers"] as? [String], ["yes"])
        XCTAssertTrue(runtime.pendingPermissions.isEmpty)
    }

    func testRespondToUnknownIdIsNoop() throws {
        let (session, runtime, captured, _) = Self.seedSession(requestId: "perm-real")

        session.respond(to: "perm-other", decision: .allow())

        XCTAssertTrue(captured.isEmpty)
        XCTAssertEqual(runtime.pendingPermissions.count, 1)
    }

    /// With two cards queued, each handler set must target the `id` of the
    /// `PendingPermission` it was built from — never the wrong (e.g. first)
    /// entry. Drives the SECOND card's handlers and asserts the decision
    /// landed on its id (and only its entry is popped). A regression that
    /// hard-codes `pendingPermissions.first.id`, or otherwise routes to the
    /// wrong card, trips here.
    func testHandlersTargetTheirOwnPendingIdWithMultipleQueued() async throws {
        let repo = InMemorySessionRepository()
        let runtime = SessionRuntime(sessionId: UUID().uuidString, repository: repo)
        let session = ccterm.Session(runtime: runtime)
        let captured = CapturedDecisions()

        let first = Self.makePending(requestId: "perm-first", captured: captured, runtime: runtime)
        let second = Self.makePending(
            requestId: "perm-second", captured: captured, runtime: runtime)
        runtime.pendingPermissions.append(first)
        runtime.pendingPermissions.append(second)

        let handlers = PermissionCardOverlay.decisionHandlers(for: second, session: session)
        handlers.onAllowOnce()
        await Self.drainPendingRemoval()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.ids.first, "perm-second")
        XCTAssertEqual(runtime.pendingPermissions.map(\.id), ["perm-first"])
    }

    // MARK: - Helpers

    /// The production `respond` closure pops the pending entry off
    /// `pendingPermissions` via `Task { @MainActor }`, so the array
    /// hasn't been mutated yet by the time `session.respond` returns.
    /// One run-loop turn drains that hop. Two `yield()`s for safety
    /// — `Task.init` enqueues and `pendingPermissions.removeAll`
    /// fires on the next main-actor execution slot.
    private static func drainPendingRemoval() async {
        await Task.yield()
        await Task.yield()
    }

    /// Constructs an active-phase session with one pending permission
    /// seeded directly onto the runtime. The returned `captured` records
    /// every `(id, decision)` the response closure receives — tests assert
    /// on its contents. The `PendingPermission` is returned so the test can
    /// build the same `Handlers` the overlay body builds.
    private static func seedSession(
        requestId: String
    ) -> (
        ccterm.Session, SessionRuntime, CapturedDecisions, PendingPermission
    ) {
        let repo = InMemorySessionRepository()
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString, repository: repo)
        let session = ccterm.Session(runtime: runtime)
        let captured = CapturedDecisions()

        let pending = makePending(requestId: requestId, captured: captured, runtime: runtime)
        runtime.pendingPermissions.append(pending)

        return (session, runtime, captured, pending)
    }

    /// One pending entry whose `respond` closure records the decision
    /// **keyed by `requestId`** (so the wrong-id guard can assert which
    /// card was answered) and then pops its own entry off the runtime on
    /// the next main-actor slot — mirroring the production sink. Shared by
    /// the single-card seed and the multi-card targeting test.
    private static func makePending(
        requestId: String,
        captured: CapturedDecisions,
        runtime: SessionRuntime
    ) -> PendingPermission {
        let request = PermissionRequest.makePreview(
            requestId: requestId,
            toolName: "Bash",
            input: ["command": "ls"])
        return PendingPermission(
            id: requestId,
            request: request,
            respond: { [captured] decision in
                captured.append(id: requestId, decision: decision)
                Task { @MainActor [weak runtime] in
                    runtime?.pendingPermissions.removeAll { $0.id == requestId }
                }
            })
    }
}

/// Reference wrapper capturing `(id, decision)` pairs so the closure can
/// record what the runtime delivered without `inout` capture. The `id`
/// side lets the wrong-id guard assert the handler targeted the right
/// `PendingPermission`.
private final class CapturedDecisions {
    private(set) var values: [PermissionDecision] = []
    private(set) var ids: [String] = []
    var count: Int { values.count }
    var isEmpty: Bool { values.isEmpty }
    subscript(i: Int) -> PermissionDecision { values[i] }

    func append(id: String, decision: PermissionDecision) {
        ids.append(id)
        values.append(decision)
    }
}

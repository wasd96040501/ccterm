import AgentSDK
import XCTest

@testable import ccterm

/// Verifies that the four decision handlers `PermissionCardOverlay` builds
/// for a `PermissionCardView` — via `decisionHandlers(for:session:)` — route
/// to the right `PermissionDecision` at the `Session.respond(to:decision:)`
/// boundary with the right request `id`, and that the runtime pops the
/// request off `pendingPermissions` once a decision has been delivered. We build the
/// SAME `Handlers` the body builds and invoke each closure (per
/// `cctermTests/CLAUDE.md` — drive the underlying method the
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

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.ids.first, "perm-allow-once")
        XCTAssertEqual(captured[0], .allow())
        XCTAssertTrue(runtime.pendingPermissions.isEmpty)
    }

    func testAllowAlwaysDeliversAllowAlwaysAndClearsPending() async throws {
        let (session, runtime, captured, pending) = Self.seedSession(
            requestId: "perm-allow-always")
        let handlers = PermissionCardOverlay.decisionHandlers(for: pending, session: session)

        handlers.onAllowAlways()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.ids.first, "perm-allow-always")
        XCTAssertEqual(
            captured[0], .allow(updatedPermissions: [Self.suggestion]),
            "allow-always applies the CLI's suggestions")
        XCTAssertTrue(runtime.pendingPermissions.isEmpty)
    }

    func testDenyDeliversDenyWithReasonAndInterrupt() async throws {
        let (session, runtime, captured, pending) = Self.seedSession(requestId: "perm-deny")
        let handlers = PermissionCardOverlay.decisionHandlers(for: pending, session: session)

        handlers.onDeny()

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

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.ids.first, "perm-allow-input")
        XCTAssertEqual(captured[0], .allow(updatedInput: ["answers": ["yes"]]))
        XCTAssertTrue(runtime.pendingPermissions.isEmpty)
    }

    func testRespondToUnknownIdIsNoop() throws {
        let (session, runtime, captured, _) = Self.seedSession(requestId: "perm-real")

        session.respond(to: "perm-other", decision: .allow())

        XCTAssertTrue(captured.isEmpty)
        XCTAssertEqual(runtime.pendingPermissions.count, 1)
    }

    /// With two cards queued, each handler set must target the `id` of the
    /// request it was built from — never the wrong (e.g. first)
    /// entry. Drives the SECOND card's handlers and asserts the decision
    /// landed on its id (and only its entry is popped). A regression that
    /// hard-codes `pendingPermissions.first.id`, or otherwise routes to the
    /// wrong card, trips here.
    func testHandlersTargetTheirOwnPendingIdWithMultipleQueued() async throws {
        let repo = InMemorySessionRepository()
        let runtime = SessionRuntime(sessionId: UUID().uuidString, repository: repo)
        let session = ccterm.Session(runtime: runtime)
        let captured = CapturedDecisions()

        let first = Self.makeRequest(requestId: "perm-first", captured: captured)
        let second = Self.makeRequest(requestId: "perm-second", captured: captured)
        runtime.pendingPermissions.append(first)
        runtime.pendingPermissions.append(second)

        let handlers = PermissionCardOverlay.decisionHandlers(for: second, session: session)
        handlers.onAllowOnce()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.ids.first, "perm-second")
        XCTAssertEqual(runtime.pendingPermissions.map(\.id), ["perm-first"])
    }

    // MARK: - Helpers

    private static let suggestion = PermissionUpdate.addRules(
        [PermissionRule(toolName: "Bash", ruleContent: "ls")], behavior: .allow, destination: .localSettings)

    /// Constructs an active-phase session with one pending permission
    /// seeded directly onto the runtime. The returned `captured` records
    /// every `(id, decision)` the request receives — tests assert on its
    /// contents. The request is returned so the test can build the same
    /// `Handlers` the overlay body builds.
    private static func seedSession(
        requestId: String
    ) -> (
        ccterm.Session, SessionRuntime, CapturedDecisions, PermissionRequest
    ) {
        let repo = InMemorySessionRepository()
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString, repository: repo)
        let session = ccterm.Session(runtime: runtime)
        let captured = CapturedDecisions()

        let request = makeRequest(requestId: requestId, captured: captured)
        runtime.pendingPermissions.append(request)

        return (session, runtime, captured, request)
    }

    /// A request that records its decision **keyed by `requestId`**, so the
    /// wrong-id guard can assert which card was answered.
    private static func makeRequest(
        requestId: String,
        captured: CapturedDecisions
    ) -> PermissionRequest {
        PermissionRequest(
            id: requestId, toolName: "Bash", input: ["command": "ls"], suggestions: [suggestion],
            onRespond: { [captured] decision in
                captured.append(id: requestId, decision: decision)
            })
    }
}

/// Reference wrapper capturing `(id, decision)` pairs so the closure can
/// record what the runtime delivered without `inout` capture. The `id`
/// side lets the wrong-id guard assert the handler targeted the right
/// request. Only touched on the main thread (`respond` runs inline there).
private final class CapturedDecisions: @unchecked Sendable {
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

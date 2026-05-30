import AgentSDK
import XCTest

@testable import ccterm

/// Verifies that the three buttons on `PermissionCardView`, as wired
/// in `ChatRestingBar`, route to the right `PermissionDecision` at
/// the `Session.respond(to:decision:)` boundary — and that the
/// runtime pops the entry off `pendingPermissions` once a decision
/// has been delivered. We drive the underlying method the buttons
/// call (per `cctermTests/CLAUDE.md` § What goes here), rather than
/// trying to synthesise SwiftUI button taps.
@MainActor
final class PermissionCardWiringTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAllowOnceDeliversAllowDecisionAndClearsPending() async throws {
        let (session, runtime, captured) = Self.seedSession(requestId: "perm-allow-once")

        let request = runtime.pendingPermissions.first!.request
        session.respond(to: "perm-allow-once", decision: request.allowOnce())
        await Self.drainPendingRemoval()

        XCTAssertEqual(captured.count, 1)
        guard case .allow(let updatedInput) = captured[0] else {
            XCTFail("expected .allow decision, got \(captured[0])")
            return
        }
        XCTAssertNil(updatedInput)
        XCTAssertTrue(runtime.pendingPermissions.isEmpty)
    }

    func testAllowAlwaysDeliversAllowAlwaysAndClearsPending() async throws {
        let (session, runtime, captured) = Self.seedSession(requestId: "perm-allow-always")

        let request = runtime.pendingPermissions.first!.request
        session.respond(to: "perm-allow-always", decision: request.allowAlways())
        await Self.drainPendingRemoval()

        XCTAssertEqual(captured.count, 1)
        guard case .allowAlways = captured[0] else {
            XCTFail("expected .allowAlways decision, got \(captured[0])")
            return
        }
        XCTAssertTrue(runtime.pendingPermissions.isEmpty)
    }

    func testDenyDeliversDenyWithReasonAndInterrupt() async throws {
        let (session, runtime, captured) = Self.seedSession(requestId: "perm-deny")

        let request = runtime.pendingPermissions.first!.request
        session.respond(to: "perm-deny", decision: request.deny())
        await Self.drainPendingRemoval()

        XCTAssertEqual(captured.count, 1)
        guard case .deny(let reason, let interrupt) = captured[0] else {
            XCTFail("expected .deny decision, got \(captured[0])")
            return
        }
        XCTAssertTrue(reason.contains("User rejected"))
        XCTAssertTrue(interrupt)
        XCTAssertTrue(runtime.pendingPermissions.isEmpty)
    }

    func testRespondToUnknownIdIsNoop() throws {
        let (session, runtime, captured) = Self.seedSession(requestId: "perm-real")

        session.respond(to: "perm-other", decision: .allow())

        XCTAssertTrue(captured.isEmpty)
        XCTAssertEqual(runtime.pendingPermissions.count, 1)
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
    /// seeded directly onto the runtime. The returned array captures
    /// every decision the response closure receives — tests assert on
    /// its contents.
    private static func seedSession(requestId: String) -> (ccterm.Session, SessionRuntime, CapturedDecisions) {
        let repo = InMemorySessionRepository()
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString, repository: repo)
        let session = ccterm.Session(runtime: runtime)
        let captured = CapturedDecisions()

        let request = PermissionRequest.makePreview(
            requestId: requestId,
            toolName: "Bash",
            input: ["command": "ls"])
        let pending = PendingPermission(
            id: requestId,
            request: request,
            respond: { [captured] decision in
                captured.values.append(decision)
                Task { @MainActor [weak runtime] in
                    runtime?.pendingPermissions.removeAll { $0.id == requestId }
                }
            })
        runtime.pendingPermissions.append(pending)

        return (session, runtime, captured)
    }
}

/// Reference wrapper around `[PermissionDecision]` so the closure can
/// mutate the same buffer the test inspects without `inout` capture.
private final class CapturedDecisions {
    var values: [PermissionDecision] = []
    var count: Int { values.count }
    var isEmpty: Bool { values.isEmpty }
    subscript(i: Int) -> PermissionDecision { values[i] }
}

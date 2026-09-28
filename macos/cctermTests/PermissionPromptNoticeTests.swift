import AgentSDK
import XCTest

@testable import ccterm

/// A pending permission *pauses* the turn, so the `.responding` →
/// `.idle` edge that fires `onTurnEnded` never lands while the card is
/// up. This pins the parallel signal that exists for exactly that gap:
/// enqueuing a permission fires `onPermissionPrompt`, which the
/// notification service turns into a banner when the app is
/// backgrounded.
///
/// Driven through the real CLI wiring (`FakeCLIClient.onPermissionRequest`
/// → `SessionRuntime.enqueuePermission`), not a hand-seeded
/// `pendingPermissions` array — `PermissionCardWiringTests` covers the
/// hand-seeded decision path; this one covers the enqueue side that
/// produces the notice.
@MainActor
final class PermissionPromptNoticeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEnqueuingPermissionFiresPromptOnce() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)

        var captured: [PermissionPromptNotice] = []
        runtime.onPermissionPrompt = { captured.append($0) }

        fake.requestPermission(toolName: "Bash", input: ["command": "ls"], id: "perm-1")
        await yieldUntil { !runtime.pendingPermissions.isEmpty }

        XCTAssertEqual(
            captured.count, 1, "enqueuing a permission must fire onPermissionPrompt exactly once")
        XCTAssertEqual(captured.first?.sessionId, runtime.sessionId)
        XCTAssertTrue(
            captured.first?.body.contains("Bash") ?? false,
            "the prompt body should name the tool awaiting approval")
        XCTAssertEqual(
            runtime.pendingPermissions.count, 1,
            "the pending entry is still appended so the card can render")
    }

    func testNoPromptSubscriberIsSafe() async {
        let (runtime, fake) = makeRuntime()
        await bootstrap(runtime, fake)
        // No onPermissionPrompt installed — enqueue must still land the
        // pending entry without crashing on the nil closure.
        fake.requestPermission(toolName: "Read", input: ["file_path": "/tmp/x"], id: "perm-2")
        await yieldUntil { !runtime.pendingPermissions.isEmpty }

        XCTAssertEqual(runtime.pendingPermissions.count, 1)
    }

    // MARK: - Helpers (mirrors SessionRuntimeCLIWiringTests)

    private func makeRuntime(sessionId: String = UUID().uuidString) -> (SessionRuntime, FakeCLIClient) {
        let fake = FakeCLIClient()
        let runtime = SessionRuntime(
            sessionId: sessionId,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in fake }
        )
        runtime.config.cwd = "/tmp/permission-prompt-tests"
        return (runtime, fake)
    }

    private func bootstrap(_ runtime: SessionRuntime, _ fake: FakeCLIClient) async {
        runtime.activate()
        await yieldUntil { fake.isAwaitingStart }
        XCTAssertTrue(fake.isAwaitingStart, "bootstrap should have started the client")
        fake.completeStart()
        await yieldUntil { runtime.status == .idle }
    }
}

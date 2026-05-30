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

        let request = PermissionRequest.makePreview(
            requestId: "perm-1", toolName: "Bash", input: ["command": "ls"])
        fake.simulatePermissionRequest(request) { _ in }
        await drain()

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
        let request = PermissionRequest.makePreview(
            requestId: "perm-2", toolName: "Read", input: ["file_path": "/tmp/x"])
        fake.simulatePermissionRequest(request) { _ in }
        await drain()

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
        for _ in 0..<8 {
            await Task.yield()
            if !fake.initializeCalls.isEmpty { break }
        }
        XCTAssertFalse(fake.initializeCalls.isEmpty, "bootstrap should have called initialize")
        fake.completeInitialize(with: nil)
        for _ in 0..<8 {
            await Task.yield()
            if runtime.status == .idle { break }
        }
    }

    /// `onPermissionRequest` posts a `Task { @MainActor … }` that calls
    /// `enqueuePermission`. Two yields drain that hop.
    private func drain() async {
        await Task.yield()
        await Task.yield()
    }
}

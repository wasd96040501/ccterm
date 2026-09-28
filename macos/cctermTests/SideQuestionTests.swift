import AgentSDK
import XCTest

@testable import ccterm

/// Pure-logic tests for the `/btw` side-question plumbing.
///
/// `Session.askSideQuestion(...)` end-to-end: the request goes through
/// the façade, into the runtime, into the `CLIClient`; the CLI's answer
/// (or failure) comes back to the caller. Tests drive a real
/// `SessionRuntime` constructed with a `FakeCLIClient` factory and
/// activate it so the production `activate → start → cliClient` wiring
/// fires — no test-only seams.
@MainActor
final class SideQuestionTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testForwardsQuestionToCLIAndDeliversAnswer() async throws {
        let fake = FakeCLIClient()
        let session = try await makeActivatedSession(client: fake)

        let ask = Task { try await session.askSideQuestion("what is the launch code?") }
        await yieldUntil { !fake.sideQuestions.isEmpty }
        XCTAssertEqual(fake.sideQuestions, ["what is the launch code?"])

        fake.completeSideQuestion(.success(SideQuestionAnswer(response: "PURPLE-RHINO-7", synthetic: false)))
        let received = try await ask.value

        XCTAssertEqual(received?.response, "PURPLE-RHINO-7")
        XCTAssertEqual(received?.synthetic, false)
    }

    func testSyntheticAnswerIsPreserved() async throws {
        let fake = FakeCLIClient()
        let session = try await makeActivatedSession(client: fake)

        let ask = Task { try await session.askSideQuestion("read my file") }
        await yieldUntil { !fake.sideQuestions.isEmpty }
        fake.completeSideQuestion(
            .success(SideQuestionAnswer(response: "(The model tried to call Read…)", synthetic: true)))

        let synthetic = try await ask.value?.synthetic
        XCTAssertEqual(synthetic, true)
    }

    func testCLIFailurePassesThrough() async throws {
        let fake = FakeCLIClient()
        let session = try await makeActivatedSession(client: fake)

        let ask = Task { try await session.askSideQuestion("anything") }
        await yieldUntil { !fake.sideQuestions.isEmpty }
        fake.completeSideQuestion(
            .failure(AgentSDKError.controlRequestFailed(subtype: "side_question", message: "unsupported")))

        do {
            _ = try await ask.value
            XCTFail("expected the CLI's error")
        } catch AgentSDKError.controlRequestFailed(_, let message) {
            XCTAssertEqual(message, "unsupported")
        }
    }

    func testDraftSessionThrowsNotRunning() async {
        let session = ccterm.Session(
            draftSessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in FakeCLIClient() }
        )
        do {
            _ = try await session.askSideQuestion("anything")
            XCTFail("a draft has no CLI to ask")
        } catch AgentSDKError.notRunning {
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: - Helpers

    /// Build an `.active`-phase Session backed by `fake` and wait for the
    /// runtime to have wired `cliClient` (production's `activate` →
    /// bootstrap → `start` → `cliClient = ...` chain). Mirrors
    /// `ContextUsageTests.makeActivatedSession`.
    private func makeActivatedSession(client fake: FakeCLIClient) async throws -> ccterm.Session {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        let record = SessionRecord(
            sessionId: sid,
            title: "btw-test",
            cwd: NSTemporaryDirectory(),
            status: .created
        )
        repo.save(record)
        let session = ccterm.Session(
            record: record,
            repository: repo,
            cliClientFactory: { _ in fake }
        )
        session.activate()
        await yieldUntil { fake.isAwaitingStart }
        fake.completeStart()

        let runtime = try XCTUnwrap(session.runtime)
        let attached = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated { runtime.cliClient != nil }
            },
            object: nil
        )
        await fulfillment(of: [attached], timeout: 5.0)
        return session
    }
}

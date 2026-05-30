import AgentSDK
import XCTest

@testable import ccterm

/// Pure-logic tests for the `/btw` side-question plumbing.
///
/// `Session.askSideQuestion(...)` end-to-end: the request goes through
/// the façade, into the runtime, into the `CLIClient`; the outcome the
/// CLI hands back is delivered to the caller on the main actor exactly
/// once. Tests drive a real `SessionRuntime` constructed with a
/// `FakeCLIClient` factory and activate it so the production
/// `activate → start → cliClient` wiring fires — no test-only seams.
@MainActor
final class SideQuestionTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testForwardsQuestionToCLIAndDeliversAnswer() async throws {
        let fake = FakeCLIClient()
        let session = try await makeActivatedSession(client: fake)

        let exp = expectation(description: "completion fires")
        var received: SideQuestionAnswer?
        session.askSideQuestion("what is the launch code?") { outcome in
            if case .answer(let a) = outcome {
                received = a
                exp.fulfill()
            } else {
                XCTFail("\(outcome)")
            }
        }

        XCTAssertEqual(fake.sideQuestionCalls.count, 1)
        XCTAssertEqual(fake.sideQuestionCalls.first?.question, "what is the launch code?")

        fake.completeSideQuestion(.answer(SideQuestionAnswer(response: "PURPLE-RHINO-7", synthetic: false)))
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertEqual(received?.response, "PURPLE-RHINO-7")
        XCTAssertEqual(received?.synthetic, false)
    }

    func testSyntheticAnswerIsPreserved() async throws {
        let fake = FakeCLIClient()
        let session = try await makeActivatedSession(client: fake)

        let exp = expectation(description: "completion fires")
        var synthetic: Bool?
        session.askSideQuestion("read my file") { outcome in
            synthetic = outcome.answer?.synthetic
            exp.fulfill()
        }
        fake.completeSideQuestion(
            .answer(SideQuestionAnswer(response: "(The model tried to call Read…)", synthetic: true)))
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertEqual(synthetic, true)
    }

    func testUnsupportedPassesThrough() async throws {
        let fake = FakeCLIClient()
        let session = try await makeActivatedSession(client: fake)

        let exp = expectation(description: "unsupported")
        session.askSideQuestion("anything") { outcome in
            if case .unsupported = outcome { exp.fulfill() } else { XCTFail("\(outcome)") }
        }
        fake.completeSideQuestion(.unsupported)
        await fulfillment(of: [exp], timeout: 2.0)
    }

    func testDraftSessionShortCircuitsToUnsupported() {
        let session = ccterm.Session(
            draftSessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in FakeCLIClient() }
        )
        let exp = expectation(description: "unsupported")
        session.askSideQuestion("anything") { outcome in
            if case .unsupported = outcome { exp.fulfill() } else { XCTFail("\(outcome)") }
        }
        wait(for: [exp], timeout: 1.0)
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

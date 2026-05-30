import AgentSDK
import XCTest

@testable import ccterm

/// Drives `SessionRuntime`'s partial-message path directly: stream events fold
/// into a provisional preview entry + live turn usage, and the finalized
/// `.assistant` envelope converges onto the same entry id (no duplicate).
/// No CLI subprocess — `consumeStreamEvent` / `receive` are called directly.
@MainActor
final class SessionRuntimeStreamingTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func makeRuntime() -> SessionRuntime {
        SessionRuntime(sessionId: UUID().uuidString, repository: InMemorySessionRepository())
    }

    /// Wait for the coalesced streaming flush (a scheduled `Task { @MainActor }`)
    /// to run by polling on a condition.
    private func wait(for runtime: SessionRuntime, until cond: @escaping () -> Bool) async {
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in cond() }, object: nil)
        await fulfillment(of: [exp], timeout: 2)
    }

    // MARK: - Text preview

    func testTextDeltasCreateProvisionalPreviewEntry() async {
        let runtime = makeRuntime()
        runtime.consumeStreamEvent(Message2Fixtures.streamMessageStart(messageId: "m1"))
        runtime.consumeStreamEvent(Message2Fixtures.streamTextDelta(index: 0, text: "Hello, world."))

        await wait(for: runtime) { !runtime.messages.isEmpty }

        XCTAssertEqual(runtime.messages.count, 1)
        guard case .single(let s) = runtime.messages[0], case .remote(let m) = s.payload,
            case .assistant(let a) = m
        else { return XCTFail("expected a provisional assistant single") }
        XCTAssertEqual(a.message?.id, "m1")
        XCTAssertNotNil(runtime.streamingPreviewEntryIds["m1"])
    }

    func testFinalEnvelopeConvergesOntoPreviewEntry() async {
        let runtime = makeRuntime()
        runtime.consumeStreamEvent(Message2Fixtures.streamMessageStart(messageId: "m1"))
        runtime.consumeStreamEvent(Message2Fixtures.streamTextDelta(index: 0, text: "Hi"))
        await wait(for: runtime) { !runtime.messages.isEmpty }

        let previewId = runtime.messages[0].id

        // The finalized envelope for the same message id arrives.
        runtime.receive(Message2Fixtures.assistantText("Hi there!", messageId: "m1"), mode: .live)

        XCTAssertEqual(runtime.messages.count, 1, "must reuse the preview entry, not append a duplicate")
        XCTAssertEqual(runtime.messages[0].id, previewId, "entry id is preserved → block ids converge")
        XCTAssertNil(runtime.streamingPreviewEntryIds["m1"], "preview mapping consumed on convergence")
    }

    func testNonStreamedAssistantStillAppendsNormally() {
        // No preview was created for "m2" → the finalized envelope appends as
        // before. (Guards that the convergence path is gated on an existing
        // preview and doesn't disturb non-streamed sessions.)
        let runtime = makeRuntime()
        runtime.receive(Message2Fixtures.assistantText("plain", messageId: "m2"), mode: .live)
        XCTAssertEqual(runtime.messages.count, 1)
        guard case .single(let s) = runtime.messages[0], case .remote = s.payload else {
            return XCTFail("expected a remote assistant single")
        }
    }

    func testNewTurnResetsStreamingState() async {
        let runtime = makeRuntime()
        runtime.consumeStreamEvent(
            Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 10, outputTokens: 5))
        runtime.consumeStreamEvent(Message2Fixtures.streamTextDelta(index: 0, text: "stuff"))
        await wait(for: runtime) { !runtime.turnUsage.isEmpty }

        runtime.resetStreamingTurn()
        XCTAssertTrue(runtime.turnUsage.isEmpty)
        XCTAssertTrue(runtime.streamingPreviewEntryIds.isEmpty)
    }

    // MARK: - Turn token usage

    func testTurnUsageTracksStreamThenFinalEnvelope() async {
        let runtime = makeRuntime()
        // message_start carries real input + a small output placeholder; the
        // authoritative cumulative output lands only in message_delta.
        runtime.consumeStreamEvent(
            Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 12, outputTokens: 5))
        runtime.consumeStreamEvent(Message2Fixtures.streamMessageDelta(outputTokens: 1556))
        await wait(for: runtime) { runtime.turnUsage.outputTokens == 1556 }

        XCTAssertEqual(runtime.turnUsage.inputTokens, 12)
        XCTAssertEqual(runtime.turnUsage.outputTokens, 1556)

        // GROUND TRUTH (ThinkingUsageSmoke): the finalized `.assistant` envelope
        // carries the SAME output placeholder (5), not the real total. It must
        // not regress the authoritative figure message_delta already delivered.
        let final = Message2Fixtures.assistantWithUsage(
            messageId: "m1", text: "done", inputTokens: 12, outputTokens: 5)
        runtime.receive(final, mode: .live)
        XCTAssertEqual(runtime.turnUsage.inputTokens, 12)
        XCTAssertEqual(
            runtime.turnUsage.outputTokens, 1556,
            "the placeholder in the final envelope must not clobber the real total")
    }

    /// A `system.thinking_tokens` arriving during the thinking phase folds its
    /// cumulative estimate into the running output and pushes it through the
    /// imperative `onTurnUsageChange` sink (no observation).
    func testThinkingTokensSystemMessageDrivesOutputViaImperativeSink() async {
        let runtime = makeRuntime()
        var pushed: [TurnTokenUsage] = []
        runtime.onTurnUsageChange = { pushed.append($0) }

        runtime.consumeStreamEvent(
            Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 2465, outputTokens: 5))
        // Redacted-thinking progress (cumulative estimate climbs).
        runtime.receive(
            Message2Fixtures.systemThinkingTokens(estimatedTokens: 200, estimatedTokensDelta: 200), mode: .live)
        runtime.receive(
            Message2Fixtures.systemThinkingTokens(estimatedTokens: 900, estimatedTokensDelta: 700), mode: .live)

        XCTAssertEqual(runtime.turnUsage.outputTokens, 900, "thinking estimate folded into output")
        XCTAssertEqual(runtime.turnUsage.inputTokens, 2465)
        XCTAssertEqual(
            pushed.last?.outputTokens, 900,
            "the imperative sink fired synchronously with the latest total")

        // Authoritative total supersedes the estimate.
        runtime.consumeStreamEvent(Message2Fixtures.streamMessageDelta(outputTokens: 1752))
        await wait(for: runtime) { runtime.turnUsage.outputTokens == 1752 }
    }
}

import AgentSDK
import XCTest

@testable import ccterm

/// A `FrameTicker` the tests step by hand. The display-driven `TimerFrameTicker`
/// can't run as a CI merge gate (see cctermTests/CLAUDE.md), so the typewriter
/// reveal is driven deterministically: feed deltas, then `tick(dt:)`.
@MainActor
final class ManualFrameTicker: FrameTicker {
    private var onTick: ((Double) -> Void)?
    private(set) var running = false

    func start(_ onTick: @escaping (Double) -> Void) {
        self.onTick = onTick
        running = true
    }
    func stop() {
        onTick = nil
        running = false
    }

    /// Advance one frame with the given elapsed seconds.
    func tick(_ dt: Double) { onTick?(dt) }
}

/// Drives `SessionRuntime`'s partial-message path directly: stream events fold
/// into a provisional preview entry typed out one glyph at a time by the
/// typewriter, and the finalized `.assistant` envelope converges onto the same
/// entry id once the head catches up. No CLI subprocess, no real frames —
/// `consumeStreamEvent` / `receive` and a `ManualFrameTicker` are driven directly.
@MainActor
final class SessionRuntimeStreamingTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func makeRuntime() -> (SessionRuntime, ManualFrameTicker) {
        let ticker = ManualFrameTicker()
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            frameTicker: ticker)
        return (runtime, ticker)
    }

    /// Wait for the coalesced usage flush (a scheduled `Task { @MainActor }`)
    /// to run by polling on a condition.
    private func wait(for runtime: SessionRuntime, until cond: @escaping () -> Bool) async {
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in cond() }, object: nil)
        await fulfillment(of: [exp], timeout: 2)
    }

    // MARK: - Text preview

    func testTextDeltasCreateProvisionalPreviewEntry() {
        let (runtime, _) = makeRuntime()
        runtime.consumeStreamEvent(Message2Fixtures.streamMessageStart(messageId: "m1"))
        runtime.consumeStreamEvent(Message2Fixtures.streamTextDelta(index: 0, text: "Hello, world."))

        // The first frame paints synchronously, so the provisional entry exists
        // in the same runloop turn as the delta (before any envelope can race it).
        XCTAssertEqual(runtime.messages.count, 1)
        guard case .single(let s) = runtime.messages[0], case .remote(let m) = s.payload,
            case .assistant(let a) = m
        else { return XCTFail("expected a provisional assistant single") }
        XCTAssertEqual(a.message?.id, "m1")
        XCTAssertNotNil(runtime.streamingPreviewEntryIds["m1"])
    }

    /// A short, fast reply whose finalized envelope lands in the same runloop
    /// batch as its first delta — before any frame fires — must still converge
    /// onto the provisional entry, never append a duplicate. (The synchronous
    /// first frame is what guarantees the preview exists by envelope time.)
    func testShortMessageEnvelopeBeforeAnyTickConverges() {
        let (runtime, ticker) = makeRuntime()
        runtime.consumeStreamEvent(Message2Fixtures.streamMessageStart(messageId: "m1"))
        runtime.consumeStreamEvent(Message2Fixtures.streamTextDelta(index: 0, text: "Yes"))
        let previewId = runtime.messages[0].id

        // Envelope arrives immediately — no manual frame stepped yet.
        runtime.receive(Message2Fixtures.assistantText("Yes", messageId: "m1"), mode: .live)
        ticker.tick(1.0)  // drain the reveal → deferred swap runs

        XCTAssertEqual(runtime.messages.count, 1, "no duplicate entry")
        XCTAssertEqual(runtime.messages[0].id, previewId)
        XCTAssertNil(runtime.streamingPreviewEntryIds["m1"])
    }

    func testRevealIsIncrementalNotWholeChunk() {
        let (runtime, ticker) = makeRuntime()
        runtime.consumeStreamEvent(Message2Fixtures.streamMessageStart(messageId: "m1"))
        runtime.consumeStreamEvent(
            Message2Fixtures.streamTextDelta(index: 0, text: String(repeating: "x", count: 40)))

        // A single short frame reveals only a few glyphs — not the whole chunk.
        ticker.tick(1.0 / 60.0)
        let partial = revealedText(runtime)
        XCTAssertGreaterThan(partial.count, 0)
        XCTAssertLessThan(partial.count, 40, "the 40-char chunk must not pop in at once")

        // Keep ticking → it converges to the full chunk.
        for _ in 0..<60 { ticker.tick(1.0 / 60.0) }
        XCTAssertEqual(revealedText(runtime).count, 40)
    }

    func testFinalEnvelopeDefersUntilTypewriterCatchesUp() {
        let (runtime, ticker) = makeRuntime()
        runtime.consumeStreamEvent(Message2Fixtures.streamMessageStart(messageId: "m1"))
        runtime.consumeStreamEvent(Message2Fixtures.streamTextDelta(index: 0, text: "Hello"))

        // Partial reveal — creates the preview entry + mapping, head still trails.
        ticker.tick(0.05)
        XCTAssertEqual(runtime.messages.count, 1)
        let previewId = runtime.messages[0].id
        XCTAssertNotNil(runtime.streamingPreviewEntryIds["m1"])

        // The finalized envelope arrives mid-type → the swap is deferred.
        runtime.receive(
            Message2Fixtures.assistantText("Hello there!", messageId: "m1"), mode: .live)
        XCTAssertNotNil(
            runtime.streamingPreviewEntryIds["m1"],
            "finalize is parked until the head catches up")
        guard case .single(let mid) = runtime.messages[0], case .remote(let mm) = mid.payload,
            case .assistant(let ma) = mm, ma.message?.content?.count == 1
        else { return XCTFail("still the provisional single-text preview") }

        // Tick to completion → the typewriter performs the swap.
        ticker.tick(1.0)
        XCTAssertEqual(runtime.messages.count, 1, "reuse the preview entry, no duplicate")
        XCTAssertEqual(runtime.messages[0].id, previewId, "entry id preserved → block ids converge")
        XCTAssertNil(
            runtime.streamingPreviewEntryIds["m1"], "preview mapping consumed on convergence")
    }

    func testCaughtUpFinalEnvelopeConvergesImmediately() {
        let (runtime, ticker) = makeRuntime()
        runtime.consumeStreamEvent(Message2Fixtures.streamMessageStart(messageId: "m1"))
        runtime.consumeStreamEvent(Message2Fixtures.streamTextDelta(index: 0, text: "Hi"))
        // Fully reveal "Hi" first so the head is caught up when the envelope lands.
        ticker.tick(1.0)
        let previewId = runtime.messages[0].id

        runtime.receive(Message2Fixtures.assistantText("Hi", messageId: "m1"), mode: .live)

        XCTAssertEqual(runtime.messages.count, 1)
        XCTAssertEqual(runtime.messages[0].id, previewId)
        XCTAssertNil(
            runtime.streamingPreviewEntryIds["m1"],
            "already-caught-up finalize swaps synchronously, no deferral")
    }

    func testNonStreamedAssistantStillAppendsNormally() {
        // No preview was created for "m2" → the finalized envelope appends as
        // before. (Guards that the convergence path is gated on an existing
        // preview and doesn't disturb non-streamed sessions.)
        let (runtime, _) = makeRuntime()
        runtime.receive(Message2Fixtures.assistantText("plain", messageId: "m2"), mode: .live)
        XCTAssertEqual(runtime.messages.count, 1)
        guard case .single(let s) = runtime.messages[0], case .remote = s.payload else {
            return XCTFail("expected a remote assistant single")
        }
    }

    func testNewTurnResetsStreamingState() async {
        let (runtime, ticker) = makeRuntime()
        runtime.consumeStreamEvent(
            Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 10, outputTokens: 5))
        runtime.consumeStreamEvent(Message2Fixtures.streamTextDelta(index: 0, text: "stuff"))
        ticker.tick(0.05)
        await wait(for: runtime) { !runtime.turnUsage.isEmpty }

        runtime.resetStreamingTurn()
        XCTAssertTrue(runtime.turnUsage.isEmpty)
        XCTAssertTrue(runtime.streamingPreviewEntryIds.isEmpty)
        XCTAssertNil(runtime.activeReveal)
        XCTAssertFalse(ticker.running, "the ticker is stopped on turn reset")
    }

    // MARK: - Turn token usage

    func testTurnUsageTracksStreamThenFinalEnvelope() async {
        let (runtime, _) = makeRuntime()
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
        let (runtime, _) = makeRuntime()
        var pushed: [TurnTokenUsage] = []
        runtime.onTurnUsageChange = { pushed.append($0) }

        runtime.consumeStreamEvent(
            Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 2465, outputTokens: 5))
        // Redacted-thinking progress (cumulative estimate climbs).
        runtime.receive(
            Message2Fixtures.systemThinkingTokens(estimatedTokens: 200, estimatedTokensDelta: 200),
            mode: .live)
        runtime.receive(
            Message2Fixtures.systemThinkingTokens(estimatedTokens: 900, estimatedTokensDelta: 700),
            mode: .live)

        XCTAssertEqual(runtime.turnUsage.outputTokens, 900, "thinking estimate folded into output")
        XCTAssertEqual(runtime.turnUsage.inputTokens, 2465)
        XCTAssertEqual(
            pushed.last?.outputTokens, 900,
            "the imperative sink fired synchronously with the latest total")

        // Authoritative total supersedes the estimate.
        runtime.consumeStreamEvent(Message2Fixtures.streamMessageDelta(outputTokens: 1752))
        await wait(for: runtime) { runtime.turnUsage.outputTokens == 1752 }
    }

    // MARK: - Helpers

    /// The text of the current provisional preview entry's first text block.
    private func revealedText(_ runtime: SessionRuntime) -> String {
        guard case .single(let s)? = runtime.messages.last, case .remote(let m) = s.payload,
            case .assistant(let a) = m, let blocks = a.message?.content
        else { return "" }
        for block in blocks {
            if case .text(let t) = block { return t.text ?? "" }
        }
        return ""
    }
}

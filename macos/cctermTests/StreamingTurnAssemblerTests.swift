import AgentSDK
import XCTest

@testable import ccterm

/// Pure-logic tests for `StreamingTurnAssembler` — folds SDK partial-message
/// stream events into accumulated text + turn token usage. No SDK subprocess,
/// no MainActor, fully parallel-safe.
final class StreamingTurnAssemblerTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Text accumulation

    func testTextDeltasAccumulateInOrder() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1"))
        a.consume(Message2Fixtures.streamTextDelta(index: 0, text: "Hello"))
        a.consume(Message2Fixtures.streamTextDelta(index: 0, text: ", world"))
        XCTAssertEqual(a.currentText, "Hello, world")
    }

    func testTextChangedFlagOnlyOnTextDelta() {
        var a = StreamingTurnAssembler()
        XCTAssertTrue(a.consume(Message2Fixtures.streamMessageStart(messageId: "m1")).startedMessage)
        let textOutcome = a.consume(Message2Fixtures.streamTextDelta(index: 0, text: "hi"))
        XCTAssertTrue(textOutcome.textChanged)
        let thinkingOutcome = a.consume(Message2Fixtures.streamThinkingDelta(index: 1, thinking: "pondering"))
        XCTAssertFalse(thinkingOutcome.textChanged, "thinking deltas must not change visible text")
        XCTAssertEqual(a.currentText, "hi", "thinking text must not leak into the rendered text")
    }

    func testThinkingAndToolDeltasAreIgnoredForText() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1"))
        a.consume(Message2Fixtures.streamThinkingDelta(index: 0, thinking: "let me think"))
        a.consume(Message2Fixtures.streamInputJSONDelta(index: 1, partialJSON: "{\"path\":"))
        XCTAssertEqual(a.currentText, "", "only text_delta should accumulate")
    }

    func testInterleavedTextBlocksJoinWithBlankLine() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1"))
        a.consume(Message2Fixtures.streamTextDelta(index: 0, text: "before tool"))
        // index 1 would be a tool_use (ignored); a later text block lands at 2.
        a.consume(Message2Fixtures.streamTextDelta(index: 2, text: "after tool"))
        XCTAssertEqual(a.currentText, "before tool\n\nafter tool")
    }

    func testNewMessageResetsTextButKeepsTurnUsage() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 10, outputTokens: 0))
        a.consume(Message2Fixtures.streamTextDelta(index: 0, text: "first message"))
        let start2 = a.consume(Message2Fixtures.streamMessageStart(messageId: "m2", inputTokens: 5, outputTokens: 0))
        XCTAssertTrue(start2.startedMessage)
        XCTAssertEqual(a.currentText, "", "text resets when a new message starts")
        XCTAssertEqual(a.currentMessageId, "m2")
        XCTAssertEqual(a.turnUsage.inputTokens, 15, "usage accumulates across messages")
    }

    // MARK: - Token usage

    func testInputTokensExcludeCache() {
        var a = StreamingTurnAssembler()
        // The fixture only seeds input/output; in production the wire also
        // carries cache_creation/cache_read which the assembler never reads.
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 42, outputTokens: 3))
        XCTAssertEqual(a.turnUsage.inputTokens, 42)
        XCTAssertEqual(a.turnUsage.outputTokens, 3)
    }

    func testMessageDeltaUpdatesOutputCumulatively() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 10, outputTokens: 1))
        a.consume(Message2Fixtures.streamMessageDelta(outputTokens: 20))
        a.consume(Message2Fixtures.streamMessageDelta(outputTokens: 55))
        XCTAssertEqual(a.turnUsage.inputTokens, 10, "input survives message_delta (which omits it)")
        XCTAssertEqual(a.turnUsage.outputTokens, 55, "output is the latest cumulative value, not a sum")
    }

    func testTurnUsageSumsAcrossMessages() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 10, outputTokens: 0))
        a.consume(Message2Fixtures.streamMessageDelta(outputTokens: 30))
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m2", inputTokens: 7, outputTokens: 0))
        a.consume(Message2Fixtures.streamMessageDelta(outputTokens: 12))
        XCTAssertEqual(a.turnUsage.inputTokens, 17)
        XCTAssertEqual(a.turnUsage.outputTokens, 42)
    }

    // MARK: - Live output estimate (claude.app parity)

    /// Text deltas grow a CJK-weighted output estimate so the `↓` counter
    /// climbs while the message streams (claude.app parity), above the
    /// `message_start` placeholder.
    func testTextDeltasGrowOutputEstimate() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 10, outputTokens: 5))
        XCTAssertEqual(a.turnUsage.outputTokens, 5, "only the wire placeholder so far")
        // 200 ASCII chars * 0.3/char = 60 estimated tokens.
        let out = a.consume(
            Message2Fixtures.streamTextDelta(index: 0, text: String(repeating: "word ", count: 40)))
        XCTAssertTrue(out.textChanged)
        XCTAssertTrue(out.usageChanged, "a growing estimate requests a flush")
        XCTAssertEqual(a.turnUsage.outputTokens, 60, "output climbs with the text estimate")
        XCTAssertEqual(a.currentText, String(repeating: "word ", count: 40))
    }

    /// CJK text counts denser (1.0/char) than Latin (0.3/char).
    func testCJKTextCountsDenser() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 1, outputTokens: 1))
        a.consume(Message2Fixtures.streamTextDelta(index: 0, text: String(repeating: "答", count: 50)))
        XCTAssertEqual(a.turnUsage.outputTokens, 50, "50 CJK chars * 1.0 = 50 tokens")
    }

    /// Raw `thinking_delta` stream events stay a no-op (thinking is accounted
    /// via `system.thinking_tokens`, not the redacted stream delta).
    func testThinkingDeltaStreamEventIsNoop() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 5, outputTokens: 1))
        let out = a.consume(
            Message2Fixtures.streamThinkingDelta(
                index: 0, thinking: String(repeating: "想", count: 50)))
        XCTAssertTrue(out.isNoop, "raw thinking_delta changes nothing")
        XCTAssertEqual(a.turnUsage.outputTokens, 1, "raw thinking_delta never moves usage")
        XCTAssertEqual(a.currentText, "", "thinking never leaks into the rendered text")
    }

    /// Text estimate and thinking estimate are **additive** in the displayed
    /// output (output = text + thinking, until the authoritative total wins).
    func testTextAndThinkingEstimatesAreAdditive() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 2465, outputTokens: 5))
        a.recordThinkingEstimate(cumulativeEstimate: 900)
        a.consume(Message2Fixtures.streamTextDelta(index: 0, text: String(repeating: "x", count: 400)))  // 120 tokens
        XCTAssertEqual(a.turnUsage.outputTokens, 1020, "max(5, 120 text + 900 thinking)")
    }

    /// The authoritative `message_delta` total overtakes the estimate via `max`
    /// — it never snaps the counter down (claude.app parity).
    func testAuthoritativeOutputOvertakesEstimate() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 10, outputTokens: 5))
        a.consume(Message2Fixtures.streamTextDelta(index: 0, text: String(repeating: "x", count: 400)))  // 120
        XCTAssertEqual(a.turnUsage.outputTokens, 120, "estimate climbs")
        a.consume(Message2Fixtures.streamMessageDelta(outputTokens: 1556))
        XCTAssertEqual(a.turnUsage.outputTokens, 1556, "authoritative total overtakes the estimate")
    }

    /// GROUND TRUTH (ThinkingUsageSmoke): the finalized `.assistant` envelope
    /// re-states the SAME small `output_tokens` placeholder as `message_start`
    /// (5), never the real total. `recordUsage` keeps a high-water mark so the
    /// placeholder can't drag the authoritative message_delta figure back down.
    func testFinalEnvelopePlaceholderDoesNotRegressOutput() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 2465, outputTokens: 5))
        a.consume(Message2Fixtures.streamMessageDelta(outputTokens: 1556))
        XCTAssertEqual(a.turnUsage.outputTokens, 1556)
        // The finalized envelope reconciles with the placeholder (5).
        let changed = a.recordUsage(messageId: "m1", input: 2465, output: 5)
        XCTAssertFalse(changed, "a non-raising reconcile reports no change (no spurious flush)")
        XCTAssertEqual(a.turnUsage.outputTokens, 1556, "placeholder must not clobber the real total")
        XCTAssertEqual(a.turnUsage.inputTokens, 2465)
    }

    // MARK: - Thinking estimate folded into output

    /// `recordThinkingEstimate` (CLI `system.thinking_tokens.estimated_tokens`,
    /// cumulative) climbs the current message's output during the redacted
    /// thinking phase; the authoritative `message_delta` total then supersedes
    /// it (it's larger — it includes thinking + text).
    func testThinkingEstimateFoldsIntoOutputThenAuthoritativeWins() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 2465, outputTokens: 5))
        XCTAssertEqual(a.turnUsage.outputTokens, 5, "placeholder only, before any thinking")

        // Cumulative thinking estimate climbs (and never regresses).
        XCTAssertTrue(a.recordThinkingEstimate(cumulativeEstimate: 200))
        XCTAssertEqual(a.turnUsage.outputTokens, 200, "output climbs with the thinking estimate")
        XCTAssertTrue(a.recordThinkingEstimate(cumulativeEstimate: 900))
        XCTAssertEqual(a.turnUsage.outputTokens, 900)
        XCTAssertFalse(
            a.recordThinkingEstimate(cumulativeEstimate: 750),
            "a lower cumulative (e.g. a new thinking block) never lowers output")
        XCTAssertEqual(a.turnUsage.outputTokens, 900)

        // Authoritative total (includes thinking) supersedes the estimate.
        a.consume(Message2Fixtures.streamMessageDelta(outputTokens: 1752))
        XCTAssertEqual(a.turnUsage.outputTokens, 1752)
        XCTAssertEqual(a.turnUsage.inputTokens, 2465)
    }

    /// With no `message_start` yet, there's no current message to attribute the
    /// estimate to — it's dropped (returns false, no change).
    func testThinkingEstimateBeforeMessageStartIsDropped() {
        var a = StreamingTurnAssembler()
        XCTAssertFalse(a.recordThinkingEstimate(cumulativeEstimate: 500))
        XCTAssertTrue(a.turnUsage.isEmpty)
    }

    func testResetClearsEverything() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 10, outputTokens: 5))
        a.consume(Message2Fixtures.streamTextDelta(index: 0, text: "stuff"))
        a.reset()
        XCTAssertEqual(a.currentText, "")
        XCTAssertNil(a.currentMessageId)
        XCTAssertTrue(a.turnUsage.isEmpty)
    }

    // MARK: - TurnTokenUsage formatting

    func testAbbreviate() {
        XCTAssertEqual(TurnTokenUsage.abbreviate(0), "0")
        XCTAssertEqual(TurnTokenUsage.abbreviate(999), "999")
        XCTAssertEqual(TurnTokenUsage.abbreviate(1000), "1k")
        XCTAssertEqual(TurnTokenUsage.abbreviate(1234), "1.2k")
        XCTAssertEqual(TurnTokenUsage.abbreviate(1_500_000), "1.5M")
    }

    func testCompactLabelNilWhenEmpty() {
        XCTAssertNil(TurnTokenUsage.zero.compactLabel)
        XCTAssertEqual(
            TurnTokenUsage(inputTokens: 1200, outputTokens: 340).compactLabel,
            "↑1.2k ↓340")
    }
}

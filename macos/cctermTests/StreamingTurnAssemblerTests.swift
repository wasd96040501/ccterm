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

    // MARK: - Live output estimate

    /// Text deltas grow the output estimate before any authoritative
    /// `message_delta` lands, so the counter moves during the message body.
    func testTextDeltasGrowLiveOutputEstimate() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 10, outputTokens: 1))
        XCTAssertEqual(a.turnUsage.outputTokens, 1, "only the placeholder so far")
        // A long ASCII chunk pushes the estimate above the placeholder.
        let chunk = String(repeating: "word ", count: 40)  // 200 chars
        let out = a.consume(Message2Fixtures.streamTextDelta(index: 0, text: chunk))
        XCTAssertTrue(out.usageChanged, "a growing estimate must request a flush")
        XCTAssertGreaterThan(
            a.turnUsage.outputTokens, 1, "estimate climbs while the message streams")
    }

    /// Thinking deltas count toward `output_tokens`, so the estimate must
    /// reflect them too (the user sees the counter move during thinking).
    func testThinkingDeltasGrowLiveOutputEstimate() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 5, outputTokens: 1))
        let out = a.consume(
            Message2Fixtures.streamThinkingDelta(
                index: 0, thinking: String(repeating: "想", count: 50)))
        XCTAssertTrue(out.usageChanged, "thinking grows the output estimate")
        XCTAssertGreaterThan(a.turnUsage.outputTokens, 1)
        XCTAssertEqual(a.currentText, "", "thinking still never leaks into the rendered text")
    }

    /// The authoritative `message_delta` total takes over exactly — an
    /// over-eager estimate can't pin the displayed value above the truth.
    func testAuthoritativeOutputOverridesEstimate() {
        var a = StreamingTurnAssembler()
        a.consume(Message2Fixtures.streamMessageStart(messageId: "m1", inputTokens: 10, outputTokens: 1))
        a.consume(
            Message2Fixtures.streamTextDelta(
                index: 0, text: String(repeating: "x", count: 400)))
        XCTAssertGreaterThan(a.turnUsage.outputTokens, 1, "estimate is live")
        a.consume(Message2Fixtures.streamMessageDelta(outputTokens: 7))
        XCTAssertEqual(
            a.turnUsage.outputTokens, 7,
            "authoritative total wins outright — estimate no longer applies")
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

import AgentSDK
import XCTest

@testable import ccterm

/// Regression for the `[stream_text, tool] → [tool]` disappearance bug.
///
/// The CLI streams an assistant turn as one `message_start`, then splits the
/// **same** `message.id` into separate finalized envelopes — a text-only one
/// and a tool-only one — that share that id (captured by `PartialMessagesSmoke`
/// for a "say something, then Read a file" turn).
///
/// `streamingPreviewEntryIds` is keyed by `message.id`. When the text finalize
/// arrives *before the typewriter has finished revealing* it is deferred
/// (parked on the reveal) and the preview mapping is NOT yet consumed. The
/// next, tool-only envelope shares the id, so without a guard it would converge
/// onto the text preview entry via `.replaceAssistant` and swap the entry's
/// text payload for the tool payload — the streamed text vanishes, leaving only
/// the tool row.
///
/// The fix: a groupable (tool-only) finalize never claims a text preview entry;
/// it appends as its own tool group. Driven through the production
/// `SessionRuntime` → `Session.wireRuntimeMessagesSink` → bridge →
/// `Transcript2Controller` stack, replaying the exact captured ordering.
@MainActor
final class TranscriptStreamTextToolReplayTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private let m1 = "msg_M1_shared_text_and_tool"
    private let m2 = "msg_M2_second_text"
    private let toolUseId = "toolu_replay_0001"

    private func assistantText(_ text: String, messageId: String) -> Message2 {
        Message2Fixtures.assistantText(text, messageId: messageId)
    }

    /// Finalized assistant envelope carrying exactly one tool_use block,
    /// reusing `messageId` — the captured "same msg.id, split into two
    /// messages" behavior.
    private func assistantTool(messageId: String, toolUseId: String) -> Message2 {
        Message2Fixtures.assistantContent(
            messageId: messageId,
            content: [
                [
                    "type": "tool_use",
                    "id": toolUseId,
                    "name": "Read",
                    "input": ["file_path": "/etc/hostname"],
                ]
            ])
    }

    private func paragraphCount(_ runtime: SessionRuntime) -> Int {
        runtime.messages.flatMap { MessageEntryBlockBuilder.entryBlocks($0) }
            .filter { if case .paragraph = $0.kind { return true } else { return false } }
            .count
    }

    private func toolGroupCount(_ runtime: SessionRuntime) -> Int {
        runtime.messages.flatMap { MessageEntryBlockBuilder.entryBlocks($0) }
            .filter { if case .toolGroup = $0.kind { return true } else { return false } }
            .count
    }

    private func makeStack() -> (SessionRuntime, ManualFrameTicker, ccterm.Session) {
        let ticker = ManualFrameTicker()
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            frameTicker: ticker)
        let session = ccterm.Session(runtime: runtime, cliClientFactory: { _ in FakeCLIClient() })
        return (runtime, ticker, session)
    }

    /// The bug-trigger ordering: the text finalize and the tool finalize both
    /// arrive **while the typewriter is still revealing** (no drain between
    /// them). Before the fix, the tool envelope hijacked the text preview entry
    /// and the streamed text was replaced by the tool. After: both survive.
    func testToolFinalizeMidRevealDoesNotReplaceStreamedText() {
        let (runtime, ticker, session) = makeStack()

        // M1 text streams in but is NOT drained — typewriter head still trails.
        runtime.consumeStreamEvent(Message2Fixtures.streamMessageStart(messageId: m1))
        runtime.consumeStreamEvent(
            Message2Fixtures.streamTextDelta(index: 0, text: "I'll read the file now."))
        XCTAssertEqual(paragraphCount(runtime), 1, "preview text is on screen")

        // Finalized [text] M1 arrives mid-reveal → deferred (preview mapping
        // intentionally not consumed yet).
        runtime.receive(assistantText("I'll read the file now.", messageId: m1), mode: .live)

        // Tool-only [tool_use] M1 (SAME msg.id) arrives next.
        runtime.receive(assistantTool(messageId: m1, toolUseId: toolUseId), mode: .live)

        // Drain the typewriter — the parked text finalize swaps in.
        ticker.tick(10.0)

        runtime.receive(
            Message2Fixtures.userToolResult(toolUseId: toolUseId, text: "no such file"),
            mode: .live)

        XCTAssertEqual(paragraphCount(runtime), 1, "streamed text survives the tool finalize")
        XCTAssertEqual(toolGroupCount(runtime), 1, "tool group is present")
        XCTAssertEqual(
            session.controller.blockIds.count, 2,
            "controller holds text + toolGroup — text not dropped")
    }

    /// Full text → tool → text turn drained between each step (the typewriter
    /// keeps up). This path already worked; it's the companion that guards
    /// against regressing the drained ordering.
    func testTextToolTextDrainedKeepsAllBlocks() {
        let (runtime, ticker, session) = makeStack()

        runtime.consumeStreamEvent(Message2Fixtures.streamMessageStart(messageId: m1))
        runtime.consumeStreamEvent(
            Message2Fixtures.streamTextDelta(index: 0, text: "I'll read the file now."))
        ticker.tick(10.0)
        runtime.receive(assistantText("I'll read the file now.", messageId: m1), mode: .live)
        ticker.tick(10.0)
        runtime.receive(assistantTool(messageId: m1, toolUseId: toolUseId), mode: .live)
        runtime.receive(
            Message2Fixtures.userToolResult(toolUseId: toolUseId, text: "no such file"),
            mode: .live)
        runtime.consumeStreamEvent(Message2Fixtures.streamMessageStart(messageId: m2))
        runtime.consumeStreamEvent(Message2Fixtures.streamTextDelta(index: 0, text: "该文件不存在。"))
        ticker.tick(10.0)
        runtime.receive(assistantText("该文件不存在。", messageId: m2), mode: .live)
        ticker.tick(10.0)
        runtime.receive(Message2Fixtures.result(), mode: .live)

        XCTAssertEqual(paragraphCount(runtime), 2, "both streamed texts survive")
        XCTAssertEqual(toolGroupCount(runtime), 1, "tool group is present")
        XCTAssertEqual(
            session.controller.blockIds.count, 3,
            "controller holds text#1 + toolGroup + text#2 — none dropped")
    }
}

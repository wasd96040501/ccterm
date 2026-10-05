import AgentSDK
import XCTest

@testable import ccterm

/// `SessionState.apply(_:)`, event by event — a pure fold over what a live
/// CLI says.
final class SessionStateTests: XCTestCase {
    private var state = SessionState(transcript: Transcript(messages: []))

    override func setUp() {
        state.didBeginLaunch()
        state.didLaunch(Self.initialization())
    }

    /// An `initialize` answer with `json` as its body.
    static func initialization(_ json: String = "{}") -> InitializationResult {
        try! JSONDecoder().decode(InitializationResult.self, from: Data(json.utf8))
    }

    // MARK: - Events as the CLI writes them

    private func line(_ json: String) -> SessionEvent {
        .message(Message(jsonLine: Data(json.utf8))!)
    }

    private func prompt(_ text: String, uuid: String = "u1") -> SessionEvent {
        line(
            #"{"type":"user","uuid":"\#(uuid)","session_id":"s","parent_tool_use_id":null,"isReplay":true,"message":{"role":"user","content":"\#(text)"}}"#
        )
    }

    private func reply(_ blocks: String, id: String = "m1", uuid: String = "a1", parent: String? = nil) -> SessionEvent
    {
        let parent = parent.map { "\"\($0)\"" } ?? "null"
        return line(
            #"{"type":"assistant","uuid":"\#(uuid)","session_id":"s","parent_tool_use_id":\#(parent),"message":{"id":"\#(id)","model":"m","role":"assistant","content":[\#(blocks)]}}"#
        )
    }

    private func stream(_ event: String, parent: String? = nil) -> SessionEvent {
        let parent = parent.map { "\"\($0)\"" } ?? "null"
        return line(
            #"{"type":"stream_event","uuid":"e","session_id":"s","parent_tool_use_id":\#(parent),"event":\#(event)}"#)
    }

    private func start(_ id: String = "m1") -> SessionEvent {
        stream(#"{"type":"message_start","message":{"id":"\#(id)","model":"m","role":"assistant","content":[]}}"#)
    }

    private func blockStart(_ index: Int, _ block: String) -> SessionEvent {
        stream(#"{"type":"content_block_start","index":\#(index),"content_block":\#(block)}"#)
    }

    private func textDelta(_ index: Int, _ text: String) -> SessionEvent {
        stream(#"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":"\#(text)"}}"#)
    }

    private var stop: SessionEvent { stream(#"{"type":"message_stop"}"#) }

    private let textBlock = #"{"type":"text","text":""}"#
    private let toolBlock = #"{"type":"tool_use","id":"t1","name":"Bash","input":{}}"#

    private func texts(_ message: AssistantMessage?) -> [String] {
        (message?.content ?? []).compactMap(\.text)
    }

    private func request(_ id: String, call: String = "t1") -> PermissionRequest {
        PermissionRequest(id: id, toolName: "Bash", toolUseID: call, input: ["command": "ls"], onRespond: { _ in })
    }

    // MARK: - Messages

    func testAMessageGoesIntoTheTranscript() {
        state.apply(prompt("hi"))
        state.apply(reply(#"{"type":"text","text":"hello"}"#))
        XCTAssertEqual(state.transcript.messages.count, 2)
    }

    func testResultsAndStatusAreNotTheConversation() {
        state.apply(
            line(
                #"{"type":"result","subtype":"success","is_error":false,"uuid":"r","session_id":"s","result":"x","num_turns":1}"#
            ))
        state.apply(line(#"{"type":"system","subtype":"status","uuid":"x","session_id":"s"}"#))
        XCTAssertTrue(state.transcript.messages.isEmpty)
    }

    func testASubagentsMessagesAreNotTheConversation() {
        state.apply(reply(#"{"type":"text","text":"inside"}"#, parent: "toolu_agent"))
        XCTAssertTrue(state.transcript.messages.isEmpty)
    }

    // MARK: - Streaming

    func testAResponseStreamsIntoPartial() {
        state.apply(start())
        XCTAssertEqual(state.partial?.messageID, "m1")
        state.apply(blockStart(0, textBlock))
        state.apply(textDelta(0, "Hel"))
        state.apply(textDelta(0, "lo"))
        XCTAssertEqual(texts(state.partial), ["Hello"])
        XCTAssertTrue(state.transcript.messages.isEmpty)
    }

    func testAFinishedBlockLeavesPartialAndJoinsTheTranscript() {
        state.apply(start())
        state.apply(blockStart(0, textBlock))
        state.apply(textDelta(0, "Hello"))
        state.apply(reply(#"{"type":"text","text":"Hello"}"#))
        XCTAssertEqual(state.partial?.content.count, 0, "the block is in the transcript, not twice")
        XCTAssertEqual(state.transcript.messages.count, 1)
    }

    func testTheNextBlockOfTheResponseStillStreamsAfterTheFirstFinished() {
        state.apply(start())
        state.apply(blockStart(0, textBlock))
        state.apply(textDelta(0, "One"))
        state.apply(reply(#"{"type":"text","text":"One"}"#, uuid: "a1"))
        state.apply(blockStart(1, textBlock))
        state.apply(textDelta(1, "Two"))
        XCTAssertEqual(texts(state.partial), ["Two"])
    }

    func testAToolCallIsPreparingUntilItsBlockFinishes() {
        state.apply(start())
        state.apply(blockStart(0, toolBlock))
        state.apply(
            stream(
                #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\""}}"#
            ))
        guard case .toolUse(let call)? = state.partial?.content.first else { return XCTFail("no tool_use block") }
        XCTAssertEqual(call.id, "t1")
        XCTAssertEqual(call.input, .object([:]))
    }

    func testTheResponseEndsWhenItStoppedAndEverythingFinished() {
        state.apply(start())
        state.apply(blockStart(0, textBlock))
        state.apply(textDelta(0, "Hi"))
        state.apply(stop)
        XCTAssertNotNil(state.partial, "a block not finished yet still shows")
        state.apply(reply(#"{"type":"text","text":"Hi"}"#))
        XCTAssertNil(state.partial)
    }

    func testAStoppedResponseWhoseBlocksAllFinishedIsGone() {
        state.apply(start())
        state.apply(blockStart(0, textBlock))
        state.apply(textDelta(0, "Hi"))
        state.apply(reply(#"{"type":"text","text":"Hi"}"#))
        state.apply(stop)
        XCTAssertNil(state.partial)
    }

    func testASubagentsStreamNeverFoldsIn() {
        state.apply(start())
        state.apply(blockStart(0, textBlock))
        state.apply(
            stream(
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"inside"}}"#,
                parent: "toolu_agent"))
        state.apply(
            stream(
                #"{"type":"message_start","message":{"id":"m2","model":"m","role":"assistant","content":[]}}"#,
                parent: "toolu_agent"))
        XCTAssertEqual(state.partial?.messageID, "m1")
        XCTAssertEqual(texts(state.partial), [""])
    }

    func testAStreamEventWithoutAResponseIsIgnored() {
        state.apply(textDelta(0, "orphan"))
        XCTAssertNil(state.partial)
    }

    func testTheResultEndsWhateverWasStreaming() {
        state.apply(start())
        state.apply(blockStart(0, textBlock))
        state.apply(
            line(
                #"{"type":"result","subtype":"success","is_error":false,"uuid":"r","session_id":"s","result":"x","num_turns":1}"#
            ))
        XCTAssertNil(state.partial)
    }

    // MARK: - Requests

    func testRequestsComeInOldestFirstAndLeaveWhenCancelled() {
        state.apply(.permissionRequest(request("r1")))
        state.apply(.permissionRequest(request("r2", call: "t2")))
        XCTAssertEqual(state.requests.map(\.id), ["r1", "r2"])
        state.apply(.permissionRequestCancelled(id: "r1"))
        XCTAssertEqual(state.requests.map(\.id), ["r2"])
        state.apply(.permissionRequestCancelled(id: "unknown"))
        XCTAssertEqual(state.requests.map(\.id), ["r2"])
    }

    // MARK: - Turns

    func testATurnRunsFromItsStartToItsResult() {
        XCTAssertNotEqual(state.phase, .responding)
        state.apply(line(#"{"type":"command_lifecycle","command_uuid":"u1","state":"queued"}"#))
        XCTAssertNotEqual(state.phase, .responding)
        state.apply(line(#"{"type":"command_lifecycle","command_uuid":"u1","state":"started"}"#))
        XCTAssertEqual(state.phase, .responding)
        state.apply(
            line(
                #"{"type":"result","subtype":"success","is_error":false,"uuid":"r","session_id":"s","result":"x","num_turns":1}"#
            ))
        XCTAssertNotEqual(state.phase, .responding)
    }

    func testASentPromptRespondsUntilItStartsOrEndsWithoutStarting() {
        state.didSend(LocalPrompt(id: "u1", text: "", delivery: .sent))
        XCTAssertEqual(state.phase, .responding, "responding from the send, before the CLI says so")
        state.apply(line(#"{"type":"command_lifecycle","command_uuid":"u1","state":"refused"}"#))
        XCTAssertNotEqual(state.phase, .responding, "a refused prompt never ran")

        state.didSend(LocalPrompt(id: "u2", text: "", delivery: .sent))
        state.apply(line(#"{"type":"command_lifecycle","command_uuid":"u2","state":"started"}"#))
        state.didSend(LocalPrompt(id: "u3", text: "", delivery: .sent))
        state.apply(line(#"{"type":"command_lifecycle","command_uuid":"u3","state":"cancelled"}"#))
        XCTAssertEqual(state.phase, .responding, "the running turn goes on")
    }

    // MARK: - Activity

    func testAnActivityIsTheMostUrgentThing() {
        XCTAssertEqual(state.activity, .idle)
        state.didSend(LocalPrompt(id: "u1", text: "", delivery: .sent))
        XCTAssertEqual(state.activity, .responding)
        state.apply(.permissionRequest(request("r1")))
        XCTAssertEqual(state.activity, .needsInput)
    }

    func testASessionAtRestHasNoActivity() {
        XCTAssertNil(SessionState(transcript: Transcript(messages: [])).activity)
    }

    // MARK: - Exit

    func testACleanExitIsAtRestNotFailed() {
        state.didSend(LocalPrompt(id: "u1", text: "", delivery: .sent))
        state.apply(.exited(Termination(exitCode: 0, stderr: "")))
        XCTAssertFalse(state.hasProcess)
        XCTAssertNotEqual(state.phase, .responding)
        XCTAssertEqual(state.phase, .atRest)
        XCTAssertNil(state.activity)
    }

    func testAnExitWithAnErrorFailsTheSession() {
        state.apply(start())
        state.apply(.permissionRequest(request("r1")))
        state.apply(.exited(Termination(exitCode: 3, stderr: "fatal: boom")))
        XCTAssertEqual(state.activity, .failed(message: "\(String(localized: "Exit code \(3)")) · fatal: boom"))
        XCTAssertTrue(state.requests.isEmpty, "nothing waits for an answer a dead CLI can't take")
        XCTAssertNil(state.partial)
    }
}

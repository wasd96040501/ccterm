import AgentSDK
import DisplayModels
import XCTest

@testable import ccterm

/// What a live session's state adds to the page: the streaming reply, calls
/// still preparing, calls waiting on a request.
final class TranscriptPageBuilderLiveTests: XCTestCase {

    private func partial(_ blocks: [ContentBlock]) -> AssistantMessage {
        AssistantMessage(
            uuid: "p", sessionID: "s", messageID: "mp", model: "m", content: blocks,
            timestamp: Date(timeIntervalSince1970: 1_700_000_100))
    }

    private func request(
        _ id: String, _ name: String = "Bash", input: String = #"{"command":"make"}"#, reason: String? = nil
    )
        -> PermissionRequest
    {
        PermissionRequest(
            toolName: name, toolUseID: id, input: MessageScript.json(input), decisionReason: reason, onRespond: { _ in }
        )
    }

    private func page(
        _ script: MessageScript, partial: AssistantMessage? = nil, requests: [PermissionRequest] = []
    ) -> [TranscriptEntry] {
        var builder = TranscriptPageBuilder(
            messages: script.messages, workingDirectory: "/r", partial: partial, requests: requests)
        return builder.build()
    }

    private func calls(_ entries: [TranscriptEntry]) -> [ToolCall] {
        entries.flatMap { entry -> [ToolCall] in
            if case .run(let run) = entry { run.items.flatMap(\.calls) } else { [] }
        }
    }

    func testTheStreamingTextIsAReplyUnderTheIdItsFinishedBlockWillGet() {
        var s = MessageScript()
        s.prompt("Hi")
        s.reply("One.")
        let entries = page(s, partial: partial([.text("Two, so f")]))
        XCTAssertEqual(entries.map(\.id), ["0", "1.0", "2.0"])
        XCTAssertEqual(entries.last, .reply(id: "2.0", markdown: "Two, so f"))
    }

    func testAThinkingBlockTakesItsIdAndShowsNothing() {
        var s = MessageScript()
        s.prompt("Hi")
        let entries = page(s, partial: partial([.thinking("hm"), .text("Answer")]))
        XCTAssertEqual(entries.map(\.id), ["0", "2.0"])
    }

    func testAnEmptyStreamingTextShowsNothingYet() {
        var s = MessageScript()
        s.prompt("Hi")
        XCTAssertEqual(page(s, partial: partial([.text("")])).map(\.id), ["0"])
    }

    func testAStreamingCallIsPreparingInTheRunItWouldJoin() {
        var s = MessageScript()
        s.call("c1", "Read", #"{"file_path":"/r/A.swift"}"#)
        s.result("c1")
        let use = ToolUseBlock(id: "c2", name: "Bash", input: MessageScript.json("{}"))
        let entries = page(s, partial: partial([.toolUse(use)]))
        XCTAssertEqual(entries.map(\.id), ["c1"])
        XCTAssertEqual(calls(entries).map(\.state), [.done, .preparing])
    }

    func testAStreamingQuestionShowsNothingUntilItsInputIsWhole() {
        let s = MessageScript()
        let use = ToolUseBlock(id: "q", name: "AskUserQuestion", input: MessageScript.json("{}"))
        XCTAssertEqual(page(s, partial: partial([.toolUse(use)])), [])
    }

    func testACallWithARequestIsWaitingWithTheCLIsReason() {
        var s = MessageScript()
        s.call("c1", "Bash", #"{"command":"make"}"#)
        let entries = page(s, requests: [request("c1", reason: "Not on the allow list")])
        XCTAssertEqual(calls(entries).map(\.state), [.waiting(reason: "Not on the allow list")])
    }

    func testARequestForACallWithAResultIsIgnored() {
        var s = MessageScript()
        s.call("c1", "Bash", #"{"command":"make"}"#)
        s.result("c1")
        XCTAssertEqual(calls(page(s, requests: [request("c1")])).map(\.state), [.done])
    }

    func testAWaitingQuestionAndPlanKeepTheirOwnEntries() {
        var s = MessageScript()
        s.call("q", "AskUserQuestion", #"{"questions":[]}"#)
        let entries = page(s, requests: [request("q", "AskUserQuestion", input: #"{"questions":[]}"#)])
        guard case .question(let question, _) = entries.first else { return XCTFail("\(entries)") }
        XCTAssertEqual(question.tile, Tile(glyph: .question, state: .waiting))
    }

    func testARequestWhoseCallIsNotOnThePageIsAnApprovalAtTheEnd() {
        var s = MessageScript()
        s.prompt("Go")
        s.reply("Working.")
        let entries = page(s, requests: [request("sub1", reason: "Subagent asks")])
        XCTAssertEqual(entries.map(\.id), ["0", "1.0", "sub1"])
        let waiting = calls(entries)
        XCTAssertEqual(waiting.map(\.state), [.waiting(reason: "Subagent asks")])
        XCTAssertEqual(waiting[0].use.input["command"]?.stringValue, "make")
    }

    func testAPartialCallWithARequestIsWaitingWithTheRequestsInput() {
        let s = MessageScript()
        let use = ToolUseBlock(id: "c2", name: "Bash", input: MessageScript.json("{}"))
        let entries = page(s, partial: partial([.toolUse(use)]), requests: [request("c2")])
        let waiting = calls(entries)
        XCTAssertEqual(waiting.map(\.state), [.waiting(reason: nil)])
        XCTAssertEqual(waiting[0].use.input["command"]?.stringValue, "make")
    }
}

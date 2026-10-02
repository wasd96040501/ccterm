import XCTest

@testable import AgentSDK

final class AssistantStreamingTests: XCTestCase {
    private func event(_ event: StreamEvent.Event, parent: String? = nil) -> StreamEvent {
        StreamEvent(uuid: "e1", sessionID: "s1", parentToolUseID: parent, event: event)
    }

    func testOnlyMessageStartBeginsAResponse() {
        XCTAssertNil(AssistantMessage(streamStart: event(.ping)))
        XCTAssertNil(AssistantMessage(streamStart: event(.contentBlockStop(index: 0))))
        let start = AssistantMessage(
            streamStart: event(.messageStart(messageID: "msg_1", model: "haiku", usage: nil), parent: "toolu_1"))
        XCTAssertEqual(start?.uuid, "e1")
        XCTAssertEqual(start?.sessionID, "s1")
        XCTAssertEqual(start?.messageID, "msg_1")
        XCTAssertEqual(start?.model, "haiku")
        XCTAssertEqual(start?.parentToolUseID, "toolu_1")
        XCTAssertEqual(start?.content, [])
    }

    func testBlocksGrowByTheirDeltas() throws {
        var message = try XCTUnwrap(
            AssistantMessage(streamStart: event(.messageStart(messageID: "m", model: "x", usage: nil))))
        let tool = ToolUseBlock(id: "t", name: "Bash", input: .object([:]))
        let events: [StreamEvent.Event] = [
            .contentBlockStart(index: 0, block: .thinking("")),
            .contentBlockDelta(index: 0, delta: .thinking("hm")),
            .contentBlockDelta(index: 0, delta: .signature("sig")),
            .contentBlockStop(index: 0),
            .contentBlockStart(index: 1, block: .text("")),
            .contentBlockDelta(index: 1, delta: .text("Hel")),
            .contentBlockDelta(index: 1, delta: .text("lo")),
            .contentBlockStop(index: 1),
            .contentBlockStart(index: 2, block: .toolUse(tool)),
            .contentBlockDelta(index: 2, delta: .inputJSON("{\"command\":")),
            .contentBlockDelta(index: 2, delta: .text("stray")),
            .contentBlockStop(index: 2),
            .messageDelta(stopReason: "tool_use", usage: nil), .messageStop, .ping,
        ]
        for e in events { message.apply(event(e)) }
        XCTAssertEqual(message.content, [.thinking("hm"), .text("Hello"), .toolUse(tool)])
    }

    func testADeltaWithoutAMatchingBlockIsIgnored() throws {
        var message = try XCTUnwrap(
            AssistantMessage(streamStart: event(.messageStart(messageID: "m", model: "x", usage: nil))))
        message.apply(event(.contentBlockDelta(index: 0, delta: .text("x"))))
        XCTAssertEqual(message.content, [])
    }
}

import XCTest

@testable import AgentSDK

/// `Transcript.append`: a live session's messages kept by the file's rules.
final class TranscriptAppendTests: XCTestCase {
    private func user(_ uuid: String, _ text: String, replay: Bool = true, parent: String? = nil) -> Message {
        .user(
            UserMessage(
                uuid: uuid, parentToolUseID: parent, content: [.text(text)], isReplay: replay))
    }

    private func command(_ uuid: String, _ name: String) -> Message {
        user(uuid, "<command-name>\(name)</command-name><command-args></command-args>")
    }

    private func output(_ uuid: String, _ text: String) -> Message {
        user(uuid, "<local-command-stdout>\(text)</local-command-stdout>")
    }

    private func assistant(_ uuid: String, _ text: String, parent: String? = nil) -> Message {
        .assistant(
            AssistantMessage(
                uuid: uuid, sessionID: "s", messageID: "m-\(uuid)", model: "m", content: [.text(text)],
                parentToolUseID: parent))
    }

    private func uuids(_ transcript: Transcript) -> [String] {
        transcript.messages.map {
            switch $0 {
            case .user(let m): return m.uuid ?? "-"
            case .assistant(let m): return m.uuid
            default: return "boundary"
            }
        }
    }

    func testKeepsConversationAndIgnoresTheRest() {
        var transcript = Transcript(messages: [])
        transcript.append(user("u1", "hi"))
        transcript.append(.system(.compactBoundary(.init(trigger: "manual", preTokens: 5, postTokens: nil))))
        transcript.append(assistant("a1", "hello"))
        transcript.append(.streamEvent(StreamEvent(uuid: "e", sessionID: "s", event: .ping)))
        XCTAssertEqual(uuids(transcript), ["u1", "boundary", "a1"])
    }

    func testASubagentsMessagesAreDropped() {
        var transcript = Transcript(messages: [])
        transcript.append(user("u1", "hi"))
        transcript.append(assistant("a1", "inner", parent: "toolu_1"))
        transcript.append(user("u2", "inner", parent: "toolu_1"))
        XCTAssertEqual(uuids(transcript), ["u1"])
    }

    func testAReplayedPromptIsKeptOnce() {
        var transcript = Transcript(messages: [])
        transcript.append(user("u1", "hi"))
        transcript.append(assistant("a1", "hello"))
        transcript.append(user("u1", "hi"))
        XCTAssertEqual(uuids(transcript), ["u1", "a1"])
    }

    func testACommandsEchoComesBeforeItsOutput() {
        var transcript = Transcript(messages: [user("u0", "earlier")])
        transcript.append(output("o1", "done"))
        transcript.append(command("c1", "/compact"))
        XCTAssertEqual(uuids(transcript), ["u0", "c1", "o1"])
    }

    func testAnEchoGoesBeforeAllOfItsOutputs() {
        var transcript = Transcript(messages: [user("u0", "earlier")])
        transcript.append(output("o1", "a"))
        transcript.append(output("o2", "b"))
        transcript.append(command("c1", "/cost"))
        XCTAssertEqual(uuids(transcript), ["u0", "c1", "o1", "o2"])
    }

    func testASecondCommandDoesNotTakeTheFirstsOutput() {
        var transcript = Transcript(messages: [])
        transcript.append(output("o1", "a"))
        transcript.append(command("c1", "/cost"))
        transcript.append(output("o2", "b"))
        transcript.append(command("c2", "/model"))
        XCTAssertEqual(uuids(transcript), ["c1", "o1", "c2", "o2"])
    }

    func testAPromptAfterOutputIsAppended() {
        var transcript = Transcript(messages: [])
        transcript.append(output("o1", "a"))
        transcript.append(user("u1", "next"))
        XCTAssertEqual(uuids(transcript), ["o1", "u1"])
    }
}

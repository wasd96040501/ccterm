import AgentSDK
import Foundation

@testable import ccterm

/// A session's messages as the CLI records them, written line by line in a
/// test — synthetic, never a real transcript. Each message is a second after
/// the one before unless `wait(_:)` says otherwise.
struct MessageScript {
    private(set) var messages: [Message] = []
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private var count = 0

    var page: TranscriptPage {
        var builder = TranscriptPageBuilder(messages: messages, workingDirectory: "/r")
        return TranscriptPage(entries: builder.build())
    }

    mutating func wait(_ seconds: TimeInterval) {
        clock += seconds
    }

    mutating func prompt(_ text: String) {
        user(text)
    }

    /// A user message with `text` as its only content — markup included.
    mutating func user(_ text: String, origin: String? = nil) {
        messages.append(.user(UserMessage(content: [.text(text)], origin: origin, timestamp: tick())))
    }

    mutating func reply(_ text: String) {
        assistant([.text(text)])
    }

    /// One assistant message calling `name` with `input`, a JSON object.
    mutating func call(_ id: String, _ name: String, _ input: String) {
        assistant([.toolUse(ToolUseBlock(id: id, name: name, input: Self.json(input)))])
    }

    /// One assistant message making several calls at once.
    mutating func calls(_ calls: [(id: String, name: String, input: String)]) {
        assistant(calls.map { .toolUse(ToolUseBlock(id: $0.id, name: $0.name, input: Self.json($0.input))) })
    }

    /// The result of call `id`: the model-facing `text`, and the tool's
    /// structured `output` (a JSON value) when it recorded one.
    mutating func result(_ id: String, _ text: String = "ok", error: Bool = false, output: String? = nil) {
        messages.append(
            .user(
                UserMessage(
                    content: [.toolResult(ToolResultBlock(toolUseID: id, content: [.text(text)], isError: error))],
                    toolUseResult: output.map(Self.json), timestamp: tick())))
    }

    mutating func compacted(trigger: String = "manual", pre: Int = 168_000, post: Int = 14_000) {
        let line =
            #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"\#(trigger)","pre_tokens":\#(pre),"post_tokens":\#(post)}}"#
        messages.append(Message(jsonLine: Data(line.utf8))!)
    }

    mutating func compactionSummary(_ text: String) {
        messages.append(.user(UserMessage(content: [.text(text)], isCompactSummary: true, timestamp: tick())))
    }

    mutating func notification(summary: String, status: String = "completed", toolUseID: String? = nil) {
        let origin = toolUseID.map { "<tool-use-id>\($0)</tool-use-id>" } ?? ""
        user(
            "<task-notification><task-id>t1</task-id>\(origin)<status>\(status)</status><summary>\(summary)</summary></task-notification>",
            origin: "task-notification")
    }

    private mutating func assistant(_ content: [ContentBlock]) {
        count += 1
        messages.append(
            .assistant(
                AssistantMessage(
                    uuid: "a\(count)", sessionID: "s", messageID: "m\(count)", model: "m", content: content,
                    timestamp: tick())))
    }

    private mutating func tick() -> Date {
        clock += 1
        return clock
    }

    static func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}

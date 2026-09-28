import Foundation

/// A user-role message: a prompt, a tool result, or text the CLI injected —
/// ``kind`` says which.
public struct UserMessage: Sendable, Equatable {
    /// `nil` only on messages from very old transcripts.
    public var uuid: String?
    public var sessionID: String?
    /// The `Agent` tool call whose subagent produced this message; `nil` on
    /// the main thread.
    public var parentToolUseID: String?
    /// A bare-string prompt is normalized to one `.text` block. A tool result
    /// carries exactly one `.toolResult` block, sometimes followed by extra
    /// text or image blocks.
    public var content: [ContentBlock]
    /// The tool's structured output for a `.toolResult` message.
    ///
    /// An object on success, a string on failure, and `nil` when the CLI did
    /// not record one (successful calls inside a subagent). Its shape depends
    /// on the tool; see ``toolOutcome(_:)``.
    public var toolUseResult: JSONValue?
    /// `true` when the CLI is echoing a prompt back as it enters a turn. A
    /// prompt sent with ``Session/send(_:)`` comes back with the same
    /// ``uuid``; the CLI also replays prompts it made itself (task
    /// notifications, local command output) with fresh uuids.
    public var isReplay: Bool
    public var timestamp: Date?
    /// Marked on the wire as written by the CLI rather than a person. Read
    /// through ``kind``.
    var isSynthetic: Bool
    /// Marked on the wire as a compaction's summary. Read through ``kind``.
    var isCompactSummary: Bool
    /// Who the wire says wrote it — `"human"`, `"task-notification"`,
    /// `"peer"`, … (`origin.kind`). Read through ``kind``.
    var origin: String?

    public init(
        uuid: String? = nil, sessionID: String? = nil, parentToolUseID: String? = nil, content: [ContentBlock],
        toolUseResult: JSONValue? = nil, isSynthetic: Bool = false, isCompactSummary: Bool = false,
        isReplay: Bool = false, origin: String? = nil, timestamp: Date? = nil
    ) {
        self.uuid = uuid
        self.sessionID = sessionID
        self.parentToolUseID = parentToolUseID
        self.content = content
        self.toolUseResult = toolUseResult
        self.isSynthetic = isSynthetic
        self.isCompactSummary = isCompactSummary
        self.isReplay = isReplay
        self.origin = origin
        self.timestamp = timestamp
    }

    /// The message's `.toolResult` block, if it carries one.
    public var toolResult: ToolResultBlock? {
        for block in content {
            if case .toolResult(let result) = block { return result }
        }
        return nil
    }
}

// MARK: - Decodable

extension UserMessage: Decodable {
    /// Decodes both the stream (snake_case) and on-disk (camelCase) envelopes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let message = try c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "message")
        self.uuid = c.lenient(String.self, "uuid")
        self.sessionID = c.lenient(String.self, "session_id", "sessionId")
        self.parentToolUseID = c.lenient(String.self, "parent_tool_use_id")
        self.content = message.contentBlocks("content") ?? []
        self.toolUseResult = c.lenient(JSONValue.self, "tool_use_result", "toolUseResult")
        self.isSynthetic =
            c.lenient(Bool.self, "isSynthetic") == true || c.lenient(Bool.self, "isMeta") == true
            || c.lenient(Bool.self, "isVisibleInTranscriptOnly") == true
        self.isCompactSummary = c.lenient(Bool.self, "isCompactSummary") == true
        self.isReplay = c.lenient(Bool.self, "isReplay") ?? false
        self.origin = c.lenient(JSONValue.self, "origin")?["kind"]?.stringValue
        self.timestamp = c.timestamp("timestamp")
    }
}

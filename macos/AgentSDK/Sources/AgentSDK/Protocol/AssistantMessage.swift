import Foundation

/// One assistant content block, as the CLI emits it.
///
/// The CLI splits each API response into one envelope per completed content
/// block. Envelopes of the same response share ``messageID``, and each one
/// carries a single block in ``content``. Group by ``messageID`` to rebuild
/// the whole response.
public struct AssistantMessage: Sendable, Equatable {
    public var uuid: String
    public var sessionID: String
    /// The API response id shared by all blocks of one response.
    public var messageID: String
    /// Model id; `"<synthetic>"` marks a message the CLI made up itself (an
    /// API error notice or local command output).
    public var model: String
    public var content: [ContentBlock]
    /// Only reliable on the final block of a response, and often `nil` even
    /// there. The turn's stop reason is ``ResultMessage/stopReason``.
    public var stopReason: String?
    /// Per-block snapshot; not final while the response streams.
    public var usage: Usage?
    /// The `Agent` tool call whose subagent produced this message; `nil` on
    /// the main thread.
    public var parentToolUseID: String?
    /// API failure class (`rate_limit`, `authentication_failed`,
    /// `billing_error`, …) when this message reports an API error.
    public var error: String?
    /// `true` when the block was flushed partway through an interrupted
    /// stream.
    public var isAborted: Bool
    /// uuids of earlier messages this one replaces; drop those rows.
    public var supersedes: [String]
    public var timestamp: Date?
    /// The effort level the turn ran on (on disk: `effort`) — with ``model``,
    /// what a resume passes again.
    public var effort: Effort? = nil
    /// The advisor's model, when one ran in this turn (`advisorModel`).
    public var advisorModel: String? = nil

    public init(
        uuid: String, sessionID: String, messageID: String, model: String, content: [ContentBlock],
        stopReason: String? = nil, usage: Usage? = nil, parentToolUseID: String? = nil, error: String? = nil,
        isAborted: Bool = false, supersedes: [String] = [], timestamp: Date? = nil
    ) {
        self.uuid = uuid
        self.sessionID = sessionID
        self.messageID = messageID
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
        self.parentToolUseID = parentToolUseID
        self.error = error
        self.isAborted = isAborted
        self.supersedes = supersedes
        self.timestamp = timestamp
    }
}

// MARK: - Decodable

extension AssistantMessage: Decodable {
    /// Decodes both the stream (snake_case) and on-disk (camelCase) envelopes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let message = try c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "message")
        self.uuid = try c.required(String.self, "uuid")
        self.sessionID = c.lenient(String.self, "session_id", "sessionId") ?? ""
        self.messageID = try message.required(String.self, "id")
        self.model = message.lenient(String.self, "model") ?? ""
        self.content = message.contentBlocks("content") ?? []
        self.stopReason = message.lenient(String.self, "stop_reason")
        self.usage = message.lenient(Usage.self, "usage")
        self.parentToolUseID = c.lenient(String.self, "parent_tool_use_id")
        self.error = c.lenient(String.self, "error")
        self.isAborted = c.lenient(Bool.self, "aborted", "isAbortedMidStream") ?? false
        self.supersedes = c.lenient([String].self, "supersedes") ?? []
        self.timestamp = c.timestamp("timestamp")
        self.effort = c.lenient(String.self, "effort").flatMap(Effort.init)
        self.advisorModel = c.lenient(String.self, "advisorModel")
    }
}

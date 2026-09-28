import Foundation

/// The end of a turn. The CLI emits exactly one per turn.
public struct ResultMessage: Sendable, Equatable {
    /// How the turn ended. An interrupted turn can end with any subtype
    /// (usually ``success``); ``ResultMessage/terminalReason`` tells it
    /// apart (`aborted_streaming` or `aborted_tools`).
    public struct Subtype: RawRepresentable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let success = Subtype(rawValue: "success")
        public static let errorDuringExecution = Subtype(rawValue: "error_during_execution")
        public static let errorMaxTurns = Subtype(rawValue: "error_max_turns")
        public static let errorMaxBudgetUSD = Subtype(rawValue: "error_max_budget_usd")
        public static let errorMaxStructuredOutputRetries = Subtype(rawValue: "error_max_structured_output_retries")
    }

    /// A tool call the permission layer refused during the turn.
    public struct PermissionDenial: Sendable, Equatable {
        public var toolName: String
        public var toolUseID: String
        public var toolInput: JSONValue
    }

    public var uuid: String
    public var sessionID: String
    public var subtype: Subtype
    /// `true` for every error subtype, and also for `.success` when the turn
    /// ended on an API error.
    public var isError: Bool
    /// Final assistant text (`.success` only).
    public var result: String?
    /// Error descriptions (error subtypes only).
    public var errors: [String]
    public var stopReason: String?
    /// Finer-grained end reason: `completed`, `aborted_streaming`,
    /// `aborted_tools`, `max_turns`, …
    public var terminalReason: String?
    public var numTurns: Int
    public var durationMS: Int
    public var durationAPIMS: Int
    /// This turn's main-loop usage.
    public var usage: Usage
    /// Session total so far — take the latest value; do not sum.
    public var totalCostUSD: Double
    /// Session totals per model — take the latest value; do not sum.
    public var modelUsage: [String: ModelUsage]
    public var permissionDenials: [PermissionDenial]
    /// The output matching the configured JSON schema, if one was set.
    public var structuredOutput: JSONValue?
    /// uuids of every prompt this turn consumed (see ``UserInput/uuid``).
    public var userMessageUUIDs: [String]
    /// Prompts still queued; greater than zero means another turn follows
    /// without new input.
    public var queuedTurnCount: Int
}

// MARK: - Decodable

extension ResultMessage: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.uuid = c.lenient(String.self, "uuid") ?? ""
        self.sessionID = c.lenient(String.self, "session_id") ?? ""
        self.subtype = Subtype(rawValue: try c.required(String.self, "subtype"))
        self.isError = c.lenient(Bool.self, "is_error") ?? (subtype != .success)
        self.result = c.lenient(String.self, "result")
        self.errors = c.lenient([String].self, "errors") ?? []
        self.stopReason = c.lenient(String.self, "stop_reason")
        self.terminalReason = c.lenient(String.self, "terminal_reason")
        self.numTurns = c.lenient(Int.self, "num_turns") ?? 0
        self.durationMS = c.lenient(Int.self, "duration_ms") ?? 0
        self.durationAPIMS = c.lenient(Int.self, "duration_api_ms") ?? 0
        self.usage = c.lenient(Usage.self, "usage") ?? Usage()
        self.totalCostUSD = c.lenient(Double.self, "total_cost_usd") ?? 0
        self.modelUsage = c.lenient([String: ModelUsage].self, "modelUsage") ?? [:]
        self.permissionDenials = c.lenient([PermissionDenial].self, "permission_denials") ?? []
        self.structuredOutput = c.lenient(JSONValue.self, "structured_output")
        self.userMessageUUIDs =
            c.lenient([String].self, "user_message_uuids")
            ?? c.lenient(String.self, "user_message_uuid").map { [$0] } ?? []
        self.queuedTurnCount = c.lenient(Int.self, "queued_turn_count") ?? 0
    }
}

extension ResultMessage.PermissionDenial: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.toolName = c.lenient(String.self, "tool_name") ?? ""
        self.toolUseID = c.lenient(String.self, "tool_use_id") ?? ""
        self.toolInput = c.lenient(JSONValue.self, "tool_input") ?? .object([:])
    }
}

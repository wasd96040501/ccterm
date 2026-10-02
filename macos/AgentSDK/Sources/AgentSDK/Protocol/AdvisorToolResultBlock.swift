import Foundation

/// The advisor's answer to a ``ServerToolUseBlock`` (`advisor_tool_result`).
public struct AdvisorToolResultBlock: Sendable, Equatable {
    /// The ``ServerToolUseBlock/id`` it answers.
    public var toolUseID: String
    public var content: Content

    public enum Content: Sendable, Equatable {
        /// The advice in the clear (`advisor_result`); a `stopReason` of
        /// `refusal` means it declined to advise.
        case result(text: String, stopReason: String?)
        /// Encrypted advice (`advisor_redacted_result`) — nothing readable;
        /// the usual case.
        case redacted
        /// It couldn't advise (`advisor_tool_result_error`):
        /// `max_uses_exceeded`, `too_many_requests`, `overloaded`,
        /// `prompt_too_long`, `execution_time_exceeded`, `unavailable`.
        case error(code: String)
        case unknown(JSONValue)
    }

    public init(toolUseID: String, content: Content) {
        self.toolUseID = toolUseID
        self.content = content
    }
}

import Foundation

/// How a tool call went, from its recorded result.
public enum ToolOutcome<Output: Sendable>: Sendable {
    /// The tool ran and recorded this output. Some tools report their own
    /// soft failures inside a success (`Tools.TaskUpdate.Output.success`).
    case success(Output)
    /// The call failed, was denied, or was interrupted; the CLI's message.
    case failure(String)
    /// The tool succeeded but its structured output is not available: the
    /// CLI does not record it for calls inside a subagent, and outputs of a
    /// shape this SDK does not know land here too. Fall back to
    /// ``ToolResultBlock/content``.
    case unavailable
}

extension ToolOutcome: Equatable where Output: Equatable {}

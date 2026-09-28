import Foundation

/// A long-running tool call is still working.
public struct ToolProgress: Sendable, Equatable {
    /// The tool call this reports on.
    public var toolUseID: String
    public var toolName: String
    /// The `Agent` tool call whose subagent runs the tool; `nil` on the main
    /// thread.
    public var parentToolUseID: String?
    public var elapsedTimeSeconds: Int
    /// The background task running the tool, if any.
    public var taskID: String?
}

extension ToolProgress: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let id = try c.required(String.self, "tool_use_id")
        let parent = c.lenient(String.self, "parent_tool_use_id")
        // Heartbeats carry a synthetic `<id>-heartbeat-<n>` id and put the
        // real tool call id in `parent_tool_use_id`.
        if c.lenient(Bool.self, "heartbeat") == true, let parent {
            self.toolUseID = parent
            self.parentToolUseID = nil
        } else {
            self.toolUseID = id
            self.parentToolUseID = parent
        }
        self.toolName = c.lenient(String.self, "tool_name") ?? ""
        self.elapsedTimeSeconds = c.lenient(Int.self, "elapsed_time_seconds") ?? 0
        self.taskID = c.lenient(String.self, "task_id")
    }
}

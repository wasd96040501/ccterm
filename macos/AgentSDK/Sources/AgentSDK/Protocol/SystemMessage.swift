import Foundation

/// A `system` message: session state and progress signals.
///
/// Subtypes this SDK does not model arrive as ``other(subtype:raw:)``; the
/// CLI adds new ones regularly and consumers should ignore what they do not
/// recognize.
public enum SystemMessage: Sendable, Equatable {
    /// Session configuration. Emitted at the start of **every** turn; the
    /// newest one wins.
    case initialized(Initialized)
    /// Status change: `requesting`, `compacting`, or back to idle, and/or a
    /// new permission mode.
    case status(Status)
    /// Compaction happened here; earlier history was summarized.
    case compactBoundary(CompactBoundary)
    /// The API call failed and will be retried.
    case apiRetry(APIRetry)
    /// Estimated progress while the model thinks with redacted output.
    case thinkingTokens(ThinkingTokens)
    case taskStarted(TaskStarted)
    case taskProgress(TaskProgress)
    /// A partial update; merge into the state built from ``taskStarted(_:)``.
    case taskUpdated(TaskUpdated)
    /// A background task ended.
    case taskNotification(TaskNotification)
    /// The full set of background tasks; replaces any previous set.
    case backgroundTasksChanged([BackgroundTask])
    /// A tool call was refused automatically, without a permission prompt.
    case permissionDenied(PermissionDenied)
    /// The full slash-command list; replaces any previous list.
    case commandsChanged([SlashCommand])
    /// The session's name, at startup when it has one and after each rename
    /// (`session_title_changed`).
    case sessionTitleChanged(title: String)
    case other(subtype: String, raw: JSONValue)
}

extension SystemMessage {
    public struct Initialized: Sendable, Equatable {
        public var sessionID: String
        public var cwd: String
        public var model: String
        /// `nil` when the CLI reports a mode this SDK does not know.
        public var permissionMode: PermissionMode?
        public var tools: [String]
        public var mcpServers: [MCPServer]
        public var slashCommands: [String]
        public var agents: [String]
        public var skills: [String]
        public var outputStyle: String
        public var apiKeySource: String
        public var claudeCodeVersion: String
    }

    public struct MCPServer: Sendable, Equatable {
        public var name: String
        /// `connected`, `failed`, `needs-auth`, `pending`, `disabled`, …
        public var status: String
    }

    public struct Status: Sendable, Equatable {
        /// `requesting`, `compacting`, or `nil` for idle.
        public var status: String?
        /// Set when the permission mode changed.
        public var permissionMode: PermissionMode?
    }

    public struct CompactBoundary: Sendable, Equatable {
        /// `manual` or `auto`.
        public var trigger: String
        public var preTokens: Int
        public var postTokens: Int?
    }

    public struct APIRetry: Sendable, Equatable {
        public var attempt: Int
        public var maxRetries: Int
        public var retryDelayMS: Int
        /// HTTP status, when the request got a response.
        public var errorStatus: Int?
        public var error: String
    }

    public struct ThinkingTokens: Sendable, Equatable {
        public var estimatedTokens: Int
        public var estimatedTokensDelta: Int
    }

    public struct TaskStarted: Sendable, Equatable {
        public var taskID: String
        /// The tool call that started the task.
        public var toolUseID: String?
        public var description: String
        /// `local_bash`, `local_agent`, `local_workflow`, …
        public var taskType: String
        public var subagentType: String?
        public var prompt: String?
    }

    public struct TaskProgress: Sendable, Equatable {
        public var taskID: String
        public var toolUseID: String?
        public var description: String
        public var totalTokens: Int
        public var toolUses: Int
        public var durationMS: Int
        public var lastToolName: String?
        public var summary: String?
    }

    /// Only the fields that changed are set.
    public struct TaskUpdated: Sendable, Equatable {
        public var taskID: String
        public var status: String?
        public var description: String?
        public var error: String?
        public var isBackgrounded: Bool?
        /// When the task ended.
        public var endTime: Date?
    }

    public struct TaskNotification: Sendable, Equatable {
        public var taskID: String
        public var toolUseID: String?
        /// `completed`, `failed`, or `stopped`.
        public var status: String
        public var outputFile: String
        public var summary: String
    }

    public struct BackgroundTask: Sendable, Equatable {
        public var taskID: String
        public var taskType: String
        public var description: String
    }

    public struct PermissionDenied: Sendable, Equatable {
        public var toolName: String
        public var toolUseID: String
        public var message: String
        public var agentID: String?
    }
}

// MARK: - Decodable

extension SystemMessage: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let subtype = c.lenient(String.self, "subtype") ?? ""
        do {
            switch subtype {
            case "init":
                self = .initialized(
                    Initialized(
                        sessionID: c.lenient(String.self, "session_id") ?? "",
                        cwd: c.lenient(String.self, "cwd") ?? "",
                        model: c.lenient(String.self, "model") ?? "",
                        permissionMode: c.lenient(String.self, "permissionMode").flatMap(PermissionMode.init),
                        tools: c.lenient([String].self, "tools") ?? [],
                        mcpServers: c.lenientArray(MCPServer.self, "mcp_servers") ?? [],
                        slashCommands: c.lenient([String].self, "slash_commands") ?? [],
                        agents: c.lenient([String].self, "agents") ?? [],
                        skills: c.lenient([String].self, "skills") ?? [],
                        outputStyle: c.lenient(String.self, "output_style") ?? "",
                        apiKeySource: c.lenient(String.self, "apiKeySource") ?? "",
                        claudeCodeVersion: c.lenient(String.self, "claude_code_version") ?? ""))
            case "status":
                self = .status(
                    Status(
                        status: c.lenient(String.self, "status"),
                        permissionMode: c.lenient(String.self, "permissionMode").flatMap(PermissionMode.init)))
            case "compact_boundary":
                let meta = try c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "compact_metadata")
                self = .compactBoundary(
                    CompactBoundary(
                        trigger: meta.lenient(String.self, "trigger") ?? "",
                        preTokens: meta.lenient(Int.self, "pre_tokens") ?? 0,
                        postTokens: meta.lenient(Int.self, "post_tokens")))
            case "api_retry":
                self = .apiRetry(
                    APIRetry(
                        attempt: c.lenient(Int.self, "attempt") ?? 0,
                        maxRetries: c.lenient(Int.self, "max_retries") ?? 0,
                        retryDelayMS: c.lenient(Int.self, "retry_delay_ms") ?? 0,
                        errorStatus: c.lenient(Int.self, "error_status"),
                        error: c.lenient(String.self, "error") ?? ""))
            case "thinking_tokens":
                self = .thinkingTokens(
                    ThinkingTokens(
                        estimatedTokens: c.lenient(Int.self, "estimated_tokens") ?? 0,
                        estimatedTokensDelta: c.lenient(Int.self, "estimated_tokens_delta") ?? 0))
            case "task_started":
                self = .taskStarted(
                    TaskStarted(
                        taskID: try c.required(String.self, "task_id"),
                        toolUseID: c.lenient(String.self, "tool_use_id"),
                        description: c.lenient(String.self, "description") ?? "",
                        taskType: c.lenient(String.self, "task_type") ?? "",
                        subagentType: c.lenient(String.self, "subagent_type"),
                        prompt: c.lenient(String.self, "prompt")))
            case "task_progress":
                let usage = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "usage")
                self = .taskProgress(
                    TaskProgress(
                        taskID: try c.required(String.self, "task_id"),
                        toolUseID: c.lenient(String.self, "tool_use_id"),
                        description: c.lenient(String.self, "description") ?? "",
                        totalTokens: usage?.lenient(Int.self, "total_tokens") ?? 0,
                        toolUses: usage?.lenient(Int.self, "tool_uses") ?? 0,
                        durationMS: usage?.lenient(Int.self, "duration_ms") ?? 0,
                        lastToolName: c.lenient(String.self, "last_tool_name"),
                        summary: c.lenient(String.self, "summary")))
            case "task_updated":
                let patch = try c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: "patch")
                self = .taskUpdated(
                    TaskUpdated(
                        taskID: try c.required(String.self, "task_id"),
                        status: patch.lenient(String.self, "status"),
                        description: patch.lenient(String.self, "description"),
                        error: patch.lenient(String.self, "error"),
                        isBackgrounded: patch.lenient(Bool.self, "is_backgrounded"),
                        endTime: patch.lenient(Double.self, "end_time").map { Date(timeIntervalSince1970: $0 / 1000) }))
            case "task_notification":
                self = .taskNotification(
                    TaskNotification(
                        taskID: try c.required(String.self, "task_id"),
                        toolUseID: c.lenient(String.self, "tool_use_id"),
                        status: c.lenient(String.self, "status") ?? "",
                        outputFile: c.lenient(String.self, "output_file") ?? "",
                        summary: c.lenient(String.self, "summary") ?? ""))
            case "background_tasks_changed":
                // Replace semantics: a missing list must not read as "no tasks".
                _ = try c.required([JSONValue].self, "tasks")
                self = .backgroundTasksChanged(c.lenientArray(BackgroundTask.self, "tasks") ?? [])
            case "permission_denied":
                self = .permissionDenied(
                    PermissionDenied(
                        toolName: c.lenient(String.self, "tool_name") ?? "",
                        toolUseID: c.lenient(String.self, "tool_use_id") ?? "",
                        message: c.lenient(String.self, "message") ?? "",
                        agentID: c.lenient(String.self, "agent_id")))
            case "commands_changed":
                _ = try c.required([JSONValue].self, "commands")
                self = .commandsChanged(c.lenientArray(SlashCommand.self, "commands") ?? [])
            case "session_title_changed":
                self = .sessionTitleChanged(title: try c.required(String.self, "title"))
            default:
                self = .other(subtype: subtype, raw: decoder.rawValue())
            }
        } catch {
            self = .other(subtype: subtype, raw: decoder.rawValue())
        }
    }
}

extension SystemMessage.MCPServer: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.name = try c.required(String.self, "name")
        self.status = c.lenient(String.self, "status") ?? ""
    }
}

extension SystemMessage.BackgroundTask: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.taskID = try c.required(String.self, "task_id")
        self.taskType = c.lenient(String.self, "task_type") ?? ""
        self.description = c.lenient(String.self, "description") ?? ""
    }
}

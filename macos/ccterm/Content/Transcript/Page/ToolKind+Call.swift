import AgentSDK
import DisplayModels
import Foundation

/// Which kind a tool call is: one line per tool here (Transcript/CLAUDE.md,
/// "Adding a tool").
nonisolated extension ToolKind {
    /// The advisor's server tool use (`server_tool_use` named `advisor`).
    static let advisorName = "advisor"

    /// The kind of `call`. A `Write` is a change when it replaced a file the
    /// result says existed, a creation otherwise — before its result, a
    /// creation, which is what 92 % of them are.
    init(_ call: ToolUseBlock, result: UserMessage?) {
        switch call.name {
        case "Bash", "PowerShell", "TaskOutput", "BashOutput", "TaskStop", "KillShell":
            self = .command
        case "Edit", "MultiEdit", "NotebookEdit":
            self = .change
        case Tools.Write.name:
            if case .success(let output)? = result?.toolOutcome(Tools.Write.self), !output.isNewFile {
                self = .change
            } else {
                self = .create
            }
        case "Read", "ListMcpResources", "ReadMcpResource":
            self = .read
        case "Grep", "Glob", "ToolSearch", "LS", "LSP":
            self = .search
        case "WebFetch", "WebSearch":
            self = .web
        case "Agent", "Task", "Workflow", "ListAgents":
            self = .agent
        case "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TodoWrite":
            self = .tasks
        case "CronCreate", "CronDelete", "CronList", "ScheduleWakeup", "Monitor", "RemoteTrigger":
            self = .schedule
        case Self.advisorName:
            self = .advisor
        case "Skill":
            self = .skill
        case "EnterWorktree", "ExitWorktree":
            self = .worktree
        case "SendMessage":
            self = .message
        case "PushNotification", "SendUserMessage", "SendUserFile":
            self = .notify
        default:
            self = .other
        }
    }
}

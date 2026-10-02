import AgentSDK
import Foundation

/// What a tool call did, in the fifteen words the transcript uses for work
/// (design/transcript/README.md "Kinds"). Tool names are many and change; the
/// kinds are what a reader asks about.
///
/// The order of the cases is the order of the run sentence's clauses, and the
/// order in which a run's tile picks its kind: what changed first, what was
/// only looked at last.
nonisolated enum ToolKind: Int, Sendable, Equatable, Comparable, CaseIterable {
    case change
    case create
    case command
    case agent
    case web
    case search
    case read
    case tasks
    case schedule
    /// The advisor, a server tool the reply itself carries.
    case advisor
    case skill
    case worktree
    case message
    /// Tools that tell the reader something outside the transcript: a
    /// notification, a message, a file.
    case notify
    case other

    static func < (lhs: ToolKind, rhs: ToolKind) -> Bool { lhs.rawValue < rhs.rawValue }

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

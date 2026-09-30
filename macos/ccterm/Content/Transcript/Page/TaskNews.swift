import AgentSDK
import Foundation

/// A background task's news — a `<task-notification>` — as one work line
/// (design/transcript/04-background.md).
nonisolated struct TaskNews: Sendable, Equatable, Identifiable {
    let id: String
    let report: TaskReport
    /// What the task was. Read from the call that started it when the page
    /// has that call, else from the report.
    let kind: Kind
    var line: WorkLine

    enum Kind: Sendable, Equatable {
        case command
        case agent
        case workflow
        case monitor
        case other
    }

    /// The call that started the task — what ↖ reveals, when it is on this
    /// page.
    var origin: String? { report.toolUseID }
}

nonisolated extension TaskNews.Kind {
    /// What the task was: the tool that started it, else what the report
    /// carries — a workflow's agent counts, a monitor's event.
    init(report: TaskReport, origin: ToolUseBlock?) {
        switch origin?.name {
        case "Bash": self = .command
        case "Agent", "Task": self = .agent
        case "Workflow": self = .workflow
        case "Monitor": self = .monitor
        default:
            if report.usage?.agentCount != nil {
                self = .workflow
            } else if report.event != nil {
                self = .monitor
            } else if report.taskType == "remote_agent" || report.result != nil {
                self = .agent
            } else {
                self = .other
            }
        }
    }
}

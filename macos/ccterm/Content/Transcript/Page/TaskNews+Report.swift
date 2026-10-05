import AgentSDK
import DisplayModels
import Foundation

nonisolated extension TaskNews {
    /// The news of `report`: the page keeps the report itself beside it
    /// (`NewsRun.reports`), for the document that opens it.
    init(id: String, report: TaskReport, kind: Kind, line: WorkLine) {
        self.init(id: id, kind: kind, line: line, origin: report.toolUseID)
    }
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

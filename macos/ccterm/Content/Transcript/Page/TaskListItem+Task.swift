import AgentSDK
import DisplayModels
import Foundation

nonisolated extension TaskListItem.Status {
    /// How the SDK's status is listed; `nil` for a deleted task, which is no line.
    init?(_ status: Tools.TaskStatus) {
        switch status {
        case .pending: self = .pending
        case .inProgress: self = .inProgress
        case .completed: self = .completed
        case .deleted: return nil
        }
    }
}

nonisolated extension TaskListItem {
    /// A task as the SDK reports it; `nil` for a deleted one.
    init?(subject: String, taskStatus: Tools.TaskStatus) {
        guard let status = Status(taskStatus) else { return nil }
        self.init(subject: subject, status: status)
    }
}

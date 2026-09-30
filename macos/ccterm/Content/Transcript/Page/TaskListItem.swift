import AgentSDK
import Foundation

/// One line of the session's task list, as it stood after some call
/// (design/transcript/07-talk.md "Task list").
nonisolated struct TaskListItem: Sendable, Equatable {
    let subject: String
    let status: Tools.TaskStatus
}

import Foundation

/// One line of the session's task list, as it stood after some call
/// (design/transcript/07-talk.md "Task list").
public nonisolated struct TaskListItem: Sendable, Equatable {
    public let subject: String
    public let status: Status

    /// Where the task is. A deleted task is no line.
    public enum Status: Sendable, Equatable {
        case pending
        case inProgress
        case completed
    }

    public init(subject: String, status: Status) {
        self.subject = subject
        self.status = status
    }
}

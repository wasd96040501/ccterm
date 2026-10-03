import Foundation

/// A background task's news — a `<task-notification>` — as one work line
/// (design/transcript/04-background.md).
public nonisolated struct TaskNews: Sendable, Equatable, Identifiable {
    public let id: String
    /// What the task was. Read from the call that started it when the page
    /// has that call, else from the report.
    public let kind: Kind
    public var line: WorkLine
    /// The call that started the task — what ↖ reveals, when it is on this
    /// page.
    public let origin: String?

    public enum Kind: Sendable, Equatable {
        case command
        case agent
        case workflow
        case monitor
        case other
    }

    public init(id: String, kind: Kind, line: WorkLine, origin: String?) {
        self.id = id
        self.kind = kind
        self.line = line
        self.origin = origin
    }
}

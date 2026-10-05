import Foundation

/// What a tool call did, in the fifteen words the transcript uses for work
/// (design/transcript/README.md "Kinds"). Tool names are many and change; the
/// kinds are what a reader asks about.
///
/// The order of the cases is the order of the run sentence's clauses, and the
/// order in which a run's tile picks its kind: what changed first, what was
/// only looked at last.
public nonisolated enum ToolKind: Int, Sendable, Equatable, Comparable, CaseIterable {
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

    public static func < (lhs: ToolKind, rhs: ToolKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

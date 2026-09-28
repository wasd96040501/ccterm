import Foundation

/// One node of the session library: a project, a session, a group of a
/// session's side transcripts, or one side transcript. A value — every scan
/// builds a new tree, and `id` is what stays the same across them.
struct LibraryNode: Identifiable, Hashable, Codable, Sendable {
    enum Kind: Hashable, Codable, Sendable {
        /// A working directory. Sessions run in its worktrees are folded in.
        case project
        /// A session's main transcript.
        case session
        /// A session's subagents.
        case subagents
        /// One workflow run; its children are the agents it spawned.
        case workflow
        /// One subagent's transcript.
        case agent
    }

    /// Stable across scans: a project's directory, a transcript's path, or a
    /// group's path under its session's.
    let id: String
    let kind: Kind
    let title: String
    /// The transcript this node opens; `nil` for a group.
    let transcriptURL: URL?
    let children: [LibraryNode]
}

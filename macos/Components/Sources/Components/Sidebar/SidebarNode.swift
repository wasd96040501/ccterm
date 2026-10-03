import Foundation

/// One row of the sidebar's tree, as it is drawn: a project, a session, a
/// group of a session's side transcripts, or one side transcript. A value —
/// every publish is a new tree, and `id` is what stays the same across them.
public struct SidebarNode: Equatable {
    /// The icon a row draws (`design/sidebar-icons`).
    public enum Glyph: Equatable {
        /// A group: a project, or a session's subagents — the system's folder.
        case folder
        /// A conversation.
        case session
        /// One subagent's transcript.
        case agent
        /// One workflow run.
        case workflow
    }

    /// Stable across publishes; what keeps a row's expansion and selection.
    public var id: String
    public var title: String
    public var toolTip: String
    public var glyph: Glyph
    /// What the row drags as, and whether it is reported when chosen: `nil`
    /// for a group.
    public var transcriptURL: URL?
    /// For a session run in a worktree: the words of the branch glyph drawn
    /// after its title, which shows only then.
    public var worktreeCaption: String?
    public var children: [SidebarNode]

    public init(
        id: String, title: String, toolTip: String, glyph: Glyph, transcriptURL: URL? = nil,
        worktreeCaption: String? = nil, children: [SidebarNode] = []
    ) {
        self.id = id
        self.title = title
        self.toolTip = toolTip
        self.glyph = glyph
        self.transcriptURL = transcriptURL
        self.worktreeCaption = worktreeCaption
        self.children = children
    }
}

import DisplayModels
import Foundation

/// A library node, worded for the sidebar's row.
extension SidebarNode {
    init(_ node: LibraryNode) {
        self.init(
            id: node.id, title: node.title,
            // A project's tooltip is its path; a row's own title may be cut short.
            toolTip: node.kind == .project ? node.id : node.title,
            glyph: Glyph(node.kind), transcriptURL: node.transcriptURL,
            worktreeCaption: node.worktreeBranch.map(SessionTabTitle.worktreeSubtitle(branch:)),
            children: node.children.map(SidebarNode.init))
    }
}

extension SidebarNode.Glyph {
    init(_ kind: LibraryNode.Kind) {
        switch kind {
        case .project, .subagents: self = .folder
        case .session: self = .session
        case .agent: self = .agent
        case .workflow: self = .workflow
        }
    }
}

extension SidebarActivity {
    init(_ activity: SessionState.Activity) {
        switch activity {
        case .idle: self = .idle
        case .responding: self = .responding
        case .needsInput: self = .needsInput
        case .failed(let message): self = .failed(message: message)
        }
    }
}

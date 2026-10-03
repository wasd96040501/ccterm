import DisplayModels
import Foundation

/// What the sidebar reports. Only nodes with a transcript are reported.
@MainActor
public protocol SidebarViewControllerDelegate: AnyObject {
    /// The reader selected a node, by clicking it or moving to it with the
    /// keyboard — a look, not a decision to keep it open.
    func sidebarViewController(_ sidebar: SidebarViewController, didSelect node: SidebarNode)

    /// The reader double-clicked a node, to keep it open.
    func sidebarViewController(_ sidebar: SidebarViewController, didOpen node: SidebarNode)

    /// End Session, from a live session's context menu.
    func sidebarViewController(_ sidebar: SidebarViewController, didRequestEndOf node: SidebarNode)
}

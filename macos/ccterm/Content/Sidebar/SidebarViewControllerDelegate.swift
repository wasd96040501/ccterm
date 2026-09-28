import AppKit

@MainActor
protocol SidebarViewControllerDelegate: AnyObject {
    /// The reader asked to see `node`'s transcript. Sent only for nodes that
    /// have one (`transcriptURL != nil`).
    func sidebarViewController(_ sidebar: SidebarViewController, didOpen node: LibraryNode)
}

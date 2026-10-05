import AppKit

/// The glyphs `design/sidebar-icons` draws, from the package's catalogue: a
/// conversation, a subagent, a workflow run and a worktree's branch, which the
/// transcript's rows and tiles show as the sidebar does.
extension NSImage {
    public static var sidebarSession: NSImage { Bundle.module.image(forResource: "SidebarSession") ?? NSImage() }
    public static var sidebarAgent: NSImage { Bundle.module.image(forResource: "SidebarAgent") ?? NSImage() }
    public static var sidebarWorkflow: NSImage { Bundle.module.image(forResource: "SidebarWorkflow") ?? NSImage() }
    public static var sidebarWorktree: NSImage { Bundle.module.image(forResource: "SidebarWorktree") ?? NSImage() }
}

extension NSColor {
    /// The coral of a conversation waiting for the reader.
    public static var sidebarCoral: NSColor { NSColor(named: "SidebarCoral", bundle: .module) ?? .systemOrange }
}

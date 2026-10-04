import AppKit

/// What the New view draws from the package's catalogue: the design's
/// worktree mark (`design/new-view-icons`, a template image the view tints)
/// and the app icon's art (`design/icon`, one rendition per appearance).
extension NSImage {
    static var newViewWorktree: NSImage { Bundle.module.image(forResource: "NewViewWorktree") ?? NSImage() }
    package static var appIconArt: NSImage { Bundle.module.image(forResource: "AppIconArt") ?? NSImage() }
}

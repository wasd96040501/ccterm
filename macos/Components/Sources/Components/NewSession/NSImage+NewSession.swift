import AppKit

/// What the New view draws from the package's catalogue: the design's chevron
/// and worktree mark (`design/new-view-icons`, template images the view tints)
/// and the app icon's art (`design/icon`, one rendition per appearance).
extension NSImage {
    static var newViewChevron: NSImage { Bundle.module.image(forResource: "NewViewChevron") ?? NSImage() }
    static var newViewWorktree: NSImage { Bundle.module.image(forResource: "NewViewWorktree") ?? NSImage() }
    package static var appIconArt: NSImage { Bundle.module.image(forResource: "AppIconArt") ?? NSImage() }
}

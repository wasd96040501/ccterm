import AppKit

extension NSImage {
    /// Claude's mark in its own colour, from the package's catalogue: what
    /// stands for a claude.ai subscription wherever one is named.
    public static var claudeMark: NSImage { Bundle.module.image(forResource: "ClaudeMark") ?? NSImage() }
}

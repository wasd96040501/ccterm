import AppKit

/// The design's fills the composer draws with (design/transcript/preview.css
/// `--hover`, `--tile`), which AppKit's named fills miss: `quaternarySystemFill`
/// is lighter than `--hover`, and no system fill is `--tile` in both appearances.
extension NSColor {
    /// A chip under the pointer or with its menu up (`--hover`).
    static let composerHover = NSColor(lightAlpha: 0.045, darkAlpha: 0.06)
    /// The disabled action button and the context ring's track (`--tile`).
    static let composerTile = NSColor(lightAlpha: 0.07, darkAlpha: 0.1)

    /// Black at `lightAlpha` in light, white at `darkAlpha` in dark.
    private convenience init(lightAlpha: CGFloat, darkAlpha: CGFloat) {
        self.init(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: darkAlpha) : NSColor(white: 0, alpha: lightAlpha)
        }
    }
}

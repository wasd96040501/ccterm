import AppKit

/// PLACEHOLDERS — the one place the window frame's images are named. Every
/// glyph the frame draws is an image the design builds (`macos/CLAUDE.md`,
/// *Every icon is an image the design builds*): the traffic lights and the
/// back and forward chevrons of the toolbar row. Their `NSImage.windowChrome…`
/// accessors come with the icons stream; until they are merged each is `nil`
/// and the frame draws nothing in its place. To swap, return the accessor
/// here — nothing else in the page names an image.
enum WindowChromeImages {
    /// The three traffic lights as one image, close, minimise, zoom: 14 high
    /// and 60 wide in the Settings window (9 between), 12 high and 52 wide in
    /// the transcript's (8 between).
    static func trafficLights() -> NSImage? { nil }  // NSImage.windowChromeTrafficLights

    /// The toolbar's back chevron, 10 × 16.
    static func back() -> NSImage? { nil }  // NSImage.windowChromeBack

    /// The toolbar's forward chevron, 10 × 16.
    static func forward() -> NSImage? { nil }  // NSImage.windowChromeForward
}

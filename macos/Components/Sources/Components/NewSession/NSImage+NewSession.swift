import AppKit

/// What the New view draws from the package's catalogue: the app icon's art
/// (`design/icon`, one rendition per appearance).
extension NSImage {
    package static var appIconArt: NSImage { Bundle.module.image(forResource: "AppIconArt") ?? NSImage() }
}

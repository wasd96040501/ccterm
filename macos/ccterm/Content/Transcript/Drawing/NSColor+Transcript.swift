import AppKit

/// The design's text colours that AppKit has no name for
/// (design/transcript/preview.css `--green-text`, `--red-text`): darker than
/// `systemGreen` / `systemRed` in light, so small text reads.
extension NSColor {
    /// Lines added; a success in words.
    static let addedText = NSColor(light: 0x248A3D, dark: 0x30D158)
    /// Lines removed; anything that went wrong, in words.
    static let failureText = NSColor(light: 0xD70015, dark: 0xFF6961)

    /// A tint of `color` whose strength differs by appearance
    /// (preview.css `--add-bg`, `--del-bg`, `--add-hl`, `--del-hl`).
    static func wash(_ color: NSColor, light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return color.withAlphaComponent(isDark ? dark : light)
        }
    }

    private convenience init(light: UInt32, dark: UInt32) {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        self.init(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        }
    }
}

import AppKit

/// Visual configuration for the native markdown renderer.
///
/// All sizes/colors flow through this struct so callers can tweak appearance
/// without touching renderer internals. Defaults match existing chat typography
/// (system 13pt body, monospaced 12pt code).
struct MarkdownTheme {

    // MARK: - Typography

    var bodyFontSize: CGFloat = 13
    var codeFontSize: CGFloat = 12

    var headingSizes: [CGFloat] = [22, 19, 16, 14, 13, 12]

    var lineSpacing: CGFloat = 2
    var paragraphSpacing: CGFloat = 8
    var headingSpacingBefore: CGFloat = 10
    var headingSpacingAfter: CGFloat = 4

    // MARK: - Spacing

    var listIndent: CGFloat = 18
    var listItemSpacing: CGFloat = 2
    var blockquoteIndent: CGFloat = 14
    var segmentSpacing: CGFloat = 10

    // MARK: - Derived fonts

    var bodyFont: NSFont { .systemFont(ofSize: bodyFontSize) }

    var codeFont: NSFont {
        .monospacedSystemFont(ofSize: codeFontSize, weight: .regular)
    }

    var inlineCodeFont: NSFont {
        .monospacedSystemFont(ofSize: bodyFontSize * 0.92, weight: .regular)
    }

    func headingFont(level: Int) -> NSFont {
        let clamped = max(1, min(level, headingSizes.count))
        let size = headingSizes[clamped - 1]
        return .systemFont(ofSize: size, weight: .semibold)
    }

    // MARK: - Colors

    var primaryColor: NSColor { .labelColor }
    var secondaryColor: NSColor { .secondaryLabelColor }
    var linkColor: NSColor { .linkColor }

    /// Subtle tint for inline `code` spans.
    var inlineCodeBackground: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(white: 1, alpha: 0.10)
                : NSColor(white: 0, alpha: 0.06)
        }
    }

    /// Stronger tint for block-level code fences.
    var codeBlockBackground: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(sRGB: 27.0 / 255, 31.0 / 255, 38.0 / 255, 1.0)
                : NSColor(sRGB: 246.0 / 255, 248.0 / 255, 250.0 / 255, 1.0)
        }
    }

    var blockquoteTextColor: NSColor { .secondaryLabelColor }
    var blockquoteBarColor: NSColor { .tertiaryLabelColor }

    var tableBorderColor: NSColor { .separatorColor }
    var tableHeaderBackground: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(white: 1, alpha: 0.06)
                : NSColor(white: 0, alpha: 0.04)
        }
    }

    static let `default` = MarkdownTheme()

    /// Hashable subset of the theme used as an attributed-string cache key.
    /// Colors are intentionally excluded: dynamic `NSColor`s aren't `Hashable`
    /// and colorScheme changes already force a full SwiftUI redraw.
    struct Fingerprint: Hashable, Sendable {
        let bodyFontSize: CGFloat
        let codeFontSize: CGFloat
        let headingSizes: [CGFloat]
        let lineSpacing: CGFloat
        let paragraphSpacing: CGFloat
        let headingSpacingBefore: CGFloat
        let headingSpacingAfter: CGFloat
        let listIndent: CGFloat
        let listItemSpacing: CGFloat
        let blockquoteIndent: CGFloat
        let segmentSpacing: CGFloat
    }

    var fingerprint: Fingerprint {
        Fingerprint(
            bodyFontSize: bodyFontSize,
            codeFontSize: codeFontSize,
            headingSizes: headingSizes,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            headingSpacingBefore: headingSpacingBefore,
            headingSpacingAfter: headingSpacingAfter,
            listIndent: listIndent,
            listItemSpacing: listItemSpacing,
            blockquoteIndent: blockquoteIndent,
            segmentSpacing: segmentSpacing)
    }
}

private extension NSColor {
    convenience init(sRGB r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) {
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

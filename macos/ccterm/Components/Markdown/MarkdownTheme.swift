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

    /// h1-h6 font sizes. h4-h6 collapse to h3's size — distinguish by weight only,
    /// matching GitHub / Apple HIG convention where deeper headings stop scaling.
    var headingSizes: [CGFloat] = [22, 19, 16, 16, 16, 16]

    // MARK: - Spacing (three semantic layers)

    /// Section break — extra space above a heading (added on top of l2 segment gap).
    var l1: CGFloat = 16
    /// Block-level — between adjacent segments and between blocks inside a markdown segment.
    var l2: CGFloat = 8
    /// Item-level — between list items.
    var l3Item: CGFloat = 4
    /// Line-level — intra-paragraph line spacing.
    var l3Line: CGFloat = 2

    // MARK: - Layout

    var listIndent: CGFloat = 18
    var blockquoteIndent: CGFloat = 14
    /// Width of the vertical bar in the blockquote SwiftUI segment.
    var blockquoteBarWidth: CGFloat = 4
    /// Gap between the blockquote bar and its content.
    var blockquoteBarGap: CGFloat = 12
    /// Vertical inset inside code/table/math blocks.
    var blockPadding: CGFloat = 8

    /// Corner radius shared by all block-level containers (code, math, table).
    /// Picked so radius/height ≈ 0.05-0.08 — soft-square "information
    /// container" feel without looking like a button or card.
    var blockCornerRadius: CGFloat = 6

    /// Inline code chip: horizontal padding (chip extends past glyph rect by
    /// this much on each side; ≈ 0.33em on a 12pt code font).
    var inlineCodeHPadding: CGFloat = 4
    /// Inline code chip: vertical padding. Kept at 0 — anything > 0 lets the
    /// chip extend past the line fragment's top/bottom and get clipped by the
    /// NSTextView's drawing bounds. The chip already fills the line height,
    /// so 0 still reads as a comfortable container.
    var inlineCodeVPadding: CGFloat = 0
    /// Inline code chip: corner radius (≈ 0.21 of chip height — moderate).
    var inlineCodeCornerRadius: CGFloat = 3
    /// Spacing pushed onto the characters immediately before and after an
    /// inline code run (via NSAttributedString `.kern`) so the chip never
    /// visually overlaps neighbouring glyphs. Must exceed `inlineCodeHPadding`
    /// by enough to absorb the neighbour glyph's LSB — punctuation like `.` and
    /// `,` has a small LSB, so a 1pt gap (kern=padding+1) still reads as the
    /// dot touching the chip. Use +4pt of visual breathing room.
    var inlineCodeSideKern: CGFloat = 8

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

    /// Inner row separator — same width as the outer border but a more muted
    /// color so the body grid reads as one block rather than a busy lattice.
    /// Standard practice: keep the stroke width consistent across borders and
    /// dial only the color/alpha down for inner lines.
    var tableInnerDividerColor: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(white: 1, alpha: 0.10)
                : NSColor(white: 0, alpha: 0.06)
        }
    }

    /// Header row tint — distinctly deeper than the zebra stripe so the header
    /// reads as a separate band rather than just another body row.
    var tableHeaderBackground: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(white: 1, alpha: 0.14)
                : NSColor(white: 0, alpha: 0.08)
        }
    }

    /// Zebra stripe applied to odd body rows. Subtle — only there to make
    /// long rows easier to track horizontally.
    var tableZebraBackground: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(white: 1, alpha: 0.04)
                : NSColor(white: 0, alpha: 0.025)
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
        let l1: CGFloat
        let l2: CGFloat
        let l3Item: CGFloat
        let l3Line: CGFloat
        let listIndent: CGFloat
        let blockquoteIndent: CGFloat
        let blockPadding: CGFloat
    }

    var fingerprint: Fingerprint {
        Fingerprint(
            bodyFontSize: bodyFontSize,
            codeFontSize: codeFontSize,
            headingSizes: headingSizes,
            l1: l1,
            l2: l2,
            l3Item: l3Item,
            l3Line: l3Line,
            listIndent: listIndent,
            blockquoteIndent: blockquoteIndent,
            blockPadding: blockPadding)
    }
}

private extension NSColor {
    convenience init(sRGB r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) {
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

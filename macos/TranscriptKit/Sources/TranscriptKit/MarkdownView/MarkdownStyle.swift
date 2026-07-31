import AppKit

/// Every typographic decision the markdown renderer makes, in one value.
///
/// Gathered here rather than spread across the block types so that "what does a
/// heading look like" is answered once, and so that a block's own file contains
/// only its geometry. Nothing here is public yet: no host has asked to restyle
/// the transcript, and a style struct is a wide surface to commit to before one
/// does.
///
/// The numbers are `NativeTranscript2.BlockStyle`'s, so that a transcript
/// rendered by this package and one rendered by the renderer it replaces are
/// the same picture. Where a value carries a reason there, the reason is
/// repeated here — a constant whose origin is "matched the old one" is a
/// constant nobody can later change with confidence.
struct MarkdownStyle {

    // MARK: - Text

    var bodyFont: NSFont
    var textColor: NSColor
    var secondaryColor: NSColor
    var linkColor: NSColor

    /// Inline code's foreground, and the reason it needs no background: the
    /// hue *is* the signal. A tinted monospaced run reads as code against
    /// surrounding prose without a filled box interrupting the line — and a box
    /// drawn from an attributed `.backgroundColor` spans the line's full
    /// leading, so it sits visibly lower than the glyphs it is meant to wrap.
    ///
    /// The teal matches the shade a function name renders in inside a
    /// highlighted code block, so an inline reference and its definition read as
    /// the same kind of thing.
    var inlineCodeColor: NSColor

    /// h1 26 / h2 22 / h3-h6 18. Markdown's six levels collapse to three visual
    /// tiers — chat content rarely goes deeper than h3, and shrinking the tail
    /// levels toward body size makes them read as emphasis rather than
    /// structure.
    func headingFont(level: Int) -> NSFont {
        let size: CGFloat
        switch max(1, min(6, level)) {
        case 1: size = 26
        case 2: size = 22
        default: size = 18
        }
        return .systemFont(ofSize: size, weight: .semibold)
    }

    /// Monospaced at the surrounding run's size and weight, so inline code
    /// inside a bold run or a heading keeps that run's proportions instead of
    /// dropping to body size mid-line.
    func inlineCodeFont(matching surrounding: NSFont?) -> NSFont {
        let size = surrounding?.pointSize ?? bodyFont.pointSize
        let bold = surrounding?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
        return .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    // MARK: - Blockquote

    /// Left inset of a blockquote's contents — bar width plus the gap after it.
    var quoteIndent: CGFloat
    var quoteBarWidth: CGFloat

    // MARK: - Lists

    var listItemSpacing: CGFloat
    var listMarkerColor: NSColor

    /// Half an em at body size — the gap between the marker column's right edge
    /// and the content's left edge.
    var listMarkerContentGap: CGFloat { bodyFont.pointSize * 0.5 }

    // MARK: - Code blocks

    /// Monospaced at the body point size, so a code block sandwiched between
    /// paragraphs reads as a sibling rather than a tonal shift.
    var codeFont: NSFont { .monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular) }

    /// `#F5F5F7` light / `#2A2A2E` dark — one elevation tier above the window
    /// background in either mode, so the card reads as a raised surface.
    var codeBackgroundColor: NSColor
    var codeBadgeBackgroundColor: NSColor

    /// The "structural" corner tier — data, code, grids. A tight curve reads as
    /// engineering; the soft tier belongs to chat bubbles.
    var codeCornerRadius: CGFloat

    var codeHorizontalPadding: CGFloat
    var codeVerticalPadding: CGFloat

    /// Chrome (the language badge, and the copy button once there is an
    /// interaction layer to hang one on) is an **overlay**: it reserves no
    /// vertical space, and a long first line passes underneath it. The badge's
    /// opaque chip is what keeps it legible when that happens.
    var codeChromeInset: CGFloat
    var codeBadgeFontSize: CGFloat
    var codeBadgeCornerRadius: CGFloat
    var codeBadgeHorizontalPadding: CGFloat

    // MARK: - Default

    static let `default` = MarkdownStyle(
        bodyFont: .systemFont(ofSize: 14, weight: .regular),
        textColor: .labelColor,
        secondaryColor: .secondaryLabelColor,
        linkColor: .linkColor,
        inlineCodeColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x67 / 255, green: 0xB7 / 255, blue: 0xA4 / 255, alpha: 1)
                : NSColor(srgbRed: 0x31 / 255, green: 0x6D / 255, blue: 0x74 / 255, alpha: 1)
        },
        quoteIndent: 14,
        quoteBarWidth: 3,
        listItemSpacing: 6,
        listMarkerColor: .secondaryLabelColor,
        codeBackgroundColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x2A / 255, green: 0x2A / 255, blue: 0x2E / 255, alpha: 1)
                : NSColor(srgbRed: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, alpha: 1)
        },
        codeBadgeBackgroundColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x3E / 255, green: 0x3E / 255, blue: 0x43 / 255, alpha: 1)
                : NSColor(srgbRed: 0xE1 / 255, green: 0xE1 / 255, blue: 0xE3 / 255, alpha: 1)
        },
        codeCornerRadius: 6,
        codeHorizontalPadding: 16,
        codeVerticalPadding: 12,
        codeChromeInset: 8,
        codeBadgeFontSize: 11,
        codeBadgeCornerRadius: 4,
        codeBadgeHorizontalPadding: 6)

    // MARK: - Vertical rhythm

    /// Per-kind space above and below a block.
    ///
    /// Not one constant, because the *visible* gap between two blocks is not the
    /// space between their boxes: soft-edged text leaves optical room inside its
    /// line height, hard-edged fills and borders do not. Body kinds carry 6/6
    /// (→ a 12pt gap between paragraphs); bordered kinds carry 8/8 to win back
    /// the room their edges take away.
    ///
    /// Headings are asymmetric on purpose — a wide space above marks a section
    /// break, a narrow one below keeps the heading glued to the content it owns.
    /// The bottom scales with the level so that the same number does not read as
    /// "tight" under an 18pt h3 and "cramped" under a 26pt h1.
    func padding(for node: MarkdownIR.BlockNode) -> (top: CGFloat, bottom: CGFloat) {
        switch node {
        case .heading(let level, _):
            switch max(1, min(6, level)) {
            case 1: return (24, 6)
            case 2: return (16, 4)
            default: return (10, 2)
            }

        // A blockquote has no container chrome, only a left bar, so it shares
        // the soft-edged tier with paragraphs rather than the bordered one.
        case .paragraph, .list, .blockquote:
            return (6, 6)

        case .codeBlock, .table:
            return (8, 8)

        // A rule is a thin line with no glyphs, so it needs wider breathing
        // room than a text-edged block to avoid attaching to either neighbour.
        case .thematicBreak:
            return (12, 12)
        }
    }
}

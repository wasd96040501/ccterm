import AppKit

/// How a row's *text* is styled: the faces and colours inline spans resolve to.
///
/// Only text. A code card's radius, a quote's bar width, a list's item spacing
/// and every block's vertical rhythm live on the block types that own them —
/// this used to be one struct holding all of it, which meant every type's
/// constants sat in someone else's file. What is left here is the set that
/// genuinely spans block kinds, because emphasis has to look the same inside a
/// paragraph, a heading, a quote and a list item.
///
/// In `Layout/`, below both of its readers: the markdown lowering sets a
/// document's text with it, and `UserMessage` sets a bubble's — so it belongs to
/// neither, and a block reading it never reaches up into `Markdown/`.
///
/// Nothing is public yet: no host has asked to restyle the transcript, and a
/// style struct is a wide surface to commit to before one does.
struct TextStyle {

    var bodyFont: NSFont
    var textColor: NSColor
    var secondaryColor: NSColor
    var linkColor: NSColor

    /// The glyph in front of a link, and the one standing in for an image.
    ///
    /// Proportions rather than images: an `NSImage` is main-thread work and this
    /// struct is read while measuring, which runs anywhere. `InlineSymbol`
    /// rasterises at draw time.
    var linkSymbol: InlineSymbol.Design
    var imageSymbol: InlineSymbol.Design

    /// Inline code's foreground, and the reason it needs no background: the hue
    /// *is* the signal. A tinted monospaced run reads as code against
    /// surrounding prose without a filled box interrupting the line — and a box
    /// drawn from an attributed `.backgroundColor` spans the line's full leading,
    /// so it sits visibly lower than the glyphs it is meant to wrap.
    ///
    /// The teal matches the shade a function name renders in inside a
    /// highlighted code card, so an inline reference and its definition read as
    /// the same kind of thing.
    var inlineCodeColor: NSColor

    /// Monospaced at the surrounding run's size and weight, so inline code
    /// inside a bold run or a heading keeps that run's proportions instead of
    /// dropping to body size mid-line.
    func inlineCodeFont(matching surrounding: NSFont?) -> NSFont {
        let size = surrounding?.pointSize ?? bodyFont.pointSize
        let bold = surrounding?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
        return .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    /// h1 26 / h2 22 / h3–h6 18, semibold. Markdown's six levels collapse to
    /// three visual tiers — chat content rarely goes deeper than h3, and
    /// shrinking the tail levels toward body size makes them read as emphasis
    /// rather than as structure.
    ///
    /// Here rather than on `Heading`: the block is handed its text already set,
    /// and the face is decided by whoever sets it — the markdown lowering. What
    /// the level decides at measure time, the room above, stays on the block.
    func headingFont(level: Int) -> NSFont {
        let size: CGFloat
        switch max(1, level) {
        case 1: size = 26
        case 2: size = 22
        default: size = 18
        }
        return .systemFont(ofSize: size, weight: .semibold)
    }

    /// A table's header cells: the body size, one weight up. The size belongs to
    /// the text around the table, not to the table.
    var tableHeaderFont: NSFont {
        .systemFont(ofSize: bodyFont.pointSize, weight: .semibold)
    }

    /// The face a code card's language chip is set in. The card lays out
    /// whatever chip it is handed; the chip's text is set by whoever typesets it.
    var codeBadgeFont: NSFont {
        .systemFont(ofSize: 11, weight: .regular)
    }

    static let `default` = TextStyle(
        bodyFont: .systemFont(ofSize: 14, weight: .regular),
        textColor: .labelColor,
        secondaryColor: .secondaryLabelColor,
        linkColor: .linkColor,
        linkSymbol: .link,
        imageSymbol: .image,
        inlineCodeColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x67 / 255, green: 0xB7 / 255, blue: 0xA4 / 255, alpha: 1)
                : NSColor(srgbRed: 0x31 / 255, green: 0x6D / 255, blue: 0x74 / 255, alpha: 1)
        })
}

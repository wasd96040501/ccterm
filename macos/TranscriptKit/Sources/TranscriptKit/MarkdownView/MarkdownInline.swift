import AppKit

/// Lowers a block's inline children into one `NSAttributedString`.
///
/// The `switch` is exhaustive because `MarkdownIR.InlineNode` is an enum — a
/// shape added upstream fails to compile here rather than silently rendering as
/// nothing, which is the reason that IR exists as enums in the first place.
///
/// Links are carried as an `.link` attribute rather than as a side-table of hit
/// rectangles. `TextRun` keeps the attributed string it typeset, so "which URL
/// is under this point" is `index(at:)` followed by an attribute lookup — the
/// hit-testing already written for selection, reused. The renderer this
/// replaces kept a parallel `[LinkHit]` per layout and re-projected each one
/// through every enclosing container by hand.
enum MarkdownInline {

    static func attributed(
        _ inlines: [MarkdownIR.InlineNode],
        style: MarkdownStyle,
        font: NSFont? = nil,
        color: NSColor? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base = font ?? style.bodyFont
        let tint = color ?? style.textColor
        for inline in inlines {
            result.append(attributed(inline, style: style, font: base, color: tint))
        }
        return result
    }

    private static func attributed(
        _ inline: MarkdownIR.InlineNode,
        style: MarkdownStyle,
        font: NSFont,
        color: NSColor
    ) -> NSAttributedString {
        switch inline {
        case .text(let string):
            return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])

        case .emphasis(let children):
            return attributed(
                children, style: style, font: font.adding(.italicFontMask), color: color)

        case .strong(let children):
            return attributed(
                children, style: style, font: font.adding(.boldFontMask), color: color)

        case .strikethrough(let children):
            let inner = NSMutableAttributedString(
                attributedString: attributed(children, style: style, font: font, color: color))
            inner.addAttribute(
                .strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: inner.length))
            return inner

        case .code(let string):
            // Tinted, not boxed. An attributed `.backgroundColor` fills the
            // line's full leading, so the box sits visibly below the glyphs it
            // is meant to wrap; the hue carries the same signal without
            // interrupting the line.
            return NSAttributedString(
                string: string,
                attributes: [
                    .font: style.inlineCodeFont(matching: font),
                    .foregroundColor: style.inlineCodeColor,
                ])

        case .link(let destination, let children):
            let inner = NSMutableAttributedString(
                attributedString: attributed(
                    children, style: style, font: font, color: style.linkColor))
            let whole = NSRange(location: 0, length: inner.length)
            inner.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: whole)
            if let url = URL(string: destination) {
                inner.addAttribute(.link, value: url, range: whole)
            }
            return inner

        case .image(_, let alt):
            // Inline images are not drawn yet. The alt text stands in, because a
            // paragraph that silently loses a word reads as a rendering bug the
            // reader cannot diagnose; visible alt text reads as a missing image.
            return NSAttributedString(
                string: alt, attributes: [.font: font, .foregroundColor: style.secondaryColor])

        case .lineBreak:
            // U+2028, not `\n`: a line separator breaks the line without ending
            // the paragraph, so paragraph-level state survives it. `CTTypesetter`
            // honours it as a hard break.
            return NSAttributedString(string: "\u{2028}", attributes: [.font: font])

        case .softBreak:
            // CommonMark folds a source newline into a space. Emitted as a real
            // space rather than dropped so the words on either side stay apart.
            return NSAttributedString(string: " ", attributes: [.font: font])
        }
    }
}

extension NSFont {

    /// The same font with a trait added, falling back to the original when the
    /// family has no such face — `NSFontManager` answers `nil` there, and an
    /// unstyled word is a better outcome than a crash or a substituted family.
    fileprivate func adding(_ trait: NSFontTraitMask) -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: trait)
    }
}

import AppKit

/// Lowers a block's inline children into one `NSAttributedString`.
///
/// The `switch` is exhaustive because `MarkdownIR.InlineNode` is an enum — a
/// shape added upstream fails to compile here rather than silently rendering as
/// nothing, which is the reason that IR exists as enums in the first place.
///
/// Links are carried as an `.link` attribute rather than as a side-table of hit
/// rectangles. `TypesetText` keeps the attributed string it typeset, so "which URL
/// is under this point" is `index(at:)` followed by an attribute lookup — the
/// hit-testing already written for selection, reused. The renderer this
/// replaces kept a parallel `[LinkHit]` per layout and re-projected each one
/// through every enclosing container by hand.
enum MarkdownInlineBuilder {

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
                children, style: style, font: font.adding(.italic), color: color)

        case .strong(let children):
            return attributed(
                children, style: style, font: font.adding(.bold), color: color)

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

        case .link(let destination, let title, let children):
            // Glyph, not underline. A rule drawn under a run of prose competes
            // with the descenders it crosses and says nothing about *what* was
            // linked; a mark in front says it once, before the text, at the size
            // of the text.
            let inner = NSMutableAttributedString(
                attributedString: InlineSymbol(
                    style.linkSymbol, font: font, color: style.linkColor
                ).attributedString(font: font))
            inner.append(attributed(children, style: style, font: font, color: style.linkColor))
            return decorated(inner, destination: destination, title: title)

        case .image(let source, let title, let alt):
            // Inline images are not fetched or drawn. A glyph and the image's own
            // words stand in, styled like a link, because that is what it is: a
            // reference to something that lives elsewhere.
            //
            // `alt` before `title` — alt is the text an author writes *for* the
            // case where the image isn't shown, which is exactly this one — and
            // neither is required, in which case the glyph carries it alone.
            let caption = [alt, title ?? ""].first { !$0.isEmpty } ?? ""
            let inner = NSMutableAttributedString(
                attributedString: InlineSymbol(
                    style.imageSymbol, font: font, color: style.linkColor
                ).attributedString(font: font))
            if !caption.isEmpty {
                inner.append(
                    NSAttributedString(
                        string: caption,
                        attributes: [.font: font, .foregroundColor: style.linkColor]))
            }
            return decorated(inner, destination: source, title: title)

        case .footnoteReference(_, let number):
            // Core Text's own superscript attribute, not `NSAttributedString`'s:
            // the two spell the key differently and only `kCTSuperscript…` is
            // read by a `CTTypesetter`, which is what does the work here.
            //
            // A mark, not a control. The number points at a note further down
            // this same block rather than out of the document, so there is no
            // destination a host could act on — and a cursor or a click that
            // promised one would be promising something nothing here does.
            return NSAttributedString(
                string: "\(number)",
                attributes: [
                    .font: font,
                    .foregroundColor: style.linkColor,
                    NSAttributedString.Key(kCTSuperscriptAttributeName as String): 1,
                ])

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

extension MarkdownInlineBuilder {

    /// Hangs the destination off the whole run.
    ///
    /// `.link` rather than a side-table of hit rectangles. `TypesetText` keeps the
    /// attributed string it typeset, so "which URL is under this point" is
    /// `index(at:)` followed by an attribute lookup — the hit-testing already
    /// written for selection, reused. A destination `URL` cannot parse is left
    /// unmarked rather than mapped to something wrong: it still reads as a link,
    /// it simply does not activate.
    ///
    /// The markdown *title* — `[text](url "title")` — is parsed but not carried:
    /// hovering shows the destination, which is what a reader is deciding on, and
    /// what a browser's status bar shows.
    fileprivate static func decorated(
        _ text: NSMutableAttributedString, destination: String, title: String?
    ) -> NSAttributedString {
        guard let url = URL(string: destination) else { return text }
        text.addAttribute(.link, value: url, range: NSRange(location: 0, length: text.length))
        return text
    }
}

extension NSFont {

    /// The same font with a trait added, falling back to the original when the
    /// family has no such face — an unstyled word is a better outcome than a
    /// crash or a substituted family.
    ///
    /// Through `NSFontDescriptor` rather than `NSFontManager`, which is
    /// main-thread-only: this runs during layout, and layout has to stay
    /// callable off the main actor.
    fileprivate func adding(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

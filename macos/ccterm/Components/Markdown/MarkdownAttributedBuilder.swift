import AppKit
import SwiftMath

/// Builds `NSAttributedString` output for `.markdown` segments and table cells.
///
/// Pure function over `(blocks, theme)` — no side effects, no UI state.
/// Main-actor only because it touches `NSFont` / `NSColor` / `NSFontManager`.
@MainActor
struct MarkdownAttributedBuilder {
    let theme: MarkdownTheme

    // MARK: - Public

    /// Build a contiguous attributed string for a run of top-level blocks.
    func build(blocks: [MarkdownBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (idx, block) in blocks.enumerated() {
            let isLast = idx == blocks.count - 1
            renderBlock(
                block,
                indent: 0,
                trailingSpacing: isLast ? 0 : theme.l2,
                into: out)
            if !isLast {
                out.append(NSAttributedString(string: "\n"))
            }
        }
        return out
    }

    /// Build the attributed string for a standalone heading segment.
    func buildHeading(level: Int, inlines: [MarkdownInline]) -> NSAttributedString {
        let font = theme.headingFont(level: level)
        let content = renderInlines(inlines, baseFont: font, color: theme.primaryColor)
        let style = paragraphStyle(indent: 0, trailing: 0)
        apply(style, to: content)
        return content
    }

    /// Build the attributed string for a top-level blockquote segment. The
    /// surrounding SwiftUI view draws the vertical bar and provides the indent;
    /// the builder only colors the inner blocks with the secondary color.
    ///
    /// Internal block-to-block spacing uses ``MarkdownTheme/l3Item`` (tighter
    /// than top-level prose) so the quote reads as one cohesive unit rather
    /// than a sequence of independent paragraphs.
    func buildBlockquote(blocks: [MarkdownBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (idx, block) in blocks.enumerated() {
            let isLast = idx == blocks.count - 1
            renderBlock(
                block,
                indent: 0,
                trailingSpacing: isLast ? 0 : theme.l3Item,
                into: out)
            if !isLast {
                out.append(NSAttributedString(string: "\n"))
            }
        }
        let range = NSRange(location: 0, length: out.length)
        out.addAttribute(.foregroundColor, value: theme.blockquoteTextColor, range: range)
        return out
    }

    /// Render a flat list of inlines — used for table cells.
    func buildInline(_ inlines: [MarkdownInline], bold: Bool = false) -> NSAttributedString {
        let base: NSFont = bold
            ? NSFontManager.shared.convert(theme.bodyFont, toHaveTrait: .boldFontMask)
            : theme.bodyFont
        return renderInlines(inlines, baseFont: base, color: theme.primaryColor)
    }

    // MARK: - Block rendering

    private func renderBlock(
        _ block: MarkdownBlock,
        indent: CGFloat,
        trailingSpacing: CGFloat,
        into out: NSMutableAttributedString
    ) {
        switch block {
        case .paragraph(let inlines):
            let content = renderInlines(inlines, baseFont: theme.bodyFont, color: theme.primaryColor)
            let style = paragraphStyle(indent: indent, trailing: trailingSpacing)
            apply(style, to: content)
            out.append(content)

        case .heading(let level, let inlines):
            let font = theme.headingFont(level: level)
            let content = renderInlines(inlines, baseFont: font, color: theme.primaryColor)
            let style = paragraphStyle(indent: indent, trailing: trailingSpacing)
            apply(style, to: content)
            out.append(content)

        case .blockquote(let innerBlocks):
            // Reached only when blockquote is nested inside another block (e.g. list
            // item). Top-level blockquotes are split out into their own segment by
            // the segmenter and rendered with a SwiftUI bar instead. Inner block
            // spacing matches ``buildBlockquote`` — l3 for cohesive quote feel.
            let inner = NSMutableAttributedString()
            for (idx, b) in innerBlocks.enumerated() {
                let isLast = idx == innerBlocks.count - 1
                renderBlock(
                    b,
                    indent: indent + theme.blockquoteIndent,
                    trailingSpacing: isLast ? trailingSpacing : theme.l3Item,
                    into: inner)
                if !isLast {
                    inner.append(NSAttributedString(string: "\n"))
                }
            }
            let range = NSRange(location: 0, length: inner.length)
            inner.addAttribute(.foregroundColor, value: theme.blockquoteTextColor, range: range)
            out.append(inner)

        case .list(let list):
            renderList(list, indent: indent, trailingSpacing: trailingSpacing, into: out)
        }
    }

    private func renderList(
        _ list: MarkdownList,
        indent: CGFloat,
        trailingSpacing: CGFloat,
        into out: NSMutableAttributedString
    ) {
        // Marker font: monospaced digits for ordered lists so 9, 10, 99, 100
        // share the same digit width and right-align cleanly.
        let markerFont: NSFont = list.ordered
            ? NSFont.monospacedDigitSystemFont(ofSize: theme.bodyFontSize, weight: .regular)
            : theme.bodyFont

        // Pre-pass: compute the widest marker across this list so every item
        // shares one right-aligned tab stop.
        var maxMarkerWidth: CGFloat = 0
        for (idx, item) in list.items.enumerated() {
            let m = makeMarker(item: item, idx: idx, list: list, markerFont: markerFont)
            maxMarkerWidth = max(maxMarkerWidth, m.size().width)
        }
        let markerRightX = indent + maxMarkerWidth
        // Half-em gap between marker and content.
        let contentX = markerRightX + theme.bodyFontSize * 0.5
        let tabStops = [
            NSTextTab(textAlignment: .right, location: markerRightX),
            NSTextTab(textAlignment: .left, location: contentX),
        ]

        func listLineStyle(trailing: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = theme.l3Line
            style.paragraphSpacing = trailing
            style.firstLineHeadIndent = indent
            style.headIndent = contentX
            style.tabStops = tabStops
            return style
        }

        for (idx, item) in list.items.enumerated() {
            let isLast = idx == list.items.count - 1
            let itemTrailing = isLast ? trailingSpacing : theme.l3Item
            let marker = makeMarker(item: item, idx: idx, list: list, markerFont: markerFont)

            if item.content.isEmpty {
                let line = NSMutableAttributedString(string: "\t")
                line.append(marker)
                line.append(NSAttributedString(string: "\t"))
                apply(listLineStyle(trailing: itemTrailing), to: line)
                out.append(line)
            } else {
                for (bi, block) in item.content.enumerated() {
                    let isFirst = bi == 0
                    let isLastInItem = bi == item.content.count - 1
                    let blockTrailing = isLastInItem ? itemTrailing : theme.l2

                    if isFirst, case .paragraph(let inlines) = block {
                        let line = NSMutableAttributedString(string: "\t")
                        line.append(marker)
                        line.append(NSAttributedString(string: "\t"))
                        line.append(renderInlines(
                            inlines,
                            baseFont: theme.bodyFont,
                            color: theme.primaryColor))
                        apply(listLineStyle(trailing: blockTrailing), to: line)
                        out.append(line)
                    } else {
                        renderBlock(
                            block,
                            indent: contentX,
                            trailingSpacing: blockTrailing,
                            into: out)
                    }

                    if !isLastInItem {
                        out.append(NSAttributedString(string: "\n"))
                    }
                }
            }

            if !isLast {
                out.append(NSAttributedString(string: "\n"))
            }
        }
    }

    private func makeMarker(
        item: MarkdownListItem,
        idx: Int,
        list: MarkdownList,
        markerFont: NSFont
    ) -> NSAttributedString {
        if let checkbox = item.checkbox {
            return checkboxAttachment(checked: checkbox == .checked)
        }
        if list.ordered {
            let n = (list.startIndex ?? 1) + idx
            return NSAttributedString(string: "\(n).", attributes: [
                .font: markerFont,
                .foregroundColor: theme.secondaryColor,
            ])
        }
        return NSAttributedString(string: "•", attributes: [
            .font: markerFont,
            .foregroundColor: theme.secondaryColor,
        ])
    }

    /// Render an inline `$..$` math run via SwiftMath as an `NSTextAttachment`,
    /// so the typeset image flows with the surrounding prose. The image's
    /// baseline aligns with the text baseline using SwiftMath's reported
    /// descent. On parse failure we fall back to monospaced text in the
    /// secondary colour so users still see the source.
    private func inlineMathAttachment(latex: String, baseFont: NSFont, color: NSColor) -> NSAttributedString {
        var img = MathImage(
            latex: latex,
            fontSize: baseFont.pointSize,
            textColor: color,
            labelMode: .text,
            textAlignment: .left)
        let (error, image, layout) = img.asImage()
        guard error == nil, let image, let layout else {
            let font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
            return NSAttributedString(string: latex, attributes: [
                .font: font,
                .foregroundColor: theme.secondaryColor,
            ])
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0,
            y: -layout.descent,
            width: image.size.width,
            height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    /// SF Symbols `square` / `checkmark.square` rendered as an `NSTextAttachment`
    /// so checked and unchecked boxes are guaranteed to be the exact same size.
    /// Sized at 1.2× body font and `.medium` weight — the default `.regular`
    /// stroke reads thin at body sizes.
    ///
    /// Vertical alignment uses the font's **cap height** centre rather than
    /// x-height. SF Symbol bounding boxes carry asymmetric internal padding,
    /// and the x-height reference visibly sits the chip below the text mean
    /// line. capHeight/2 puts the symbol's geometric centre on the same line
    /// as uppercase letters, which reads as properly centred.
    private func checkboxAttachment(checked: Bool) -> NSAttributedString {
        let symbolSize = theme.bodyFontSize * 1.2
        let name = checked ? "checkmark.square" : "square"
        let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else {
            return NSAttributedString(string: checked ? "☑" : "☐", attributes: [
                .font: theme.bodyFont,
                .foregroundColor: theme.secondaryColor,
            ])
        }
        image.isTemplate = true
        let attachment = NSTextAttachment()
        attachment.image = image
        let capHeight = theme.bodyFont.capHeight
        attachment.bounds = CGRect(
            x: 0,
            y: (capHeight - symbolSize) / 2,
            width: symbolSize,
            height: symbolSize)
        let attr = NSMutableAttributedString(attachment: attachment)
        attr.addAttribute(
            .foregroundColor,
            value: theme.secondaryColor,
            range: NSRange(location: 0, length: attr.length))
        return attr
    }

    // MARK: - Inline rendering

    private func renderInlines(
        _ inlines: [MarkdownInline],
        baseFont: NSFont,
        color: NSColor
    ) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for inline in inlines {
            append(
                inline: inline,
                baseFont: baseFont,
                color: color,
                bold: false,
                italic: false,
                strike: false,
                into: out)
        }
        return out
    }

    private func append(
        inline: MarkdownInline,
        baseFont: NSFont,
        color: NSColor,
        bold: Bool,
        italic: Bool,
        strike: Bool,
        into out: NSMutableAttributedString
    ) {
        switch inline {
        case .text(let s):
            out.append(styled(s, baseFont: baseFont, color: color, bold: bold, italic: italic, strike: strike))

        case .emphasis(let children):
            for c in children {
                append(inline: c, baseFont: baseFont, color: color, bold: bold, italic: true, strike: strike, into: out)
            }

        case .strong(let children):
            for c in children {
                append(inline: c, baseFont: baseFont, color: color, bold: true, italic: italic, strike: strike, into: out)
            }

        case .strikethrough(let children):
            for c in children {
                append(inline: c, baseFont: baseFont, color: color, bold: bold, italic: italic, strike: true, into: out)
            }

        case .code(let s):
            let font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.92, weight: .regular)
            // Custom marker — drawn as a padded rounded chip by
            // ``MarkdownLayoutManager``. Built-in `.backgroundColor` only
            // supports tight rectangles.
            let chipAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .inlineCodeBackground: theme.inlineCodeBackground,
            ]
            let chip = NSAttributedString(string: s, attributes: chipAttrs)

            // LEFT side: push the chip away from the previous character by
            // bumping that char's kern in the already-emitted output. The kern
            // sits on a glyph OUTSIDE the chip's marker range, so it shifts
            // the chip's start position without widening the chip itself.
            if out.length > 0 {
                let prevRange = NSRange(location: out.length - 1, length: 1)
                out.addAttribute(.kern, value: theme.inlineCodeSideKern, range: prevRange)
            }
            out.append(chip)

            // RIGHT side: append a zero-width word joiner (U+2060) carrying
            // the kern. CRITICAL — putting the kern on the chip's *last*
            // character would widen `enumerateEnclosingRects`'s result and
            // pull the following glyph INSIDE the chip's rounded right edge.
            // The U+2060 is invisible, has no advance, and is unmarked, so it
            // sits outside the chip range; only its post-kern carries through
            // to push the next visible glyph past the chip's drawn edge.
            let trailing = NSAttributedString(string: "\u{2060}", attributes: [
                .font: font,
                .kern: theme.inlineCodeSideKern,
            ])
            out.append(trailing)

        case .link(let destination, let children):
            let before = out.length
            for c in children {
                append(
                    inline: c,
                    baseFont: baseFont,
                    color: theme.linkColor,
                    bold: bold,
                    italic: italic,
                    strike: strike,
                    into: out)
            }
            let after = out.length
            guard after > before, !destination.isEmpty else { break }
            out.addAttributes([
                .link: destination,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: NSRange(location: before, length: after - before))

        case .image(let source, let alt):
            // v1: render images as a clickable link to the source URL. The
            // visible label uses the alt text when present, otherwise the URL
            // itself, so the user can still see what the link points at.
            let label = alt.isEmpty ? source : alt
            guard !label.isEmpty else { break }
            let before = out.length
            out.append(styled(label, baseFont: baseFont, color: theme.linkColor,
                              bold: bold, italic: italic, strike: strike))
            let after = out.length
            guard !source.isEmpty, after > before else { break }
            out.addAttributes([
                .link: source,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: NSRange(location: before, length: after - before))

        case .inlineMath(let s):
            out.append(inlineMathAttachment(latex: s, baseFont: baseFont, color: color))

        case .lineBreak:
            out.append(NSAttributedString(string: "\n"))

        case .softBreak:
            out.append(NSAttributedString(string: " "))
        }
    }

    private func styled(
        _ s: String,
        baseFont: NSFont,
        color: NSColor,
        bold: Bool,
        italic: Bool,
        strike: Bool
    ) -> NSAttributedString {
        var font = baseFont
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        if strike {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: s, attributes: attrs)
    }

    // MARK: - Paragraph style

    private func paragraphStyle(
        indent: CGFloat,
        trailing: CGFloat,
        firstLineIndent: CGFloat? = nil
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.l3Line
        style.paragraphSpacing = trailing
        style.firstLineHeadIndent = firstLineIndent ?? indent
        style.headIndent = indent
        return style
    }

    private func apply(_ style: NSParagraphStyle, to attr: NSMutableAttributedString) {
        attr.addAttribute(
            .paragraphStyle,
            value: style,
            range: NSRange(location: 0, length: attr.length))
    }
}

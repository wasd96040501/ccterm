import AppKit

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
                trailingSpacing: isLast ? 0 : theme.paragraphSpacing,
                into: out)
            if !isLast {
                out.append(NSAttributedString(string: "\n"))
            }
        }
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
            let style = paragraphStyle(
                indent: indent,
                trailing: max(trailingSpacing, theme.headingSpacingAfter),
                before: out.length == 0 ? 0 : theme.headingSpacingBefore)
            apply(style, to: content)
            out.append(content)

        case .blockquote(let innerBlocks):
            let inner = NSMutableAttributedString()
            for (idx, b) in innerBlocks.enumerated() {
                let isLast = idx == innerBlocks.count - 1
                renderBlock(
                    b,
                    indent: indent + theme.blockquoteIndent,
                    trailingSpacing: isLast ? trailingSpacing : theme.paragraphSpacing,
                    into: inner)
                if !isLast {
                    inner.append(NSAttributedString(string: "\n"))
                }
            }
            let range = NSRange(location: 0, length: inner.length)
            inner.addAttribute(.foregroundColor, value: theme.blockquoteTextColor, range: range)
            inner.addAttribute(.obliqueness, value: 0.1, range: range)
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
        for (idx, item) in list.items.enumerated() {
            let isLast = idx == list.items.count - 1
            let itemTrailing = isLast ? trailingSpacing : theme.listItemSpacing

            let markerString: String
            if let checkbox = item.checkbox {
                markerString = checkbox == .checked ? "☑  " : "☐  "
            } else if list.ordered {
                let n = (list.startIndex ?? 1) + idx
                markerString = "\(n).  "
            } else {
                markerString = "•  "
            }
            let marker = NSAttributedString(string: markerString, attributes: [
                .font: theme.bodyFont,
                .foregroundColor: theme.secondaryColor,
            ])
            let markerWidth = marker.size().width
            let contentIndent = indent + markerWidth

            if item.content.isEmpty {
                let line = NSMutableAttributedString(attributedString: marker)
                let style = paragraphStyle(
                    indent: contentIndent,
                    trailing: itemTrailing,
                    firstLineIndent: indent)
                apply(style, to: line)
                out.append(line)
            } else {
                for (bi, block) in item.content.enumerated() {
                    let isFirst = bi == 0
                    let isLastInItem = bi == item.content.count - 1
                    let blockTrailing = isLastInItem ? itemTrailing : theme.paragraphSpacing

                    if isFirst, case .paragraph(let inlines) = block {
                        let line = NSMutableAttributedString()
                        line.append(marker)
                        line.append(renderInlines(
                            inlines,
                            baseFont: theme.bodyFont,
                            color: theme.primaryColor))
                        let style = paragraphStyle(
                            indent: contentIndent,
                            trailing: blockTrailing,
                            firstLineIndent: indent)
                        apply(style, to: line)
                        out.append(line)
                    } else {
                        renderBlock(
                            block,
                            indent: contentIndent,
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
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .backgroundColor: theme.inlineCodeBackground,
            ]
            out.append(NSAttributedString(string: s, attributes: attrs))

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

        case .image(_, let alt):
            // v1: render as alt text. No attachment, no network fetch.
            out.append(styled(alt, baseFont: baseFont, color: theme.secondaryColor,
                              bold: bold, italic: italic, strike: strike))

        case .inlineMath(let s):
            let font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
            out.append(NSAttributedString(string: s, attributes: [
                .font: font,
                .foregroundColor: theme.secondaryColor,
            ]))

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
        before: CGFloat = 0,
        firstLineIndent: CGFloat? = nil
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.lineSpacing
        style.paragraphSpacing = trailing
        style.paragraphSpacingBefore = before
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

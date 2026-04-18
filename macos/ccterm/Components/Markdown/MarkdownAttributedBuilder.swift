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
    func buildBlockquote(blocks: [MarkdownBlock]) -> NSAttributedString {
        let inner = NSMutableAttributedString(attributedString: build(blocks: blocks))
        let range = NSRange(location: 0, length: inner.length)
        inner.addAttribute(.foregroundColor, value: theme.blockquoteTextColor, range: range)
        return inner
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
            // the segmenter and rendered with a SwiftUI bar instead.
            let inner = NSMutableAttributedString()
            for (idx, b) in innerBlocks.enumerated() {
                let isLast = idx == innerBlocks.count - 1
                renderBlock(
                    b,
                    indent: indent + theme.blockquoteIndent,
                    trailingSpacing: isLast ? trailingSpacing : theme.l2,
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

    /// SF Symbols `square` / `checkmark.square` rendered as an `NSTextAttachment`
    /// so checked and unchecked boxes are guaranteed to be the exact same size.
    /// Aligned so the symbol's vertical center matches the body font's x-height.
    private func checkboxAttachment(checked: Bool) -> NSAttributedString {
        let name = checked ? "checkmark.square" : "square"
        let config = NSImage.SymbolConfiguration(pointSize: theme.bodyFontSize, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else {
            // Fallback to the legacy glyphs if the symbol isn't available.
            return NSAttributedString(string: checked ? "☑" : "☐", attributes: [
                .font: theme.bodyFont,
                .foregroundColor: theme.secondaryColor,
            ])
        }
        image.isTemplate = true
        let attachment = NSTextAttachment()
        attachment.image = image
        let h = theme.bodyFontSize
        let xHeight = theme.bodyFont.xHeight
        attachment.bounds = CGRect(x: 0, y: (xHeight - h) / 2, width: h, height: h)
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

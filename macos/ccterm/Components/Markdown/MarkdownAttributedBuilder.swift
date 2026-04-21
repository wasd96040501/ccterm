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
        // Marker font: fully monospaced (SF Mono) for ordered lists. Previously
        // used `monospacedDigitSystemFont`, which only gives tabular digit
        // advances — the digit→`.` pair kerning still varies by digit in SF Pro,
        // so "1." / "2." / "3." widths were subtly unequal and visually drifted
        // under the right-aligned tab stop. SF Mono has no context-dependent
        // kerning, so every marker lines up exactly at both the dot and the
        // digits above it.
        let markerFont: NSFont = list.ordered
            ? NSFont.monospacedSystemFont(ofSize: theme.bodyFontSize, weight: .regular)
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
                    // Use l3Item (not l2) between blocks WITHIN one list item:
                    // a list item is a single semantic unit, so its internal
                    // blocks (paragraph + nested list, or multi-paragraph
                    // content) should sit tighter than top-level paragraphs.
                    // Mirrors the same convention used for blockquote inner
                    // blocks in `buildBlockquote`.
                    let blockTrailing = isLastInItem ? itemTrailing : theme.l3Item

                    if isFirst, case .paragraph(let inlines) = block {
                        let line = NSMutableAttributedString(string: "\t")
                        line.append(marker)
                        line.append(NSAttributedString(string: "\t"))
                        // Trim leading whitespace from the first text run —
                        // nested-list content sometimes carries over indentation
                        // from the source (` - inner` yields `" inner"`), which
                        // reads as an unwanted tab/space right after the marker.
                        line.append(renderInlines(
                            Self.trimLeadingWhitespace(inlines),
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

    /// Trim leading ASCII whitespace from the first text inline of a sequence.
    /// Used when rendering a list item's first paragraph — see the caller for
    /// the "nested list bleeds an indent" rationale. Newlines are preserved;
    /// we only strip spaces/tabs that would render as leading gutter whitespace.
    static func trimLeadingWhitespace(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        guard case let .text(s)? = inlines.first else { return inlines }
        let trimmed = s.drop(while: { $0 == " " || $0 == "\t" })
        if trimmed.count == s.count { return inlines }
        var result = Array(inlines.dropFirst())
        if !trimmed.isEmpty {
            result.insert(.text(String(trimmed)), at: 0)
        }
        return result
    }

    /// Task list checkbox rendered as Unicode glyphs (☐ / ☑).
    ///
    /// Historically we used an `NSTextAttachment` wrapping an SF Symbol image,
    /// but CoreText (which the NativeTranscript renderer uses) does NOT run
    /// the TextKit attachment substitution pass — attachment characters are
    /// typeset as zero-width (or the object-replacement-glyph) with no image
    /// drawn. Unicode BALLOT BOX / BALLOT BOX WITH CHECK ship in SF Pro and
    /// render cleanly through the standard glyph pipeline.
    ///
    /// Size bumped slightly (1.05× body) so the box reads at similar visual
    /// weight to surrounding text. Checked box uses `primaryColor` so the
    /// tick stands out; unchecked uses `secondaryColor` for a softer empty
    /// box.
    private func checkboxAttachment(checked: Bool) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: theme.bodyFontSize * 1.05, weight: .regular)
        return NSAttributedString(string: checked ? "☑" : "☐", attributes: [
            .font: font,
            .foregroundColor: checked ? theme.primaryColor : theme.secondaryColor,
        ])
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
            // Custom marker — drawn as a padded rounded chip by the CoreText
            // renderer. Built-in `.backgroundColor` only supports tight
            // character-bounds rectangles.
            let chipAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .inlineCodeBackground: theme.inlineCodeBackground,
            ]
            let chip = NSAttributedString(string: s, attributes: chipAttrs)

            // External gap: BOTH sides insert an invisible U+2060 word joiner
            // carrying the same `.kern`. The joiner is 0-advance and carries
            // no ink, so it lives OUTSIDE the chip's CTRun — only its kern
            // shifts the next glyph past the chip's drawn edge.
            //
            // Earlier we kerned the character immediately before the chip,
            // but `.kern` stacks on top of that character's intrinsic advance.
            // When the preceding char was a space (" `code`") the space's own
            // 3-4pt width plus our kern showed up as a double-wide gap on the
            // left side, while the right side still read as a single gap.
            // Using a joiner on both sides makes the mechanism — and the
            // resulting gap — perfectly symmetric regardless of the neighbour
            // glyph.
            let joinerAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .kern: theme.inlineCodeSideKern,
            ]
            let joiner = NSAttributedString(string: "\u{2060}", attributes: joinerAttrs)
            if out.length > 0 {
                out.append(joiner)
            }
            out.append(chip)
            out.append(joiner)

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

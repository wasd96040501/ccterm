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

        case .list:
            // List 不走 attributed-string 路径——它被分派到 ``MarkdownListView``
            // （SwiftUI 路径）和 ``TranscriptListLayout``（CoreText 路径），
            // 那里 marker 是独立的、不可选的视觉元素。这里静默跳过：builder
            // 只会在 fallback（list item 内部的 heading / blockquote）时收到
            // 非 list 的 block，不会有人显式让它渲染 list。
            break
        }
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

            // External gap on each side via `InlineSpacer` (CTRunDelegate over
            // U+2060). Spacer width has to compensate for the chip's own
            // horizontal padding — chipRect extends `chipPadding` past the
            // last/first glyph, so a spacer of N points only yields
            // `N - chipPadding` of visible gap. To get exactly `outerGap`
            // visible breathing room on each side, the spacer must be
            // `outerGap + chipPadding`.
            //
            // Spacers are inserted unconditionally on both sides — at the very
            // start of a paragraph there's no preceding char, but a missing
            // leading spacer would put chipRect at x = -chipPadding, clipped
            // by the layout origin. Always emitting the spacer keeps the chip
            // honest at line/paragraph boundaries too.
            let spacerWidth = theme.inlineCodeOuterGap + theme.inlineCodeHPadding
            out.append(InlineSpacer.attributedString(width: spacerWidth))
            out.append(chip)
            out.append(InlineSpacer.attributedString(width: spacerWidth))

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

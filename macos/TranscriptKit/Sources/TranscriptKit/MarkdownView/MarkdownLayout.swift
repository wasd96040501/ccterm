import AppKit

/// Builds a block tree from a parsed document, at a width.
///
/// The one place that maps `MarkdownIR` onto block types, and therefore the one
/// place that says what an unfinished shape currently degrades to. The `switch`
/// is exhaustive: a case added to `MarkdownIR.BlockNode` fails to compile here
/// rather than disappearing from the screen.
enum MarkdownLayout {

    static func make(
        _ source: String, width: CGFloat, style: MarkdownStyle = .default
    ) -> BlockStack {
        make(MarkdownConvert.document(source), width: width, style: style)
    }

    static func make(
        _ document: MarkdownIR.Document, width: CGFloat, style: MarkdownStyle
    ) -> BlockStack {
        stack(document.blocks, width: width, style: style)
    }

    /// Builds the nodes and spaces them by their own kinds' padding.
    ///
    /// The gap between two blocks is the lower one's bottom plus the upper one's
    /// top — the same sum `NativeTranscript2` arrives at by giving each block
    /// its own row padding, computed here instead so that the total is visible
    /// at the one place it is decided. The document's outer edges take the first
    /// block's top and the last block's bottom.
    private static func stack(
        _ nodes: [MarkdownIR.BlockNode],
        width: CGFloat,
        style: MarkdownStyle,
        inset: NSEdgeInsets = NSEdgeInsets(),
        padEdges: Bool = true
    ) -> BlockStack {
        // Zipped so a node that builds to nothing takes its padding with it,
        // rather than leaving a gap where no block was drawn.
        let built = nodes.compactMap { node -> (MarkdownIR.BlockNode, Block)? in
            block(node, width: width - inset.left - inset.right, style: style)
                .map { (node, $0) }
        }
        guard let first = built.first, let last = built.last else { return .empty }

        let gaps = zip(built, built.dropFirst()).map { above, below in
            style.padding(for: above.0).bottom + style.padding(for: below.0).top
        }

        var edges = inset
        if padEdges {
            edges.top += style.padding(for: first.0).top
            edges.bottom += style.padding(for: last.0).bottom
        }

        return BlockStack.make(built.map(\.1), width: width, gaps: gaps, inset: edges)
    }

    private static func block(
        _ node: MarkdownIR.BlockNode, width: CGFloat, style: MarkdownStyle
    ) -> Block? {
        switch node {
        case .paragraph(let inlines):
            return Paragraph.make(
                MarkdownInline.attributed(inlines, style: style), width: width)

        case .heading(let level, let inlines):
            return Paragraph.make(
                MarkdownInline.attributed(
                    inlines, style: style, font: style.headingFont(level: level)),
                width: width)

        case .blockquote(let children):
            guard width - style.quoteIndent > 0 else { return nil }
            // No outer padding: the bar is sized to the content, so padding
            // inside the quote would show as bar overhanging the first and last
            // lines. The gap to whatever surrounds the quote is the quote's own
            // `padding(for:)`, applied by the stack above it.
            return Blockquote.make(
                content: stack(
                    children, width: width, style: style,
                    inset: NSEdgeInsets(top: 0, left: style.quoteIndent, bottom: 0, right: 0),
                    padEdges: false),
                style: style)

        case .thematicBreak:
            return ThematicBreak.make(width: width, color: style.secondaryColor)

        case .codeBlock(let code):
            return CodeBlock.make(
                code: code.code, language: code.language, width: width, style: style)

        // MARK: Not yet drawn as themselves
        //
        // Both below have a block type coming — `List` with a negotiated marker
        // column, `Table` with its cell grid. Until then they are typeset as
        // text rather than dropped: content that vanishes reads as a bug the
        // reader cannot diagnose, whereas unstyled content reads as unfinished.

        case .list(let list):
            return BlockStack.make(
                list.items.enumerated().compactMap { index, item in
                    listItem(
                        item, ordinal: (list.startIndex ?? 1) + index,
                        ordered: list.ordered, width: width, style: style)
                },
                width: width,
                spacing: style.listItemSpacing)

        case .table(let table):
            let rows = ([table.header] + table.rows).map { row in
                row.map { MarkdownInline.attributed($0, style: style).string }
                    .joined(separator: "\t")
            }
            return Paragraph.make(
                NSAttributedString(
                    string: rows.joined(separator: "\n"),
                    attributes: [.font: style.codeFont, .foregroundColor: style.textColor]),
                width: width)
        }
    }

    /// A list item, indented, with its marker folded into the first line's text.
    ///
    /// A stopgap for the marker column `List` will negotiate — and a deliberate
    /// one, because it gets the *selection* wrong in a way worth being able to
    /// see: a marker rendered as text is selectable and copies, whereas the real
    /// `List` will draw it and leave it out of the index space.
    private static func listItem(
        _ item: MarkdownIR.List.Item, ordinal: Int, ordered: Bool,
        width: CGFloat, style: MarkdownStyle
    ) -> Block? {
        let marker: String
        switch item.checkbox {
        case .checked: marker = "☑ "
        case .unchecked: marker = "☐ "
        case nil: marker = ordered ? "\(ordinal). " : "• "
        }

        let indent: CGFloat = 20
        guard width - indent > 0 else { return nil }

        // Folded in at the IR level rather than onto the built paragraph, so
        // there is one path that turns nodes into blocks. The marker therefore
        // takes body colour instead of the muted tone a marker wants — another
        // thing the real `List` fixes by drawing it.
        var content = item.content
        if case .paragraph(let inlines) = content.first {
            content[0] = .paragraph([.text(marker)] + inlines)
        }

        return stack(
            content, width: width, style: style,
            inset: NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0),
            padEdges: false)
    }
}

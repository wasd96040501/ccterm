import AppKit

/// Turns a parsed document into a `Block`. The one place markdown and the block
/// engine meet.
///
/// **No width appears in this file.** An adapter composes recipes; a width is
/// applied later, once, by whoever is filling a row. That is what keeps the
/// arithmetic for a quote's indent or a list's marker column inside the type that
/// owns it, instead of being spread across every call site that builds one.
///
/// It is also the only markdown-aware file below the parser. `Blockquote`, `ListBuilder`,
/// `BlockStack` and the rest have never heard of `MarkdownIR`, so anything else that
/// wants to build a row composes them directly without going through here.
///
/// The `switch` is exhaustive: a case added to `MarkdownIR.BlockNode` fails to
/// compile here rather than disappearing from the screen. It is pure dispatch —
/// one line per case, no layout logic — which is what keeps a central switch from
/// being the place block behaviour accumulates.
enum MarkdownBlockBuilder {

    static func make(_ source: String, style: MarkdownStyle = .default) -> Block {
        make(MarkdownParser.document(source), style: style)
    }

    static func make(_ document: MarkdownIR.Document, style: MarkdownStyle) -> Block {
        let body = stack(document.blocks, style: style, spacing: blockSpacing)
        guard !document.footnotes.isEmpty else { return body }
        return BlockStack(
            [body, ThematicBreak(), notes(document.footnotes, style: style)],
            spacing: blockSpacing)
    }

    /// The notes, under a rule at the foot of the document.
    ///
    /// An ordered list, because that is what it is: a numbered marker column
    /// beside each note's own blocks. `ListBuilder` already settles the column
    /// against the widest marker, so a document with ten notes lines `10.` up
    /// with `9.` without this knowing that is a question.
    private static func notes(
        _ footnotes: [MarkdownIR.Document.Footnote], style: MarkdownStyle
    ) -> Block {
        ListBuilder.make(
            items: footnotes.map { note in
                ListBuilder.Item(
                    marker: ListBuilder.marker(
                        .ordinal(note.number), font: style.bodyFont,
                        color: style.secondaryColor),
                    content: stack(note.blocks, style: style, spacing: tightListSpacing))
            },
            spacing: tightListSpacing,
            gap: style.bodyFont.pointSize * 0.5)
    }

    /// The gap between two blocks of a document — and the number the block types
    /// are calibrated against, which is why `Paragraph` asks for nothing of its
    /// own and only headings, code cards and rules add to it.
    ///
    /// Twelve because that is what `NativeTranscript2` produces: every block is
    /// its own table row there, each padded six above and six below, so two
    /// paragraphs land twelve apart. Copying the *result* rather than that
    /// design's per-block halves is the point — a container that owns its
    /// spacing does not need each child to carry half of every gap.
    private static let blockSpacing: CGFloat = 12

    /// The gap inside a **tight** list, at every depth: between items, and
    /// between the blocks within one item. `NativeTranscript2` states these as
    /// two constants (`listItemSpacing`, `listIntraItemSpacing`) and gives both
    /// the same value, so a list has one rhythm no matter how it is shaped.
    ///
    /// A loose list uses `blockSpacing` instead — which is the whole of what
    /// loose means. HTML gets there by wrapping each item's content in a `<p>`
    /// and letting paragraph margins do the rest; with one number per stack, the
    /// same outcome is one number.
    private static let tightListSpacing: CGFloat = 6

    private static func stack(
        _ nodes: [MarkdownIR.BlockNode], style: MarkdownStyle, spacing: CGFloat
    ) -> BlockStack {
        BlockStack(nodes.map { block($0, style: style, spacing: spacing) }, spacing: spacing)
    }

    /// `spacing` is the rhythm of the stack this node is going into, passed down
    /// so a container can hand its children the same one — the only reason it
    /// travels at all is that a list is tighter than a document, and a block
    /// inside a list item belongs to the list's rhythm rather than the page's.
    private static func block(
        _ node: MarkdownIR.BlockNode, style: MarkdownStyle, spacing: CGFloat
    ) -> Block {
        switch node {
        case .paragraph(let inlines):
            return Paragraph(text(inlines, style: style))

        case .heading(let level, let inlines):
            return Heading(
                level: level,
                text: text(inlines, style: style, font: Heading.font(level: level)))

        case .blockquote(let children):
            return Blockquote(stack(children, style: style, spacing: spacing))

        case .thematicBreak:
            return ThematicBreak()

        case .codeBlock(let code):
            return CodeBlock(
                // Monospaced at the body size: a card sandwiched between
                // paragraphs has to match the text around it, which is the one
                // thing the card itself cannot know.
                text: ShapedText(
                    code.code,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: style.bodyFont.pointSize, weight: .regular),
                        .foregroundColor: style.textColor,
                    ]),
                badge: badge(code.language, style: style))

        case .list(let list):
            // The item's own blocks are stacked at the list's rhythm, not the
            // document's — which is what makes every gap inside one list match,
            // whether it separates two items, two paragraphs of one item, or an
            // item from the sub-list under it. Which rhythm that is, is the
            // loose/tight distinction and nothing else.
            let listSpacing = list.isTight ? tightListSpacing : blockSpacing
            return ListBuilder.make(
                items: list.items.enumerated().map { index, item in
                    ListBuilder.Item(
                        marker: ListBuilder.marker(
                            kind(for: item, at: index, in: list),
                            font: style.bodyFont, color: style.secondaryColor),
                        content: stack(item.content, style: style, spacing: listSpacing))
                },
                spacing: listSpacing,
                gap: style.bodyFont.pointSize * 0.5)

        case .table(let table):
            let headerFont = Table.headerFont(style.bodyFont)
            return Table(
                header: table.header.map { text($0, style: style, font: headerFont) },
                rows: table.rows.map { row in row.map { text($0, style: style) } },
                alignments: table.alignments.map(alignment))
        }
    }

    /// Lowers inline children and shapes the result — the single place text
    /// crosses from markdown into something a block can hold. Everything past
    /// this line is width-independent and stays that way until `measure`.
    private static func text(
        _ inlines: [MarkdownIR.InlineNode], style: MarkdownStyle, font: NSFont? = nil
    ) -> ShapedText {
        ShapedText(MarkdownInlineBuilder.attributed(inlines, style: style, font: font))
    }

    /// The language chip, typeset. `nil` for a bare fence or an indented block,
    /// which have no language to name.
    private static func badge(_ language: String?, style: MarkdownStyle) -> TypesetText? {
        let name = language?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard !name.isEmpty else { return nil }
        return ShapedText(
            name,
            attributes: [
                .font: NSFont.systemFont(ofSize: CodeBlock.badgeFontSize, weight: .regular),
                .foregroundColor: style.secondaryColor,
            ]
        ).typeset(width: .greatestFiniteMagnitude)
    }

    /// GFM's "no alignment specified" lays out as leading, which is what every
    /// renderer does with it and the only reason `Table.Alignment` has three
    /// cases where the IR has four.
    private static func alignment(_ alignment: MarkdownIR.Table.Alignment) -> Table.Alignment {
        switch alignment {
        case .center: return .center
        case .right: return .trailing
        case .left, .none: return .leading
        }
    }

    private static func kind(
        for item: MarkdownIR.List.Item, at index: Int, in list: MarkdownIR.List
    ) -> ListBuilder.Kind {
        switch item.checkbox {
        case .checked: return .task(checked: true)
        case .unchecked: return .task(checked: false)
        case nil: return list.ordered ? .ordinal((list.startIndex ?? 1) + index) : .bullet
        }
    }
}

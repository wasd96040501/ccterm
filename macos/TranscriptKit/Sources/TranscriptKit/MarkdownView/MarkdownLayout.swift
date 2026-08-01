import AppKit

/// Turns a parsed document into a `Layout`. The one place markdown and block
/// layout meet.
///
/// **No width appears in this file.** An adapter composes recipes; a width is
/// applied later, once, by whoever is filling a row. That is what keeps the
/// arithmetic for a quote's indent or a list's marker column inside the type that
/// owns it, instead of being spread across every call site that builds one.
///
/// It is also the only markdown-aware file below the parser. `Blockquote`, `List`,
/// `BlockStack` and the rest have never heard of `MarkdownIR`, so anything else that
/// wants to build a row composes them directly without going through here.
///
/// The `switch` is exhaustive: a case added to `MarkdownIR.BlockNode` fails to
/// compile here rather than disappearing from the screen. It is pure dispatch —
/// one line per case, no layout logic — which is what keeps a central switch from
/// being the place block behaviour accumulates.
enum MarkdownLayout {

    static func make(_ source: String, style: MarkdownStyle = .default) -> Layout {
        make(MarkdownConvert.document(source), style: style)
    }

    static func make(_ document: MarkdownIR.Document, style: MarkdownStyle) -> Layout {
        stack(document.blocks, style: style, spacing: blockSpacing)
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

    /// The gap inside a list, at every depth: between items, and between the
    /// blocks within one item. `NativeTranscript2` states these as two constants
    /// (`listItemSpacing`, `listIntraItemSpacing`) and gives both the same value,
    /// so a list has one rhythm no matter how it is shaped.
    private static let listSpacing: CGFloat = 6

    private static func stack(
        _ nodes: [MarkdownIR.BlockNode], style: MarkdownStyle, spacing: CGFloat
    ) -> BlockStack {
        BlockStack(nodes.map { layout($0, style: style, spacing: spacing) }, spacing: spacing)
    }

    /// `spacing` is the rhythm of the stack this node is going into, passed down
    /// so a container can hand its children the same one — the only reason it
    /// travels at all is that a list is tighter than a document, and a block
    /// inside a list item belongs to the list's rhythm rather than the page's.
    private static func layout(
        _ node: MarkdownIR.BlockNode, style: MarkdownStyle, spacing: CGFloat
    ) -> Layout {
        switch node {
        case .paragraph(let inlines):
            return Paragraph(MarkdownInline.attributed(inlines, style: style))

        case .heading(let level, let inlines):
            return Heading(
                level: level,
                attributed: MarkdownInline.attributed(
                    inlines, style: style, font: Heading.font(level: level)))

        case .blockquote(let children):
            var quote = Blockquote(stack(children, style: style, spacing: spacing))
            quote.barColor = style.secondaryColor
            return quote

        case .thematicBreak:
            var rule = ThematicBreak()
            rule.color = style.secondaryColor
            return rule

        case .codeBlock(let code):
            var card = CodeBlock(code: code.code, language: code.language)
            // Monospaced at the body size: the card's own default guesses one,
            // but the surrounding text is what it actually has to match.
            card.font = .monospacedSystemFont(ofSize: style.bodyFont.pointSize, weight: .regular)
            card.textColor = style.textColor
            card.badgeTextColor = style.secondaryColor
            return card

        case .list(let list):
            // The item's own blocks are stacked at the list's rhythm, not the
            // document's — which is what makes every gap inside a list the same
            // six, whether it separates two items, two paragraphs of one item, or
            // an item from the sub-list under it.
            var built = List(
                items: list.items.enumerated().map { index, item in
                    List.Item(
                        marker: marker(for: item, at: index, in: list),
                        content: stack(item.content, style: style, spacing: listSpacing))
                })
            built.font = style.bodyFont
            built.color = style.secondaryColor
            built.spacing = listSpacing
            return built

        case .table(let table):
            let headerFont = Table.headerFont(style.bodyFont)
            return Table(
                header: table.header.map {
                    MarkdownInline.attributed($0, style: style, font: headerFont)
                },
                rows: table.rows.map { row in
                    row.map { MarkdownInline.attributed($0, style: style) }
                },
                alignments: table.alignments.map(alignment))
        }
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

    private static func marker(
        for item: MarkdownIR.List.Item, at index: Int, in list: MarkdownIR.List
    ) -> List.Marker {
        switch item.checkbox {
        case .checked: return .task(checked: true)
        case .unchecked: return .task(checked: false)
        case nil: return list.ordered ? .ordinal((list.startIndex ?? 1) + index) : .bullet
        }
    }
}

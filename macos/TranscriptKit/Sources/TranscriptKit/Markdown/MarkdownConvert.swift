import Foundation
import Markdown

/// Lowers swift-markdown's AST into `MarkdownIR`.
///
/// Every `default` arm below is a decision rather than an omission: this is the
/// one place that says what a node this package doesn't draw degrades to. Add a
/// shape to `MarkdownIR` and the arm goes here — and only here, because
/// everything downstream switches over enums the compiler checks.
enum MarkdownParser {

    static func block(_ markup: Markdown.BlockMarkup) -> MarkdownIR.BlockNode? {
        switch markup {
        case let paragraph as Markdown.Paragraph:
            return .paragraph(inlines(Array(paragraph.inlineChildren)))

        case let heading as Markdown.Heading:
            return .heading(level: heading.level, inlines: inlines(Array(heading.inlineChildren)))

        case let quote as Markdown.BlockQuote:
            return .blockquote(blocks(Array(quote.blockChildren)))

        case let unordered as Markdown.UnorderedList:
            let items = Array(unordered.listItems).map { item(for: $0) }
            return .list(MarkdownIR.List(ordered: false, startIndex: nil, items: items))

        case let ordered as Markdown.OrderedList:
            let items = Array(ordered.listItems).map { item(for: $0) }
            return .list(
                MarkdownIR.List(ordered: true, startIndex: Int(ordered.startIndex), items: items))

        case let code as Markdown.CodeBlock:
            let info = code.language?.trimmingCharacters(in: .whitespaces)
            let language = (info?.isEmpty ?? true) ? nil : info
            // cmark always terminates a fenced block with a newline; keeping it
            // would typeset a trailing blank line inside the card.
            let body = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
            return .codeBlock(MarkdownIR.CodeBlock(language: language, code: body))

        case let node as Markdown.Table:
            return .table(table(node))

        case is Markdown.ThematicBreak:
            return .thematicBreak

        case let html as Markdown.HTMLBlock:
            // Shown as its source text. A transcript is program output;
            // interpreting embedded HTML would be a security surface, and
            // dropping it silently would hide content the model emitted.
            return .paragraph([.text(html.rawHTML)])

        default:
            // Nothing here has a rendering: footnote definitions, block
            // directives, doxygen commands. Dropped rather than degraded —
            // unlike raw HTML above, their source text is markup scaffolding
            // rather than something the author meant to be read.
            return nil
        }
    }

    static func blocks(_ markups: [Markdown.BlockMarkup]) -> [MarkdownIR.BlockNode] {
        markups.compactMap(block)
    }

    /// Parses GFM source into the IR — the entry point everything upstream of
    /// the renderer goes through.
    ///
    /// `.parseBlockDirectives` is left off: the syntax is Swift-DocC's, not
    /// GFM's, and enabling it would turn a line of prose beginning with `@` into
    /// a directive node that `block(_:)` then drops.
    static func document(_ source: String) -> MarkdownIR.Document {
        let parsed = Markdown.Document(parsing: source, options: [])
        return MarkdownIR.Document(blocks: blocks(Array(parsed.blockChildren)))
    }

    static func item(for listItem: Markdown.ListItem) -> MarkdownIR.List.Item {
        let checkbox: MarkdownIR.List.Item.Checkbox?
        switch listItem.checkbox {
        case .some(.checked): checkbox = .checked
        case .some(.unchecked): checkbox = .unchecked
        case .none: checkbox = nil
        }
        return MarkdownIR.List.Item(
            checkbox: checkbox, content: blocks(Array(listItem.blockChildren)))
    }

    static func inlines(_ markups: [Markdown.InlineMarkup]) -> [MarkdownIR.InlineNode] {
        inlines(markups, insideLink: false)
    }

    /// `insideLink` gates bare-URL detection. It is off inside `[…](url)` so a
    /// URL appearing in the link *text* isn't turned into an inner link that
    /// would shadow the outer destination.
    private static func inlines(
        _ markups: [Markdown.InlineMarkup], insideLink: Bool
    ) -> [MarkdownIR.InlineNode] {
        var result: [MarkdownIR.InlineNode] = []
        for markup in markups {
            switch markup {
            case let text as Markdown.Text:
                if insideLink {
                    result.append(.text(text.string))
                } else {
                    result.append(contentsOf: MarkdownAutolink.split(text.string))
                }
            case let emphasis as Markdown.Emphasis:
                result.append(
                    .emphasis(inlines(Array(emphasis.inlineChildren), insideLink: insideLink)))
            case let strong as Markdown.Strong:
                result.append(
                    .strong(inlines(Array(strong.inlineChildren), insideLink: insideLink)))
            case let strike as Markdown.Strikethrough:
                result.append(
                    .strikethrough(inlines(Array(strike.inlineChildren), insideLink: insideLink)))
            case let code as Markdown.InlineCode:
                result.append(.code(code.code))
            case let link as Markdown.Link:
                result.append(
                    .link(
                        destination: link.destination ?? "",
                        children: inlines(Array(link.inlineChildren), insideLink: true)))
            case let image as Markdown.Image:
                result.append(.image(source: image.source ?? "", alt: image.plainText))
            case is Markdown.LineBreak:
                result.append(.lineBreak)
            case is Markdown.SoftBreak:
                result.append(.softBreak)
            case let html as Markdown.InlineHTML:
                result.append(.text(html.rawHTML))
            case let symbol as Markdown.SymbolLink:
                if let destination = symbol.destination {
                    result.append(.text(destination))
                }
            default:
                result.append(.text(markup.plainText))
            }
        }
        return result
    }

    static func table(_ table: Markdown.Table) -> MarkdownIR.Table {
        let header = Array(table.head.cells).map { inlines(Array($0.inlineChildren)) }

        let alignments: [MarkdownIR.Table.Alignment] = table.columnAlignments.map { raw in
            switch raw {
            case .some(.left): return .left
            case .some(.center): return .center
            case .some(.right): return .right
            case .none: return .none
            }
        }

        let rows = Array(table.body.rows).map { row in
            Array(row.cells).map { cell in inlines(Array(cell.inlineChildren)) }
        }

        return MarkdownIR.Table(header: header, alignments: alignments, rows: rows)
    }
}

extension MarkdownIR.Document {

    /// Parses GFM source.
    ///
    /// Smart typography is disabled: a transcript carries program output, where
    /// a straight quote is a straight quote and `--` is two hyphens, not an
    /// en dash.
    init(parsing source: String) {
        let document = Markdown.Document(parsing: source, options: [.disableSmartOpts])
        self.init(blocks: MarkdownParser.blocks(Array(document.blockChildren)))
    }
}

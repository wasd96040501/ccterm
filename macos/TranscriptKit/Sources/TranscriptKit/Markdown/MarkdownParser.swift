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
            return .list(list(unordered, ordered: false, startIndex: nil))

        case let ordered as Markdown.OrderedList:
            return .list(list(ordered, ordered: true, startIndex: Int(ordered.startIndex)))

        case let code as Markdown.CodeBlock:
            // The info string's **first word** is the language. CommonMark leaves
            // the rest to whoever consumes it, and renderers that pass the whole
            // string through end up with a chip reading `swift title="x"`.
            let language = code.language?
                .split(whereSeparator: \.isWhitespace).first
                .map(String.init)
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
            // Nothing here has a rendering: block directives, doxygen commands,
            // DocC asides. Dropped rather than degraded — unlike raw HTML above,
            // their source text is markup scaffolding rather than something the
            // author meant to be read.
            //
            // Footnotes are *not* among them, despite looking like they should
            // be: swift-markdown has no footnote node at all, so `[^1]` arrives
            // as ordinary text. `MarkdownFootnotes` lifts them out before this
            // sees anything.
            return nil
        }
    }

    static func blocks(_ markups: [Markdown.BlockMarkup]) -> [MarkdownIR.BlockNode] {
        markups.compactMap(block)
    }

    /// Parses GFM source into the IR — **the** entry point, and the only place
    /// that names a parse option.
    ///
    /// `.disableSmartOpts` because a transcript carries program output, where a
    /// straight quote is a straight quote and `--` is two hyphens. Smart
    /// typography is on by default in swift-markdown, and left on it rewrites
    /// `git commit --amend` to `git commit –amend` in any line of prose that
    /// isn't a code span. This flag used to live on a second entry point that
    /// nothing called, so the documented intent and the shipped behaviour
    /// disagreed; there is one entry point now so they cannot.
    ///
    /// `.parseBlockDirectives` is left off: the syntax is Swift-DocC's, not
    /// GFM's, and enabling it would turn a line of prose beginning with `@` into
    /// a directive node that `block(_:)` then drops.
    static func document(_ source: String) -> MarkdownIR.Document {
        let (body, definitions) = MarkdownFootnotes.split(source)
        return MarkdownFootnotes.resolve(fragment(body), definitions: definitions)
    }

    /// A run of markdown lowered to blocks, with the options `document(_:)` uses
    /// — the seam a footnote's own body comes back through, since it was lifted
    /// out of the source before the document was parsed.
    static func fragment(_ source: String) -> [MarkdownIR.BlockNode] {
        let parsed = Markdown.Document(parsing: source, options: [.disableSmartOpts])
        return blocks(Array(parsed.blockChildren))
    }

    static func list(
        _ container: Markdown.ListItemContainer, ordered: Bool, startIndex: Int?
    ) -> MarkdownIR.List {
        let items = Array(container.listItems)
        return MarkdownIR.List(
            ordered: ordered,
            startIndex: startIndex,
            isTight: isTight(items),
            items: items.map { item(for: $0) })
    }

    /// CommonMark's loose/tight rule, recovered from source positions: a list is
    /// loose if a blank line separates two of its items, or two blocks inside one
    /// item.
    ///
    /// cmark settles this while parsing and swift-markdown drops the answer, so
    /// the line numbers are the only route back to it. They are there because
    /// `CMARK_OPT_SOURCEPOS` is on unless a caller passes `.disableSourcePosOpts`,
    /// and `document(_:)` does not — if that ever changes, every list silently
    /// becomes tight, which is the failure mode to watch for.
    ///
    /// The gap between two items is measured from the first item's **content**
    /// rather than from the item itself, because cmark extends a loose item's
    /// own range over the blank line that follows it. Comparing item ranges
    /// therefore asks a question whose answer is already the one being computed:
    /// in `- a\n\n- b` the first item reports it ends on line 2, leaving no gap
    /// before an item starting on line 3, and every loose list reads as tight.
    private static func isTight(_ items: [Markdown.ListItem]) -> Bool {
        let separated = zip(items, items.dropFirst()).contains { first, second in
            guard let end = contentEndLine(of: first), let start = second.range?.lowerBound.line
            else { return false }
            return start > end + 1
        }
        return !separated && !items.contains { hasBlankLine(between: $0.blockChildren.map(\.range)) }
    }

    /// The last line an item's content occupies — which is not where the item
    /// ends. See `isTight(_:)`.
    private static func contentEndLine(of item: Markdown.ListItem) -> Int? {
        item.blockChildren.compactMap { $0.range?.upperBound.line }.max()
            ?? item.range?.upperBound.line
    }

    /// Whether any two consecutive nodes have a blank line between them — the
    /// second starting more than one line after the first ended.
    ///
    /// A `nil` range reads as "no blank line": it can only come from a node this
    /// package didn't parse, and guessing loose there would space out a list for
    /// a reason nobody could see in the source.
    private static func hasBlankLine(between ranges: [SourceRange?]) -> Bool {
        zip(ranges, ranges.dropFirst()).contains { first, second in
            guard let end = first?.upperBound.line, let start = second?.lowerBound.line
            else { return false }
            return start > end + 1
        }
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
                        title: link.title,
                        children: inlines(Array(link.inlineChildren), insideLink: true)))
            case let image as Markdown.Image:
                result.append(
                    .image(source: image.source ?? "", title: image.title, alt: image.plainText))
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

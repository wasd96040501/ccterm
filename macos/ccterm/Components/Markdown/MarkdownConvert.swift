import Foundation
import Markdown

/// Converts a swift-markdown AST (`Markdown.Markup`) to our internal
/// `MarkdownBlock` / `MarkdownInline` tree.
///
/// The conversion happens after block-math extraction but also handles
/// inline `$...$` math by post-processing plain text content.
nonisolated enum MarkdownConvert {
    static func block(_ markup: Markdown.BlockMarkup) -> MarkdownBlock? {
        switch markup {
        case let paragraph as Markdown.Paragraph:
            return .paragraph(inlines(Array(paragraph.inlineChildren)))
        case let heading as Markdown.Heading:
            return .heading(level: heading.level, children: inlines(Array(heading.inlineChildren)))
        case let quote as Markdown.BlockQuote:
            return .blockquote(blocks(Array(quote.blockChildren)))
        case let unordered as Markdown.UnorderedList:
            let items: [MarkdownListItem] = Array(unordered.listItems).map { item(for: $0) }
            return .list(MarkdownList(ordered: false, startIndex: nil, items: items))
        case let ordered as Markdown.OrderedList:
            let items: [MarkdownListItem] = Array(ordered.listItems).map { item(for: $0) }
            return .list(MarkdownList(ordered: true, startIndex: Int(ordered.startIndex), items: items))
        default:
            return nil
        }
    }

    static func blocks(_ markups: [Markdown.BlockMarkup]) -> [MarkdownBlock] {
        markups.compactMap(block)
    }

    private static func item(for listItem: Markdown.ListItem) -> MarkdownListItem {
        let cb: MarkdownListItem.Checkbox?
        switch listItem.checkbox {
        case .some(.checked): cb = .checked
        case .some(.unchecked): cb = .unchecked
        case .none: cb = nil
        }
        return MarkdownListItem(checkbox: cb, content: blocks(Array(listItem.blockChildren)))
    }

    static func inlines(_ markups: [Markdown.InlineMarkup]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for markup in markups {
            switch markup {
            case let text as Markdown.Text:
                result.append(contentsOf: MarkdownMath.splitInlineMath(in: text.string))
            case let emphasis as Markdown.Emphasis:
                result.append(.emphasis(inlines(Array(emphasis.inlineChildren))))
            case let strong as Markdown.Strong:
                result.append(.strong(inlines(Array(strong.inlineChildren))))
            case let strike as Markdown.Strikethrough:
                result.append(.strikethrough(inlines(Array(strike.inlineChildren))))
            case let code as Markdown.InlineCode:
                result.append(.code(code.code))
            case let link as Markdown.Link:
                result.append(.link(destination: link.destination ?? "", children: inlines(Array(link.inlineChildren))))
            case let image as Markdown.Image:
                result.append(.image(source: image.source ?? "", alt: image.plainText))
            case is Markdown.LineBreak:
                result.append(.lineBreak)
            case is Markdown.SoftBreak:
                result.append(.softBreak)
            case let html as Markdown.InlineHTML:
                result.append(.text(html.rawHTML))
            case let symbol as Markdown.SymbolLink:
                if let dest = symbol.destination {
                    result.append(.text(dest))
                }
            default:
                result.append(.text(markup.plainText))
            }
        }
        return result
    }

    /// Build a `MarkdownTable` from a swift-markdown `Table`.
    static func table(_ table: Markdown.Table) -> MarkdownTable {
        let header: [[MarkdownInline]] = Array(table.head.cells).map { inlines(Array($0.inlineChildren)) }

        let alignments: [MarkdownTable.Alignment] = table.columnAlignments.map { raw in
            switch raw {
            case .some(.left): return .left
            case .some(.center): return .center
            case .some(.right): return .right
            case .none: return .none
            }
        }

        let rows: [[[MarkdownInline]]] = Array(table.body.rows).map { row in
            Array(row.cells).map { cell in inlines(Array(cell.inlineChildren)) }
        }

        return MarkdownTable(header: header, alignments: alignments, rows: rows)
    }
}

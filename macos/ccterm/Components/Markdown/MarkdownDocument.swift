import Foundation
import Markdown

/// Parses a GFM markdown source into an ordered list of `MarkdownSegment`s.
///
/// Segments separate content that can be rendered by TextKit (`.markdown`) from
/// content that should be rendered by dedicated SwiftUI components (code blocks,
/// tables, block math). Thematic breaks are emitted as their own segment so the
/// host view can draw a native divider.
public struct MarkdownDocument: Hashable, Sendable {
    public let segments: [MarkdownSegment]

    public init(parsing source: String) {
        let chunks = MarkdownMath.splitByBlockMath(source)
        var segments: [MarkdownSegment] = []

        for chunk in chunks {
            switch chunk {
            case .mathBlock(let content):
                segments.append(.mathBlock(content))

            case .markdown(let raw):
                let document = Markdown.Document(parsing: raw, options: [.disableSmartOpts])
                segments.append(contentsOf: Self.segments(from: document))
            }
        }

        self.segments = segments
    }

    /// Walk a parsed `Document`'s top-level block children and split them into
    /// `MarkdownSegment`s. Consecutive TextKit-renderable blocks are merged into
    /// a single `.markdown` segment; extractable blocks (code, table, HR) become
    /// their own segment.
    private static func segments(from document: Markdown.Document) -> [MarkdownSegment] {
        var out: [MarkdownSegment] = []
        var buffer: [MarkdownBlock] = []

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            out.append(.markdown(buffer))
            buffer.removeAll()
        }

        for child in document.blockChildren {
            switch child {
            case let heading as Markdown.Heading:
                flushBuffer()
                let inlines = MarkdownConvert.inlines(Array(heading.inlineChildren))
                out.append(.heading(level: heading.level, inlines: inlines))

            case let quote as Markdown.BlockQuote:
                flushBuffer()
                let inner = MarkdownConvert.blocks(Array(quote.blockChildren))
                out.append(.blockquote(inner))

            case let code as Markdown.CodeBlock:
                flushBuffer()
                let language = code.language?.trimmingCharacters(in: .whitespaces)
                let lang = (language?.isEmpty == true) ? nil : language
                let stripped = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
                out.append(.codeBlock(MarkdownCodeBlock(language: lang, code: stripped)))

            case let table as Markdown.Table:
                flushBuffer()
                out.append(.table(MarkdownConvert.table(table)))

            case is Markdown.ThematicBreak:
                flushBuffer()
                out.append(.thematicBreak)

            case let html as Markdown.HTMLBlock:
                // Preserve raw HTML as plain-text paragraph in the markdown buffer.
                // TextKit renderer decides what to do (v1: render as text).
                buffer.append(.paragraph([.text(html.rawHTML)]))

            default:
                if let block = MarkdownConvert.block(child) {
                    buffer.append(block)
                }
            }
        }
        flushBuffer()

        return out
    }
}

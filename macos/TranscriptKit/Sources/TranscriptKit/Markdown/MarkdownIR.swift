import Foundation

/// The renderable subset of a GFM document, as plain values.
///
/// Deliberately **not** a mirror of swift-markdown's AST. Three differences,
/// each of which is a reason this layer exists rather than drawing off
/// `Markdown.Document` directly:
///
/// - **Exhaustiveness.** The AST models nodes as protocol existentials
///   (`BlockMarkup` / `InlineMarkup`) walked by dynamic casts, so every `switch`
///   over it needs a `default` and the compiler can never report a missing
///   case. Rendering is exactly where a missed case must not fail quietly — a
///   shape nobody handles simply doesn't appear on screen. These are enums.
/// - **A narrowing, decided once.** cmark-gfm parses more than this package
///   draws — footnotes, block directives, raw HTML. `MarkdownConvert` is the
///   single place that says what each of those degrades to. Drawing off the AST
///   would scatter that decision across a `default` arm in every drawing
///   routine, to be answered slightly differently each time.
/// - **Additions the AST doesn't have.** A bare URL becomes `.link` here;
///   there is no such node upstream. Doing it while parsing means once per
///   edit rather than once per draw.
///
/// The tree carries no "these blocks can share one typeset run, those need
/// their own geometry" distinction. Every `BlockNode` is one unit in a vertical
/// stack, and a container — a blockquote, a list item — is simply a nested
/// stack, the same way `NSStackView` nests. Merging consecutive paragraphs into
/// a single typeset run would save a couple of framesetter calls and cost the
/// ability to re-typeset only the paragraph that actually changed, which is the
/// wrong trade for streaming output that re-parses on every token.
///
/// That last point is also why every value is `Hashable`: an assistant message
/// re-parses in full on each arriving token, and comparing the new nodes
/// against the previous ones is how the typesetter learns that only the last
/// one moved.
enum MarkdownIR {

    /// A parsed document — its top-level blocks in source order.
    struct Document: Hashable, Sendable {
        let blocks: [BlockNode]
    }

    /// One unit of the document's vertical flow.
    ///
    /// `Node` rather than bare `MarkdownBlock` for two reasons: it marks these as
    /// syntax-tree values, distinct from the `…Layout` types that hold typeset
    /// geometry; and `block` / `inline` are CommonMark's own terms, worth
    /// keeping so the spec reads across.
    indirect enum BlockNode: Hashable, Sendable {
        case paragraph([InlineNode])
        case heading(level: Int, inlines: [InlineNode])
        case blockquote([BlockNode])
        case list(List)
        case codeBlock(CodeBlock)
        case table(Table)
        case thematicBreak
    }

    /// A span within a block's text.
    indirect enum InlineNode: Hashable, Sendable {
        case text(String)
        case emphasis([InlineNode])
        case strong([InlineNode])
        case strikethrough([InlineNode])
        case code(String)
        case link(destination: String, children: [InlineNode])
        case image(source: String, alt: String)

        /// A hard break — trailing backslash or two spaces. Starts a new line
        /// inside the same block.
        case lineBreak

        /// A newline in the source that CommonMark folds into a space. Kept
        /// distinct from `.text(" ")` so the typesetter can decide (it may want
        /// to break there, but must not show a literal space at a wrap point).
        case softBreak
    }

    struct List: Hashable, Sendable {
        let ordered: Bool

        /// The number the first item carries; `nil` when unordered.
        let startIndex: Int?

        let items: [Item]

        struct Item: Hashable, Sendable {
            enum Checkbox: Hashable, Sendable { case checked, unchecked }

            /// Non-nil only for GFM task-list items (`- [ ]` / `- [x]`).
            let checkbox: Checkbox?

            let content: [BlockNode]
        }
    }

    struct CodeBlock: Hashable, Sendable {
        /// The opening fence's info string, trimmed; `nil` for an indented
        /// block or a bare fence.
        let language: String?

        /// Verbatim source, trailing newline removed.
        let code: String
    }

    struct Table: Hashable, Sendable {
        enum Alignment: Hashable, Sendable { case none, left, center, right }

        let header: [[InlineNode]]

        /// One entry per column, in column order.
        let alignments: [Alignment]

        /// Body rows, each a list of cells, each cell a list of inlines.
        let rows: [[[InlineNode]]]
    }
}

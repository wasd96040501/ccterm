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
///   draws — block directives, doxygen commands, raw HTML. `MarkdownParser` is
///   the single place that says what each of those degrades to. Drawing off the
///   AST would scatter that decision across a `default` arm in every drawing
///   routine, to be answered slightly differently each time.
/// - **Additions the AST doesn't have.** A bare URL becomes `.link` here and a
///   `[^1]` becomes `.footnoteReference`; upstream has neither node. Doing it
///   while parsing means once per edit rather than once per draw — and for
///   footnotes it means the numbering is settled in one pass instead of being
///   re-derived by whoever draws the marker and whoever draws the note.
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

        /// The footnotes something in `blocks` refers to, numbered in the order
        /// those references appear. Empty for almost every document.
        ///
        /// Beside the blocks rather than among them, because a footnote section
        /// is not a block the author wrote — it is assembled from definitions
        /// that were scattered through the source, and only whoever renders the
        /// whole document is in a position to put it anywhere.
        let footnotes: [Footnote]

        struct Footnote: Hashable, Sendable {
            let number: Int

            /// The label as written, kept for nothing but debugging: two notes
            /// never share one, and the number is what renders.
            let label: String

            let blocks: [BlockNode]
        }
    }

    /// One unit of the document's vertical flow.
    ///
    /// `Node` rather than bare `Block` for two reasons: it marks these as
    /// syntax-tree values, distinct from the `Block` / `MeasuredBlock` types
    /// that hold layout and geometry; and `block` / `inline` are CommonMark's
    /// own terms, worth
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

        /// `title` is the quoted string in `[text](url "title")` — what a browser
        /// shows on hover, and the only part of a link that has no glyphs of its
        /// own. Carried rather than dropped because the renderer surfaces it as a
        /// tooltip.
        case link(destination: String, title: String?, children: [InlineNode])

        /// `alt` is the bracket text, `title` the quoted one. Both are kept
        /// because neither is reliably present and the renderer prefers `alt`,
        /// which is the one authored for the case where the image isn't shown —
        /// exactly this one.
        case image(source: String, title: String?, alt: String)

        /// A hard break — trailing backslash or two spaces. Starts a new line
        /// inside the same block.
        case lineBreak

        /// A `[^label]` whose definition was found. Carries the number rather
        /// than the label because that is what renders, and because resolving it
        /// twice — once to number the note, once to draw the marker — is how the
        /// two drift apart.
        case footnoteReference(label: String, number: Int)

        /// A newline in the source that CommonMark folds into a space. Kept
        /// distinct from `.text(" ")` so the typesetter can decide (it may want
        /// to break there, but must not show a literal space at a wrap point).
        case softBreak
    }

    struct List: Hashable, Sendable {
        let ordered: Bool

        /// The number the first item carries; `nil` when unordered.
        let startIndex: Int?

        /// CommonMark's loose/tight distinction, which decides how much air the
        /// items get: a tight list is one thought broken into lines, a loose one
        /// is a run of paragraphs that happen to be numbered.
        ///
        /// Derived rather than read off the AST — cmark tracks it, but
        /// swift-markdown exposes no `isTight`, so `MarkdownParser` recovers it
        /// from source positions. Kept here anyway, because "how far apart do
        /// these sit" is a property of the list and not of whoever draws it.
        let isTight: Bool

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

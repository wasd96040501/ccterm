import Foundation

/// Recursive inline-formatting IR. Mirrors the CommonMark inline AST: parsers
/// produce a tree of these, the layout pipeline walks the tree to build an
/// `NSAttributedString`. Block-level kinds (`.paragraph`, `.heading`) carry
/// `[InlineNode]` instead of raw `String` so inline emphasis / links survive
/// down to the renderer without re-parsing.
///
/// `code` deliberately has no children: CommonMark forbids further inline
/// markup inside a code span. `link` carries already-resolved children so
/// nested emphasis (e.g. `[**bold**](url)`) renders as a styled, tappable
/// run rather than the parser flattening it away.
enum InlineNode: Equatable, Sendable {
    case text(String)
    case strong([InlineNode])
    case emphasis([InlineNode])
    case code(String)
    case link(children: [InlineNode], url: URL)
    /// Hard line break inside a block (markdown's two-space-newline / `<br>`).
    /// A paragraph break ends the block — that's an entirely separate `Block`.
    case lineBreak
}

extension InlineNode {
    /// Sum of visible-character lengths across an inline tree. Hard line
    /// breaks count as one. Used by stress / metric views that report
    /// "characters in transcript" without caring about emphasis structure.
    static func charCount(_ nodes: [InlineNode]) -> Int {
        var total = 0
        for node in nodes {
            switch node {
            case .text(let s), .code(let s): total += s.count
            case .strong(let cs), .emphasis(let cs): total += charCount(cs)
            case .link(let cs, _): total += charCount(cs)
            case .lineBreak: total += 1
            }
        }
        return total
    }
}


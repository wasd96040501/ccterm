import AppKit

/// A section heading. Typeset like a paragraph; spaced like a heading.
///
/// Its own type rather than a `Paragraph` with different numbers, because both
/// numbers that make a heading a heading — the size it renders at and the space
/// it claims — follow from the level, and keeping them here is what stops them
/// being scattered into a table keyed by node kind somewhere else. Whoever lowers
/// the text asks `Heading.font(level:)` for the face; nothing else needs to know
/// what an h2 is.
struct Heading: Layout {

    let level: Int
    let text: MarkdownText

    init(level: Int, text: MarkdownText) {
        self.level = level
        self.text = text
    }

    /// h1 26 / h2 22 / h3–h6 18, semibold. Markdown's six levels collapse to
    /// three visual tiers — chat content rarely goes deeper than h3, and
    /// shrinking the tail levels toward body size makes them read as emphasis
    /// rather than as structure.
    static func font(level: Int) -> NSFont {
        let size: CGFloat
        switch clamp(level) {
        case 1: size = 26
        case 2: size = 22
        default: size = 18
        }
        return .systemFont(ofSize: size, weight: .semibold)
    }

    /// Extra room **above** a heading, on top of whatever the container already
    /// puts between two blocks: a wide space there is what marks a section break.
    /// Scaled by level so the same gap does not read as generous under an
    /// 18-point h3 and mean under a 26-point h1.
    ///
    /// Nothing below. A heading wants to sit closer to the content it owns than
    /// two paragraphs sit to each other, and that is the one thing this cannot
    /// express — the container's spacing is a floor, and a block can only add to
    /// it. So a heading is followed by the same gap as anything else.
    private var extraTop: CGFloat {
        switch Self.clamp(level) {
        case 1: return 18
        case 2: return 10
        default: return 4
        }
    }

    func measure(_ width: CGFloat) -> MarkdownBlock {
        let run = text.run(width: width)
        let extraTop = extraTop
        return Paragraph.Measured(
            run: run,
            textOrigin: CGPoint(x: 0, y: extraTop),
            size: CGSize(width: width, height: extraTop + run.size.height))
    }

    private static func clamp(_ level: Int) -> Int { max(1, min(6, level)) }
}

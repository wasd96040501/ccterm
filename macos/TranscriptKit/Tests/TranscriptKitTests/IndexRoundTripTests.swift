import AppKit
import XCTest

@testable import TranscriptKit

/// The property the whole selection model rests on, and the one nothing was
/// watching: **a block agrees with itself about where a position is.** Point at
/// something, take the index back, ask where that index is — and be told the
/// place you were pointing.
///
/// Every container maps its children onto one flat line by adding a `base` on the
/// way up and subtracting it on the way down. Get one of those wrong and nothing
/// fails: the block still measures, still paints, still answers every call. What
/// breaks is a drag across the seam, and it breaks by selecting the wrong text —
/// the kind of defect that reaches a reader before it reaches a test.
///
/// ## Driven from points, not from the index space
///
/// The obvious shape — walk `0..<length` and ask each position where it is — is
/// wrong, and wrong in a way worth recording. `rects(from:to:)` does not answer
/// "where is position `i`"; it answers "what does a selection from `i` to `i+1`
/// cover", and a table is the block where those differ. A pair straddling a cell
/// boundary is a **structural** selection, so the table correctly hands back whole
/// cell bands rather than one glyph's box — and an index walk reads that correct
/// answer as a failure at every separator slot.
///
/// Sweeping points has no such seam. A point is always somewhere real, no sample
/// ever lands on a separator, and the property comes out as the one the renderer
/// actually depends on: *the rectangle I draw for what I found is where I found
/// it.* That is the same sentence a hover highlight is built on, which is why the
/// link half below is the same assertion one level up.
@MainActor
final class IndexRoundTripTests: XCTestCase {

    /// Every markdown shape that puts an index space behind an offset. Ordered
    /// roughly by how much translating each does, so a failure's name says how deep
    /// the arithmetic went before it went wrong.
    private static let corpus: [(name: String, source: String)] = [
        ("paragraph", "a short paragraph of ordinary words"),
        ("heading", "## A heading, and then some\n\nfollowed by prose"),
        ("emphasis", "text with *emphasis*, `code`, and [a link](https://example.com)"),
        ("code block", "```swift\nlet a = 1\nlet b = 2\n```"),
        ("stack", "first paragraph\n\nsecond paragraph\n\nthird paragraph"),
        ("rule between paragraphs", "before the rule\n\n---\n\nafter the rule"),
        ("bullet list", "- alpha\n- beta\n- gamma"),
        ("ordered list", "1. alpha\n2. beta\n3. gamma"),
        ("task list", "- [ ] undone\n- [x] done"),
        ("nested list", "- outer\n  - inner one\n  - inner two"),
        ("blockquote", "> quoted words\n>\n> and a second paragraph"),
        ("quote around a list", "> - alpha\n> - beta"),
        ("quote around code", "> ```\n> fenced\n> ```"),
        ("table", "| h1 | h2 |\n|----|----|\n| a | b |\n| c | d |"),
        ("table with an empty cell", "| h1 | h2 |\n|----|----|\n| a |  |\n|  | d |"),
        ("table holding a link", "| h |\n|---|\n| [word](https://example.com) |"),
        (
            "everything at once",
            """
            # Title

            A paragraph with [a link](https://example.com) in it.

            - alpha
            - beta

            > quoted

            | h1 | h2 |
            |----|----|
            | a | b |

            ```
            code
            ```

            closing words
            """
        ),
    ]

    private static let width: CGFloat = 400

    /// Coarse enough to keep the whole corpus under a second, fine enough that
    /// every glyph of body text is hit several times over. Density is not the
    /// point — reaching every container is, and a full-bounds sweep does that by
    /// construction rather than by anyone choosing where to look.
    private static let step: CGFloat = 3

    func testABlockAgreesWithItselfAboutWhereAPositionIs() throws {
        for (name, source) in Self.corpus {
            let block = MarkdownBlockBuilder.make(source).measure(Self.width)
            XCTAssertGreaterThan(
                block.length, 0,
                "\(name): measured to an empty index space, so nothing was checked")

            var found: Set<Int> = []
            // Kept rather than asserted in the loop: one wrong `base` is wrong at
            // every point over that child, and a few thousand identical failures
            // bury the one line that says which block it was.
            var mismatch: (point: CGPoint, index: Int, rects: [CGRect])?

            for y in stride(from: 0, to: block.size.height, by: Self.step) {
                for x in stride(from: 0, to: Self.width, by: Self.step) {
                    let point = CGPoint(x: x, y: y)
                    guard let index = block.characterIndex(at: point) else { continue }
                    found.insert(index)

                    guard mismatch == nil else { continue }
                    let rects = block.rects(from: index, to: index + 1)
                    if !rects.contains(where: { $0.contains(point) }) {
                        mismatch = (point, index, rects)
                    }
                }
            }

            if let bad = mismatch {
                XCTFail(
                    """
                    \(name): pointing at \(bad.point) gave index \(bad.index), \
                    which the block places at \(bad.rects)
                    """)
            }

            // The sweep has to have provoked something, and it has to have reached
            // the far end of the index space — a wrong `base` in the *last* child
            // or cell is exactly what a sweep that stopped early would miss.
            XCTAssertFalse(found.isEmpty, "\(name): no point in the block was on a character")
            XCTAssertTrue(
                found.contains { $0 < block.length / 2 },
                "\(name): nothing was found in the first half of the index space")
            XCTAssertTrue(
                found.contains { $0 >= block.length / 2 },
                "\(name): nothing was found in the second half of the index space")
        }
    }

    /// The same property one level up, in the currency a link now speaks: a link's
    /// range, decoded back to geometry, has to land on the glyphs the pointer found
    /// it by.
    ///
    /// This is what a container that forwards the point but forgets to lift the
    /// range fails — and it would fail *silently* without this, because the URL is
    /// still correct and only the highlight would be drawn somewhere else.
    func testALinksRangeLandsOnTheGlyphsItWasFoundBy() throws {
        let cases: [(name: String, source: String)] = [
            ("bare", "[word](https://example.com)"),
            ("in prose", "some words, then [word](https://example.com), then more"),
            ("in a quote", "> [word](https://example.com)"),
            ("in a list", "- [word](https://example.com)"),
            ("in a nested list inside a quote", "> - [word](https://example.com)"),
            ("after other blocks", "first paragraph\n\nsecond with [word](https://example.com)"),
            ("in a table cell", "| h1 | h2 |\n|----|----|\n| plain | [word](https://example.com) |"),
        ]

        for (name, source) in cases {
            let block = MarkdownBlockBuilder.make(source).measure(Self.width)
            let point = try XCTUnwrap(
                Self.firstLinkPoint(in: block), "\(name): no link found anywhere in the block")
            let link = try XCTUnwrap(
                block.link(at: point), "\(name): the link vanished at its own point")

            let rects = block.rects(from: link.range.lowerBound, to: link.range.upperBound)
            XCTAssertFalse(rects.isEmpty, "\(name): the link's range covers no geometry")
            XCTAssertTrue(
                rects.contains { $0.contains(point) },
                "\(name): range \(link.range) draws at \(rects), which does not contain \(point)")

            // And the range names the link's own text, not a slice of its
            // neighbours — the failure a lift that is off by a few would produce
            // while still overlapping enough geometry to pass the check above.
            XCTAssertEqual(
                block.text(from: link.range.lowerBound, to: link.range.upperBound), "word",
                "\(name): range \(link.range) does not cover the link's own text")
        }
    }

    /// Sweeps for a point that reports a link, rather than computing where one
    /// ought to be. The subject here is that arithmetic about where a run sits can
    /// be wrong, so a helper that derived the point would be assuming what is under
    /// test.
    private static func firstLinkPoint(in block: MeasuredBlock) -> CGPoint? {
        for y in stride(from: 0, to: block.size.height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let point = CGPoint(x: x, y: y)
                if block.link(at: point) != nil { return point }
            }
        }
        return nil
    }
}

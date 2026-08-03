import AppKit
import XCTest

@testable import TranscriptKit

/// Selection across a tree of blocks — the claim that a container needs no
/// selection code of its own beyond splitting endpoints and offsetting what
/// comes back.
///
/// No window, no mount. That is worth stating rather than assuming: the rest of
/// this suite has to mount because `NSTableView` only asks its data source
/// anything when it lays out, whereas a measured block is a value that answers
/// the same way whether or not it is on screen. If a test here ever needs a
/// mount, something has leaked out of the value layer.
final class BlockStackSelectionTests: XCTestCase {

    // MARK: - Fixture

    /// Monospaced so that character offsets and x-coordinates relate
    /// predictably, and one attribute set for every paragraph so a difference in
    /// the assertions is a difference in the tree, not in the styling.
    ///
    /// A paragraph claims no space of its own, so the vertical arithmetic in a
    /// test is only what that test's `spacing` put there.
    private func paragraph(_ text: String) -> Paragraph {
        Paragraph(Self.text(text))
    }

    private func run(_ text: String, width: CGFloat = 400) -> MarkdownTextRun {
        Self.text(text).run(width: width)
    }

    private static func text(_ string: String) -> MarkdownText {
        MarkdownText(
            string, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
    }

    /// A list at the fixture font, markers rendered the way `MarkdownLayout`
    /// renders them — the marker column is settled before any width is known, so
    /// this is a plain `BlockStack` by the time a test sees it.
    private func list(_ items: [(List.Kind, Layout)]) -> BlockStack {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return List.make(
            items: items.map {
                List.Item(
                    marker: List.marker($0.0, font: font, color: .secondaryLabelColor),
                    content: $0.1)
            },
            spacing: 6,
            gap: font.pointSize * 0.5)
    }

    // MARK: - One run

    func testRunTypesetsOneLinePerHardBreak() {
        let run = run("alpha\nbeta")
        XCTAssertEqual(run.lines.count, 2)
        XCTAssertEqual(run.length, "alpha\nbeta".utf16.count)
    }

    func testWrappingProducesMoreLinesThanTheSourceHas() {
        let narrow = run(String(repeating: "word ", count: 60), width: 100)
        XCTAssertGreaterThan(narrow.lines.count, 1)
        XCTAssertLessThanOrEqual(narrow.size.width, 100)
    }

    func testIndexAtPointClampsAboveAndBelowTheRun() {
        let run = run("alpha\nbeta")
        XCTAssertEqual(run.index(at: CGPoint(x: 0, y: -50)), 0)
        XCTAssertEqual(run.index(at: CGPoint(x: 10_000, y: 10_000)), run.length)
    }

    // MARK: - A measured block reports the width it was measured into

    /// The invariant everything else rests on: `size.width` is the measure, not
    /// the ink. Break it and "is this tree valid at the current width" stops
    /// being answerable.
    func testBlockReportsTheWidthItWasMeasuredInto() {
        XCTAssertEqual(paragraph("hi").measure(400).size.width, 400)
        XCTAssertEqual(BlockStack([paragraph("hi")]).measure(400).size.width, 400)
    }

    // MARK: - Who owns the space between two blocks

    /// A paragraph claims nothing: its box is its glyphs, and what separates two
    /// of them is the stack's `spacing` alone.
    func testParagraphClaimsNoSpaceOfItsOwn() {
        let line = run("alpha").size.height
        XCTAssertEqual(paragraph("alpha").measure(400).size.height, line, accuracy: 0.5)

        let stack = BlockStack([paragraph("alpha"), paragraph("beta")], spacing: 12).measure(400)
        XCTAssertEqual(stack.size.height, line * 2 + 12, accuracy: 0.5)
    }

    /// A block wanting more than the base puts it inside its own height, and the
    /// stack is told nothing. A heading is the case this exists for — and it can
    /// only ever add, which is why nothing sits *closer* than `spacing`.
    func testHeadingAddsItsExtraRoomInsideItsOwnHeight() {
        let title = MarkdownText("Title", attributes: [.font: Heading.font(level: 1)])
        let bare = title.run(width: 400).size.height
        let heading = Heading(level: 1, text: title).measure(400)

        XCTAssertEqual(heading.size.height, bare + 18, accuracy: 0.5)
        // The glyphs moved down by the extra, and selection moved with them.
        XCTAssertEqual(try XCTUnwrap(heading.rects(from: 0, to: 5).first).minY, 18, accuracy: 0.5)
    }

    /// Every gap inside a list is the list's own, at any depth — between items,
    /// and between the blocks of one item.
    func testListUsesOneRhythmAtEveryDepth() throws {
        let block = MarkdownLayout.make(
            """
            - one
            - two
              - two a
            """
        ).measure(400)

        let tops = try (0..<block.length)
            .compactMap { block.rects(from: $0, to: $0 + 1).first?.minY }
            .reduce(into: [CGFloat]()) { seen, y in
                if seen.last.map({ abs($0 - y) > 0.5 }) ?? true { seen.append(y) }
            }
        XCTAssertEqual(tops.count, 3)

        let gaps = zip(tops, tops.dropFirst()).map { $1 - $0 }
        XCTAssertEqual(try XCTUnwrap(gaps.first), try XCTUnwrap(gaps.last), accuracy: 0.5)
    }

    // MARK: - Across blocks

    /// The load-bearing case: a drag that starts inside one paragraph and ends
    /// inside another. The stack has to hand each end a partial range and stitch
    /// the text back together — neither paragraph knows the other exists.
    func testSelectionSpanningTwoParagraphs() {
        let stack = BlockStack([paragraph("alpha"), paragraph("beta")]).measure(400)

        XCTAssertEqual(stack.length, 9)  // "alpha" + "beta"

        // From "al|pha" through "be|ta".
        XCTAssertEqual(stack.text(from: 2, to: 7), "pha\nbe")
        XCTAssertEqual(stack.rects(from: 2, to: 7).count, 2)
    }

    func testSelectionWithinOneChildStaysInThatChild() {
        let stack = BlockStack([paragraph("alpha"), paragraph("beta")]).measure(400)
        XCTAssertEqual(stack.text(from: 1, to: 4), "lph")
        XCTAssertEqual(stack.rects(from: 1, to: 4).count, 1)
    }

    /// A second child's rectangles come back offset by where the stack put it,
    /// not in the child's own coordinates.
    func testChildRectsAreOffsetIntoStackCoordinates() {
        let first = paragraph("alpha")
        let stack = BlockStack([first, paragraph("beta")], spacing: 7).measure(400)

        let secondOnly = stack.rects(from: 5, to: 9)
        XCTAssertEqual(secondOnly.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(secondOnly.first).minY,
            first.measure(400).size.height + 7,
            accuracy: 0.5)
    }

    // MARK: - Blocks that hold no text

    /// A rule is drawn but occupies no index, so a selection running through it
    /// picks up its neighbours and nothing else — no stray position, no blank
    /// line in the copied text.
    func testOpaqueBlockOccupiesNoIndexSpace() {
        XCTAssertEqual(ThematicBreak().measure(400).length, 0)

        let stack = BlockStack([paragraph("alpha"), ThematicBreak(), paragraph("beta")])
            .measure(400)
        XCTAssertEqual(stack.length, 9)
        XCTAssertEqual(stack.text(from: 0, to: 9), "alpha\nbeta")
    }

    /// A list marker is furniture: drawn, never selected. Dragging across a list
    /// copies the items and none of the bullets.
    func testListMarkersAreOutsideTheIndexSpace() {
        let block = list([
            (.ordinal(9), paragraph("alpha")),
            (.task(checked: true), paragraph("beta")),
        ]).measure(400)

        XCTAssertEqual(block.length, 9)
        XCTAssertEqual(block.text(from: 0, to: 9), "alpha\nbeta")
    }

    /// The one thing a stack cannot do, done by the type that needs it: both
    /// items' content starts at the same x, past a marker column wide enough for
    /// the wider of the two markers.
    func testListNegotiatesOneMarkerColumnForAllItems() throws {
        let block = list([
            (.ordinal(9), paragraph("alpha")),
            (.ordinal(10), paragraph("beta")),
        ]).measure(400)

        let first = try XCTUnwrap(block.rects(from: 0, to: 5).first)
        let second = try XCTUnwrap(block.rects(from: 5, to: 9).first)
        XCTAssertEqual(first.minX, second.minX, accuracy: 0.5)
        XCTAssertGreaterThan(first.minX, 0)
    }

    // MARK: - Nesting

    /// A stack inside a decorator inside a stack. Indices compose because each
    /// level adds its own child's base, and rectangles compose because each level
    /// adds its own offset — the same two lines at every depth.
    func testNestedLayoutComposesIndicesAndOrigins() throws {
        var quote = Blockquote(BlockStack([paragraph("beta"), paragraph("gamma")]))
        quote.indent = 20

        let outer = BlockStack([paragraph("alpha"), quote]).measure(400)

        XCTAssertEqual(outer.length, 5 + 4 + 5)

        // Reaching into the quoted stack's second paragraph through both levels.
        XCTAssertEqual(outer.text(from: 9, to: 14), "gamma")

        let rects = outer.rects(from: 9, to: 14)
        XCTAssertEqual(rects.count, 1)
        // 20 from the quote's indent; the stack inside adds none of its own.
        XCTAssertEqual(try XCTUnwrap(rects.first).minX, 20, accuracy: 0.5)
    }

    /// A decorator subtracts its indent from the width it was handed, and the
    /// inner number never escapes — so the content is narrower by exactly the
    /// indent, and nobody outside had to compute that.
    func testDecoratorNarrowsItsContentByItsOwnIndent() throws {
        var quote = Blockquote(BlockStack([paragraph("beta")]))
        quote.indent = 20

        let block = quote.measure(400)
        XCTAssertEqual(block.size.width, 400)
        XCTAssertEqual(try XCTUnwrap(block as? Blockquote.Measured).content.size.width, 380)
    }

    /// Hit-testing walks the same tree back the other way: a point lands in a
    /// child, the child answers locally, the stack adds its base.
    func testHitTestRoundTripsThroughNesting() {
        let alpha = paragraph("alpha")
        let outer = BlockStack([alpha, BlockStack([paragraph("beta")])]).measure(400)

        // Far below everything clamps to the last child's end.
        XCTAssertEqual(outer.index(at: CGPoint(x: 10_000, y: 10_000)), outer.length)
        // Above everything clamps to the start.
        XCTAssertEqual(outer.index(at: CGPoint(x: -10, y: -10)), 0)
        // Inside the second child, at its left edge.
        XCTAssertEqual(
            outer.index(at: CGPoint(x: 0, y: alpha.measure(400).size.height + 1)), 5)
    }
}

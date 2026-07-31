import AppKit
import XCTest

@testable import TranscriptKit

/// Selection across a tree of blocks — the claim that a container needs no
/// selection code of its own beyond splitting endpoints and offsetting what
/// comes back.
///
/// No window, no mount. That is worth stating rather than assuming: the rest of
/// this suite has to mount because `NSTableView` only asks its data source
/// anything when it lays out, whereas a block tree is a value that answers the
/// same way whether or not it is on screen. If a test here ever needs a mount,
/// something has leaked out of the value layer.
final class BlockStackSelectionTests: XCTestCase {

    // MARK: - Fixture

    /// Monospaced so that character offsets and x-coordinates relate
    /// predictably, and one attribute set for every paragraph so a difference
    /// in the assertions is a difference in the tree, not in the styling.
    private func paragraph(_ text: String, width: CGFloat = 400) -> Paragraph {
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        return .make(attributed, width: width)
    }

    // MARK: - One block

    func testRunTypesetsOneLinePerHardBreak() {
        let run = paragraph("alpha\nbeta").run
        XCTAssertEqual(run.lines.count, 2)
        XCTAssertEqual(run.length, "alpha\nbeta".utf16.count)
    }

    func testWrappingProducesMoreLinesThanTheSourceHas() {
        let long = String(repeating: "word ", count: 60)
        let narrow = paragraph(long, width: 100).run
        XCTAssertGreaterThan(narrow.lines.count, 1)
        XCTAssertLessThanOrEqual(narrow.size.width, 100)
    }

    func testIndexAtPointClampsAboveAndBelowTheRun() {
        let run = paragraph("alpha\nbeta").run
        XCTAssertEqual(run.index(at: CGPoint(x: 0, y: -50)), 0)
        XCTAssertEqual(run.index(at: CGPoint(x: 10_000, y: 10_000)), run.length)
    }

    // MARK: - Across blocks

    /// The load-bearing case: a drag that starts inside one paragraph and ends
    /// inside another. The stack has to hand each end a partial range, and
    /// stitch the text back together — neither paragraph knows the other
    /// exists.
    func testSelectionSpanningTwoParagraphs() {
        let first = paragraph("alpha")
        let second = paragraph("beta")
        let stack = BlockStack.make([first, second], width: 400)

        XCTAssertEqual(stack.length, 9)  // "alpha" + "beta"

        // From "al|pha" through "be|ta".
        XCTAssertEqual(stack.text(from: 2, to: 7), "pha\nbe")
        XCTAssertEqual(stack.rects(from: 2, to: 7).count, 2)
    }

    func testSelectionWithinOneChildStaysInThatChild() {
        let stack = BlockStack.make([paragraph("alpha"), paragraph("beta")], width: 400)
        XCTAssertEqual(stack.text(from: 1, to: 4), "lph")
        XCTAssertEqual(stack.rects(from: 1, to: 4).count, 1)
    }

    /// A second child's rectangles come back offset by where the stack put it,
    /// not in the child's own coordinates.
    func testChildRectsAreOffsetIntoStackCoordinates() {
        let first = paragraph("alpha")
        let stack = BlockStack.make([first, paragraph("beta")], width: 400, spacing: 7)

        let secondOnly = stack.rects(from: 5, to: 9)
        XCTAssertEqual(secondOnly.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(secondOnly.first).minY, first.size.height + 7, accuracy: 0.5)
    }

    // MARK: - Blocks that hold no text

    /// A rule is drawn but occupies no index, so a selection running through it
    /// picks up its neighbours and nothing else — no stray position, no blank
    /// line in the copied text.
    func testOpaqueBlockOccupiesNoIndexSpace() {
        let rule = ThematicBreak.make(width: 400)
        XCTAssertEqual(rule.length, 0)

        let stack = BlockStack.make([paragraph("alpha"), rule, paragraph("beta")], width: 400)
        XCTAssertEqual(stack.length, 9)
        XCTAssertEqual(stack.text(from: 0, to: 9), "alpha\nbeta")
    }

    // MARK: - Nesting

    /// A stack inside a stack. Indices compose because each level adds its own
    /// child's base, and rectangles compose because each level adds its own
    /// child's origin — the same two lines at every depth.
    func testNestedStackComposesIndicesAndOrigins() {
        let inner = BlockStack.make([paragraph("beta"), paragraph("gamma")], width: 380)
        let outer = BlockStack.make(
            [paragraph("alpha"), inner],
            width: 400,
            inset: NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0))

        XCTAssertEqual(outer.length, 5 + 4 + 5)

        // Reaching into the inner stack's second paragraph through both levels.
        XCTAssertEqual(outer.text(from: 9, to: 14), "gamma")

        let rects = outer.rects(from: 9, to: 14)
        XCTAssertEqual(rects.count, 1)
        // 20 from the outer inset; the inner stack adds none of its own.
        XCTAssertEqual(try XCTUnwrap(rects.first).minX, 20, accuracy: 0.5)
    }

    /// Hit-testing walks the same tree back the other way: a point lands in a
    /// child, the child answers locally, the stack adds its base.
    func testHitTestRoundTripsThroughNesting() {
        let alpha = paragraph("alpha")
        let inner = BlockStack.make([paragraph("beta")], width: 400)
        let outer = BlockStack.make([alpha, inner], width: 400)

        // Far below everything clamps to the last child's end.
        XCTAssertEqual(outer.index(at: CGPoint(x: 10_000, y: 10_000)), outer.length)
        // Above everything clamps to the start.
        XCTAssertEqual(outer.index(at: CGPoint(x: -10, y: -10)), 0)
        // Inside the second child, at its left edge.
        XCTAssertEqual(outer.index(at: CGPoint(x: 0, y: alpha.size.height + 1)), 5)
    }
}

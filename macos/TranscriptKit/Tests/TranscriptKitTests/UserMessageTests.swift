import AppKit
import XCTest

@testable import TranscriptKit

/// The bubble's geometry: where it sits, how wide it gets, and where the text
/// lands inside it.
///
/// No window, no mount — a measured block is a value and answers the same way
/// on screen or off. The mounted half of this case, which is about whether the
/// transcript reaches for one of these at all, is `UserMessageRowTests`.
final class UserMessageTests: XCTestCase {

    // MARK: - Fixture

    /// Monospaced so that "how wide should this have come out" is a multiple of
    /// one advance rather than something only the font knows.
    private func message(_ text: String) -> UserMessage {
        UserMessage(
            ShapedText(
                text,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
    }

    private let width: CGFloat = 600

    /// What `maxWidthFraction` resolves to at the fixture width.
    private let cap: CGFloat = 450

    // MARK: - Width

    /// The whole reason the bubble reads as one side of a conversation: a short
    /// message is a short bubble, not a full-width band with three words in it.
    func testAShortMessageHugsItsText() throws {
        let measured = try XCTUnwrap(message("Hi.").measure(width) as? UserMessage.Measured)

        // Against the measured text's own ink, which is what hugging means — and
        // the padding is on both sides of it.
        XCTAssertEqual(
            measured.bubble.width, measured.text.size.width + 32, accuracy: 0.5)
        XCTAssertLessThan(measured.bubble.width, cap)
    }

    /// The row is the full column whatever the bubble came out at —
    /// `MeasuredBlock`'s invariant, and what makes the gutter part of the row
    /// rather than something the transcript has to add around it.
    func testTheRowStaysTheFullWidth() {
        XCTAssertEqual(message("Hi.").measure(width).size.width, width)
    }

    func testTheBubbleIsFlushWithTheRightEdge() throws {
        let measured = try XCTUnwrap(message("Hi.").measure(width) as? UserMessage.Measured)
        XCTAssertEqual(measured.bubble.maxX, width, accuracy: 0.5)
    }

    /// Past three quarters of the column the bubble stops widening and the text
    /// wraps instead, leaving the last quarter as gutter at every window size.
    ///
    /// It keeps hugging *at* the cap, which is why the assertion is not
    /// `width == cap`: the lines are broken against three quarters of the column,
    /// and the bubble then hugs the widest one — a word's advance short of what it
    /// was broken against, since the word that would have filled the rest is what
    /// forced the wrap. A bubble padded out to the cap would have empty space on
    /// its right that no line reaches.
    func testALongMessageStopsAtThreeQuartersOfTheColumn() throws {
        let measured = try XCTUnwrap(
            message(String(repeating: "word ", count: 60)).measure(width)
                as? UserMessage.Measured)

        XCTAssertEqual(measured.text.typesetWidth, cap - 32, accuracy: 0.5)
        XCTAssertLessThanOrEqual(measured.bubble.width, cap)
        XCTAssertEqual(measured.bubble.width, measured.text.size.width + 32, accuracy: 0.5)
        XCTAssertEqual(measured.bubble.maxX, width, accuracy: 0.5)
        XCTAssertGreaterThan(measured.text.lines.count, 1)
    }

    // MARK: - Text inside it

    func testTheTextSitsInsideTheBubblesPadding() throws {
        let measured = try XCTUnwrap(message("Hi.").measure(width) as? UserMessage.Measured)

        XCTAssertEqual(measured.textOrigin.x - measured.bubble.minX, 16, accuracy: 0.5)
        XCTAssertEqual(measured.textOrigin.y - measured.bubble.minY, 14, accuracy: 0.5)
        XCTAssertEqual(
            measured.size.height, measured.text.size.height + 28, accuracy: 0.5)
    }

    /// The inherited selection surface, threaded through `textOrigin`: every
    /// highlight a full selection produces is inside the bubble it belongs to.
    /// Miss the offset and the band draws in the gutter, several hundred points
    /// to the left of the words.
    func testSelectionRectsLandInsideTheBubble() throws {
        let measured = try XCTUnwrap(
            message("A message long enough to wrap onto a second line at this width.")
                .measure(width) as? UserMessage.Measured)

        let rects = measured.rects(from: 0, to: measured.length)
        XCTAssertFalse(rects.isEmpty)
        for rect in rects {
            XCTAssertTrue(
                measured.bubble.insetBy(dx: -0.5, dy: -0.5).contains(rect),
                "\(rect) is outside the bubble \(measured.bubble)")
        }
    }

    /// The gutter is empty space, not part of the message — so the pointing
    /// question declines there, which is what keeps a click to the left of a
    /// bubble from behaving as a click on its first character.
    func testTheGutterIsOnNoCharacter() throws {
        let measured = try XCTUnwrap(message("Hi.").measure(width) as? UserMessage.Measured)
        XCTAssertNil(measured.characterIndex(at: CGPoint(x: 10, y: measured.size.height / 2)))
    }

    // MARK: - Cut short
    //
    // The cut is a fact about a width, so every one of these measures rather than
    // counting characters: the same string is short in a wide column.

    /// One line per repetition at this width and font, so a line count is
    /// something a test can ask for directly.
    private func lines(_ count: Int) -> UserMessage {
        message((1...count).map { "line \($0)" }.joined(separator: "\n"))
    }

    private func measure(_ message: UserMessage) throws -> UserMessage.Measured {
        try XCTUnwrap(message.measure(width) as? UserMessage.Measured)
    }

    func testAMessageInsideTheLimitIsShownWhole() throws {
        let measured = try measure(lines(12))
        XCTAssertEqual(measured.text.lines.count, 12)
        XCTAssertFalse(measured.text.isTruncated)
        XCTAssertNil(measured.more)
    }

    /// The second half of the rule: a message a little over the limit is shown
    /// whole rather than cut, because a `More` that reveals two lines is worse
    /// than the two lines.
    func testAMessageOnlyJustOverTheLimitIsStillShownWhole() throws {
        let measured = try measure(lines(15))
        XCTAssertEqual(measured.text.lines.count, 15)
        XCTAssertNil(measured.more)
    }

    func testALongMessageIsCutToTheLimitAndOffersMore() throws {
        let measured = try measure(lines(40))
        XCTAssertEqual(measured.text.lines.count, 12)
        XCTAssertTrue(measured.text.isTruncated)
        XCTAssertNotNil(measured.more)
    }

    /// The affordance is under the message, inside the bubble, and the bubble
    /// grew to hold it.
    func testTheMoreRunSitsUnderTheMessageInsideTheBubble() throws {
        let measured = try measure(lines(40))
        let more = try XCTUnwrap(measured.more)

        XCTAssertEqual(more.origin.x, measured.textOrigin.x, accuracy: 0.5)
        XCTAssertGreaterThan(more.origin.y, measured.textOrigin.y + measured.text.size.height)
        XCTAssertTrue(measured.bubble.insetBy(dx: -0.5, dy: -0.5).contains(more.frame))
    }

    /// The cut text is what a copy takes — including the part that is off screen,
    /// which is `ShapedText.typeset(width:limit:)`'s documented trade — and the
    /// word "More" is not in it. The affordance holds a position, not characters.
    func testCopyingACutMessageTakesTheMessageAndNotTheAffordance() throws {
        let measured = try measure(lines(40))
        let copied = measured.text(from: 0, to: measured.length)

        XCTAssertTrue(copied.hasPrefix("line 1\n"))
        XCTAssertTrue(copied.hasSuffix("line 40"))
        XCTAssertFalse(copied.contains("More"))
        XCTAssertFalse(copied.contains(String(InlineSymbol.placeholder)))
    }

    // MARK: - The affordance is a link
    //
    // Not "looks like one": `link(at:)` answers for it, which is the whole of how
    // `BlockView` finds a link — so the band, the pointing hand and the
    // press-is-a-click rule are the ones already written rather than a second
    // copy of them.

    private func onTheMore(_ measured: UserMessage.Measured) throws -> CGPoint {
        let more = try XCTUnwrap(measured.more)
        // Left of centre: the run starts with a glyph, and the label after it is
        // what a pointer would most likely land on.
        return CGPoint(x: more.frame.midX, y: more.frame.midY)
    }

    func testTheMoreRunAnswersAsALinkWithNoAddress() throws {
        let measured = try measure(lines(40))
        let link = try XCTUnwrap(measured.link(at: try onTheMore(measured)))

        XCTAssertEqual(link.destination, .more)
        XCTAssertNil(link.url, "there is nowhere to go; the host decides what a press does")
    }

    func testThereIsNoLinkOnTheMessageItself() throws {
        let measured = try measure(lines(40))
        let firstLine = try XCTUnwrap(measured.rects(from: 0, to: 4).first)
        XCTAssertNil(measured.link(at: CGPoint(x: firstLine.midX, y: firstLine.midY)))
    }

    /// The gap beside the run is not the run — the same declining that keeps a
    /// click to the right of a link from opening it.
    func testThereIsNoLinkBesideTheMoreRun() throws {
        let measured = try measure(lines(40))
        let more = try XCTUnwrap(measured.more)
        XCTAssertNil(measured.link(at: CGPoint(x: more.frame.maxX + 30, y: more.frame.midY)))
    }

    /// What the hover band is drawn from: `BlockView` asks for the rectangles
    /// over the link's range and knows nothing else about it, so a range that
    /// produced none would hover invisibly.
    func testTheMoreRunHasARectangleToDrawABandOver() throws {
        let measured = try measure(lines(40))
        let link = try XCTUnwrap(measured.link(at: try onTheMore(measured)))
        let more = try XCTUnwrap(measured.more)

        let rects = measured.rects(from: link.range.lowerBound, to: link.range.upperBound)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects.first, more.frame)
    }

    /// One position, and only one: the message's own index space is untouched, so
    /// a selection inside the text means what it meant before the cut.
    func testTheAffordanceTakesExactlyOnePosition() throws {
        let cut = try measure(lines(40))
        let whole = try measure(lines(12))

        XCTAssertEqual(cut.length, cut.text.length + 1)
        XCTAssertEqual(whole.length, whole.text.length)
    }

    // MARK: - Paint

    /// Two strokes, and the order between them is a phase rather than an
    /// emission: the fill is `.background`, so a selection band lands over it and
    /// under the glyphs without either knowing the other exists.
    func testPaintsTheFillBehindTheGlyphs() throws {
        let measured = try XCTUnwrap(message("Hi.").measure(width) as? UserMessage.Measured)

        var items: [PaintItem] = []
        measured.paint(
            at: CGPoint(x: 100, y: 50),
            dirty: CGRect(x: 0, y: 0, width: 1000, height: 1000), into: &items)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].phase, .background)
        XCTAssertEqual(items[1].phase, .content)

        guard case .fillPath(let path, _) = items[0].primitive else {
            return XCTFail("expected the bubble's fill first, got \(items[0].primitive)")
        }
        let expected = measured.bubble.offsetBy(dx: 100, dy: 50)
        XCTAssertEqual(path.boundingBox.minX, expected.minX, accuracy: 0.5)
        XCTAssertEqual(path.boundingBox.minY, expected.minY, accuracy: 0.5)
        XCTAssertEqual(path.boundingBox.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(path.boundingBox.height, expected.height, accuracy: 0.5)

        guard case .text(_, let origin) = items[1].primitive else {
            return XCTFail("expected the glyphs second, got \(items[1].primitive)")
        }
        XCTAssertEqual(origin.x, measured.textOrigin.x + 100, accuracy: 0.5)
        XCTAssertEqual(origin.y, measured.textOrigin.y + 50, accuracy: 0.5)
    }
}

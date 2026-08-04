import AppKit
import XCTest

@testable import TranscriptKit

/// The glyph in front of a link, and the one standing in for an image.
///
/// A symbol is the one thing in a line that is not a glyph, so what these guard
/// is the seam: it has to claim room while the line is broken, land on the
/// baseline once it is, take exactly one position in the index space, and then
/// stay out of the pasteboard. Four properties, four places they can go wrong
/// independently.
final class InlineSymbolTests: XCTestCase {

    private func measured(_ source: String, width: CGFloat = 400) throws -> MeasuredBlock {
        MarkdownBlockBuilder.make(source).measure(width)
    }

    /// The document's first paragraph, measured — the level the symbol lives at.
    private func paragraph(_ source: String, width: CGFloat = 400) throws -> Paragraph.Measured {
        let stack = try XCTUnwrap(try measured(source, width: width) as? BlockStack.Measured)
        return try XCTUnwrap(stack.children.first?.block as? Paragraph.Measured)
    }

    /// How far right the block's ink reaches. `size.width` is always the width it
    /// was measured into, so it cannot answer this.
    private func inkWidth(_ source: String, width: CGFloat = 400) throws -> CGFloat {
        try measured(source, width: width).fullRects().map(\.maxX).max() ?? 0
    }

    // MARK: - It claims room

    /// The run delegate's whole job. Without it the placeholder would lay out as
    /// a zero-width character and the glyph would sit on top of the first word.
    func testLinkGlyphClaimsRoomInTheLine() throws {
        XCTAssertGreaterThan(
            try inkWidth("[word](https://x.com)"), try inkWidth("word") + 4)
    }

    func testTwoLinksClaimTwiceTheRoom() throws {
        let one = try inkWidth("[a](https://x.com)")
        let two = try inkWidth("[a](https://x.com)[a](https://x.com)")
        // Two of everything, so the difference between them is one link's worth.
        XCTAssertEqual(two - one, one, accuracy: 1)
    }

    // MARK: - The proportions are the symbol's own
    //
    // `Design` writes down two numbers per symbol so that measuring never builds
    // an `NSImage`. These are the check that the numbers are still the ones the
    // artwork publishes — the only place in the package that opens the image.

    func testRecordedProportionsMatchTheArtwork() throws {
        for design in [InlineSymbol.Design.link, .image, .more] {
            let image = try XCTUnwrap(
                NSImage(systemSymbolName: design.name, accessibilityDescription: nil),
                "\(design.name) is not a symbol on this system")
            XCTAssertEqual(image.size, design.canvas, "\(design.name) canvas")
            XCTAssertEqual(image.alignmentRect, design.alignment, "\(design.name) alignment")
        }
    }

    /// The claim the whole placement rests on: a symbol's alignment box is the
    /// cap height of text set at the same size. Apple's, not ours.
    func testAlignmentBoxTracksTheFontsCapHeight() throws {
        for size in [12.0, 14.0, 20.0] as [CGFloat] {
            let font = NSFont.systemFont(ofSize: size)
            let image = try XCTUnwrap(
                NSImage(systemSymbolName: "link", accessibilityDescription: nil)?
                    .withSymbolConfiguration(
                        NSImage.SymbolConfiguration(pointSize: size, weight: .regular)))
            XCTAssertEqual(image.alignmentRect.height, font.capHeight, accuracy: size * 0.02)
        }
    }

    // MARK: - It lands on the baseline

    /// An em tall, centred on the capital band.
    ///
    /// Both halves are the whole design. The size comes from scaling the symbol's
    /// alignment box to the x-height, which is what puts the artwork at about
    /// `1em` — GitHub's number for an inline icon. The position does *not* come
    /// from the alignment box: seating it on the baseline is right only at the
    /// size Apple drew the symbol for, and shrinking around that anchor drops the
    /// artwork's mass about a point below where the eye wants it. Measured
    /// against Apple's own inline rendering, which centres on 4.88pt above the
    /// baseline at 14pt against capitals whose centre is 4.93.
    func testGlyphIsAnEmTallAndCentredOnTheCapitals() throws {
        let font = MarkdownStyle.default.bodyFont
        let symbol = InlineSymbol(.link, font: font, color: .linkColor)

        XCTAssertEqual(
            symbol.box.height * (symbol.design.alignment.height / symbol.design.canvas.height),
            font.xHeight, accuracy: 0.01)
        XCTAssertEqual(symbol.box.height, font.pointSize, accuracy: font.pointSize * 0.1)

        let paragraph = try paragraph("[word](https://x.com)")
        let placement = try XCTUnwrap(paragraph.text.symbols.first)
        let line = try XCTUnwrap(paragraph.text.lines.first)

        XCTAssertEqual(paragraph.text.symbols.count, 1)
        XCTAssertEqual(placement.rect.minX, 0, accuracy: 0.5)
        XCTAssertEqual(
            placement.rect.midY, line.baseline - font.capHeight / 2, accuracy: 0.01,
            "the box's centre is the capital band's centre")
    }

    /// A symbol is a property of the text, not of the line that caught it — so a
    /// link pushed onto a second line is placed against that line's baseline.
    func testGlyphOnAWrappedLineFollowsThatLinesBaseline() throws {
        let source = String(repeating: "word ", count: 30) + "[link](https://x.com)"
        let paragraph = try paragraph(source, width: 200)
        let placement = try XCTUnwrap(paragraph.text.symbols.first)
        let symbol = InlineSymbol(.link, font: MarkdownStyle.default.bodyFont, color: .linkColor)

        XCTAssertGreaterThan(paragraph.text.lines.count, 1)
        let owning = try XCTUnwrap(
            paragraph.text.lines.first {
                abs(symbol.frame(pen: 0, baseline: $0.baseline).midY - placement.rect.midY) < 0.5
            })
        XCTAssertEqual(
            placement.rect.midY, owning.baseline - symbol.capHeight / 2, accuracy: 0.01)
    }

    /// The run delegate reports the surrounding font's own ascent and descent, so
    /// a line holding a symbol is exactly as tall as the same line without one —
    /// and a line holding *only* a symbol is still a line of text tall.
    func testGlyphDoesNotChangeTheLineHeight() throws {
        let withGlyph = try paragraph("[word](https://x.com)")
        let without = try paragraph("word")
        XCTAssertEqual(
            withGlyph.text.size.height, without.text.size.height, accuracy: 0.01)

        let glyphAlone = try paragraph("![](pic.png)")
        XCTAssertEqual(glyphAlone.text.size.height, without.text.size.height, accuracy: 0.01)
    }

    /// The advance is the ink, not the canvas. The artwork carries padding on
    /// both sides; charging the line for it would open a gap in front of every
    /// link that the reader would see as a stray space.
    func testTheAdvanceIsTheInkRatherThanTheCanvas() {
        let symbol = InlineSymbol(.link, font: MarkdownStyle.default.bodyFont, color: .linkColor)
        XCTAssertLessThan(symbol.inkWidth, symbol.box.width)
        XCTAssertEqual(symbol.leadingInset, 0, "nothing sits before the pen")
    }

    // MARK: - It takes one position, and no more

    func testGlyphOccupiesExactlyOneIndex() throws {
        XCTAssertEqual(try measured("word").length, 4)
        XCTAssertEqual(try measured("[word](https://x.com)").length, 5)
    }

    // MARK: - It stays out of the pasteboard

    func testCopyingALinkLeavesTheGlyphBehind() throws {
        let block = try measured("[word](https://x.com)")
        XCTAssertEqual(block.text(from: 0, to: block.length), "word")
    }

    func testCopyingAcrossProseAndALinkReadsAsWritten() throws {
        let block = try measured("see [docs](https://x.com) now")
        XCTAssertEqual(block.text(from: 0, to: block.length), "see docs now")
    }

    // MARK: - Images

    func testImagePrefersAltOverTitle() throws {
        let block = try measured(#"![alt](pic.png "T")"#)
        XCTAssertEqual(block.text(from: 0, to: block.length), "alt")
    }

    func testImageFallsBackToItsTitle() throws {
        let block = try measured(#"![](pic.png "T")"#)
        XCTAssertEqual(block.text(from: 0, to: block.length), "T")
    }

    /// Neither, which is common in generated output — the glyph carries it alone,
    /// and the paragraph is still something rather than nothing.
    func testImageWithNeitherIsJustTheGlyph() throws {
        let block = try measured("![](pic.png)")
        XCTAssertEqual(block.text(from: 0, to: block.length), "")
        XCTAssertGreaterThan(try inkWidth("![](pic.png)"), 4)
    }
}

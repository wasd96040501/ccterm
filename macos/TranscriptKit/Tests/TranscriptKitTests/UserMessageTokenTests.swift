import AppKit
import XCTest

@testable import TranscriptKit

/// A bubble with tokens (design/transcript/05-local.md): the wash behind a
/// command's name, the padding that makes room for it, the picture token's
/// link, and a pending bubble's half strength. Values only — a measured block
/// answers the same on screen or off.
final class UserMessageTokenTests: XCTestCase {

    private let width: CGFloat = 600

    private func measured(_ message: TranscriptRowContent.UserMessage) throws -> UserMessageBlock.Measured {
        try XCTUnwrap(UserMessageBlock(message).measure(width) as? UserMessageBlock.Measured)
    }

    private func command(
        _ text: String = "/model opus", length: Int = 6, tip: String? = nil
    )
        -> TranscriptRowContent.UserMessage
    {
        .init(text, tokens: [.init(range: 0..<length, kind: .command, toolTip: tip)])
    }

    // MARK: - The wash

    func testACommandTokenHasOneWashBehindItsName() throws {
        let measured = try measured(command())
        XCTAssertEqual(measured.washes.count, 1)
        let wash = try XCTUnwrap(measured.washes.first)
        XCTAssertEqual(wash.height, UserMessageBlock.washHeight, accuracy: 0.01)
        XCTAssertTrue(measured.bubble.contains(wash), "the inset stays inside the bubble")
        XCTAssertEqual(wash.minX, measured.textOrigin.x, accuracy: 0.5, "the wash starts where the text does")
    }

    /// The token's words are one pad in from the wash's edge on each side.
    func testTheWashPadsTheWordsByFourPointsEitherSide() throws {
        let measured = try measured(command("/model", length: 6))
        let wash = try XCTUnwrap(measured.washes.first)
        let glyphs = UserMessageBlock.tokenFont.maximumAdvancement.width  // an upper bound for one glyph
        XCTAssertGreaterThan(wash.width, 8)
        XCTAssertLessThan(wash.width, 8 + glyphs * 6 + 1)
        // The first glyph's ink begins one pad in.
        let first = try XCTUnwrap(measured.text.rects(from: 1, to: 2).first)
        XCTAssertEqual(first.minX, 4, accuracy: 0.5)
    }

    /// A token is a patch of the line, not a taller line.
    func testATokenDoesNotChangeTheLineHeight() throws {
        let plain = try measured(.init("/model opus"))
        let tokened = try measured(command())
        XCTAssertEqual(tokened.size.height, plain.size.height, accuracy: 0.01)
    }

    func testTheSigilIsSecondaryAndTheNameIsLabel() throws {
        let measured = try measured(command())
        let attributed = measured.text.attributed
        // 0 is the leading pad; the sigil is next, then the name.
        let sigil = attributed.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        let name = attributed.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
        XCTAssertEqual(sigil, .secondaryLabelColor)
        XCTAssertEqual(name, .labelColor)
        let font = attributed.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 13)
        XCTAssertTrue(font?.isFixedPitch ?? false)
    }

    func testTheArgumentsAreOrdinaryText() throws {
        let measured = try measured(command("/model opus"))
        let attributed = measured.text.attributed
        let last = attributed.length - 1
        let font = attributed.attribute(.font, at: last, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 14)
        XCTAssertFalse(font?.isFixedPitch ?? true)
    }

    /// The pads and the glyph are positions, not words: a copy is what was sent.
    func testCopyingATokenedMessageCopiesItsWordsOnly() throws {
        let measured = try measured(command("/model opus"))
        XCTAssertEqual(measured.text(from: 0, to: measured.length), "/model opus")
    }

    func testATokenThatReachesOutsideTheTextIsIgnored() throws {
        let measured = try measured(.init("hi", tokens: [.init(range: 0..<9, kind: .command)]))
        XCTAssertTrue(measured.washes.isEmpty)
        XCTAssertEqual(measured.text(from: 0, to: measured.length), "hi")
    }

    func testOverlappingTokensKeepTheFirst() throws {
        let message = TranscriptRowContent.UserMessage(
            "/model opus", tokens: [.init(range: 0..<6, kind: .command), .init(range: 3..<9, kind: .command)])
        XCTAssertEqual(try measured(message).washes.count, 1)
    }

    // MARK: - Links

    func testAPictureTokenIsALinkWithItsGlyphBeforeItsWords() throws {
        let url = URL(string: "ccterm-image:1")!
        let message = TranscriptRowContent.UserMessage(
            "Image 1 shows it", tokens: [.init(range: 0..<7, kind: .image(url))])
        let measured = try measured(message)
        XCTAssertEqual(measured.text.symbols.count, 1, "the photo glyph")
        // The link covers the glyph and the words, not the pads.
        let link = try XCTUnwrap(measured.link(at: 3))
        XCTAssertEqual(link.url, url)
        XCTAssertNil(measured.link(at: 0))
        XCTAssertEqual(measured.text(from: 0, to: measured.length), "Image 1 shows it")
    }

    /// A picture's token is words (`.imgtok`): the 13-pt body face, medium, on
    /// an 18-pt wash with 5 pt either side; a command's is code on 15.
    func testAPictureTokenIsSetAsWordsOnATallerWash() throws {
        let url = URL(string: "ccterm-image:1")!
        let measured = try measured(.init("Image 1", tokens: [.init(range: 0..<7, kind: .image(url))]))
        let wash = try XCTUnwrap(measured.washes.first)
        XCTAssertEqual(wash.height, UserMessageBlock.pictureWashHeight, accuracy: 0.01)
        XCTAssertEqual(UserMessageBlock.pictureWashHeight, 18)
        let attributed = measured.text.attributed
        let font = try XCTUnwrap(attributed.attribute(.font, at: attributed.length - 2, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(font.isFixedPitch)
        XCTAssertEqual(font.pointSize, 13)
        let first = try XCTUnwrap(measured.text.rects(from: 1, to: 2).first)
        XCTAssertEqual(first.minX, 5, accuracy: 0.5, "the glyph begins one 5-pt pad in")
        let glyph = try XCTUnwrap(measured.text.symbols.first)
        XCTAssertEqual(glyph.symbol.inkWidth, UserMessageBlock.pictureGlyphWidth, accuracy: 0.01)
        XCTAssertEqual(
            glyph.symbol.advance, UserMessageBlock.pictureGlyphWidth + 3, accuracy: 0.01, "3 pt before the words")
    }

    func testAPointOverATokenFindsItsLink() throws {
        let url = URL(string: "ccterm-image:1")!
        let measured = try measured(.init("Image 1", tokens: [.init(range: 0..<7, kind: .image(url))]))
        let wash = try XCTUnwrap(measured.washes.first)
        XCTAssertEqual(measured.link(at: CGPoint(x: wash.midX, y: wash.midY))?.url, url)
    }

    // MARK: - Tool tips

    func testATokenWithAToolTipReportsItsRect() throws {
        let full = "/skill-creator:skill-creator"
        let measured = try measured(command("/skill-creator", length: 14, tip: full))
        XCTAssertEqual(measured.toolTips.map(\.text), [full])
        XCTAssertEqual(measured.toolTips.first?.rect, measured.washes.first)
    }

    func testATokenWithoutOneReportsNone() throws {
        XCTAssertTrue(try measured(command()).toolTips.isEmpty)
    }

    // MARK: - Pending

    func testAPendingBubbleIsAtHalfStrength() throws {
        let full = try measured(command())
        let pending = try measured(.init("/model opus", tokens: command().tokens, isPending: true))
        func alpha(_ color: NSColor) -> CGFloat {
            var value: CGFloat = 0
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                value = color.usingColorSpace(.sRGB)?.alphaComponent ?? -1
            }
            return value
        }
        XCTAssertEqual(alpha(pending.backgroundColor), alpha(full.backgroundColor) / 2, accuracy: 0.01)
        XCTAssertEqual(alpha(pending.tokenColor), alpha(full.tokenColor) / 2, accuracy: 0.01)
        let text = pending.text.attributed.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
        XCTAssertEqual(alpha(try XCTUnwrap(text)), alpha(.labelColor) / 2, accuracy: 0.01)
    }

    func testAPendingBubbleKeepsItsGeometry() throws {
        let full = try measured(command())
        let pending = try measured(.init("/model opus", tokens: command().tokens, isPending: true))
        XCTAssertEqual(pending.bubble, full.bubble)
        XCTAssertEqual(pending.washes, full.washes)
    }

    // MARK: - Shell commands

    func testAShellCommandIsSetInMono() throws {
        let message = TranscriptRowContent.UserMessage(
            "!git status --short", tokens: [.init(range: 0..<1, kind: .command)], isMonospaced: true)
        let measured = try measured(message)
        let attributed = measured.text.attributed
        let font = attributed.attribute(.font, at: attributed.length - 1, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 12.5)
        XCTAssertTrue(font?.isFixedPitch ?? false)
    }

    /// `! git status`: the space after the `!` token is the bubble's body face,
    /// as the sheet sets it, not a wider mono space.
    func testTheSpaceAfterAShellTokenIsTheBodyFace() throws {
        let message = TranscriptRowContent.UserMessage(
            "! git status", tokens: [.init(range: 0..<1, kind: .command)], isMonospaced: true)
        let attributed = try measured(message).text.attributed
        let space = (attributed.string as NSString).range(of: " ").location
        let font = try XCTUnwrap(attributed.attribute(.font, at: space, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(font.isFixedPitch)
        XCTAssertEqual((attributed.string as NSString).substring(from: space + 1), "git status")
    }

    // MARK: - Truncation

    /// A glyph past the cut would be drawn on the ellipsis: past it every
    /// position reports the same pen.
    func testAPictureGlyphInTheHiddenTailIsNotDrawn() throws {
        let url = URL(string: "ccterm-image:1")!
        let head = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let text = head + "\nImage 1"
        let start = (head as NSString).length + 1
        let measured = try measured(.init(text, tokens: [.init(range: start..<(start + 7), kind: .image(url))]))
        XCTAssertTrue(measured.text.isTruncated)
        XCTAssertTrue(measured.text.symbols.isEmpty)
        XCTAssertTrue(measured.washes.isEmpty)
    }

    // MARK: - Equality

    func testTheRowCacheSeesATokenChange() {
        let a = TranscriptRowContent.userMessage(command())
        let b = TranscriptRowContent.userMessage(.init("/model opus"))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.source, b.source)
    }
}

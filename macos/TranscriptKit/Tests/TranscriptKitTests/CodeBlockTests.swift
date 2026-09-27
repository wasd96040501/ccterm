import AppKit
import CoreText
import XCTest

@testable import TranscriptKit

/// The two things a code card has to get right that nothing else checks: the
/// language chip never sits on code, and the card is visible on the page.
///
/// Both were wrong for a long time without any test noticing — a long first line
/// ran under the chip, and a card chosen against one window colour met another
/// and nearly vanished — because both are facts about *where* things land and
/// *what* they land on, and every other test here asks about text.
final class CodeBlockTests: XCTestCase {

    private static let width: CGFloat = 400
    /// One token with nowhere to break, so the first line is filled to the edge —
    /// wherever the chip is — rather than stopping at a word that happens to fit.
    private static let longLine = String(repeating: "0123456789abcdef", count: 16)

    private func card(_ source: String) throws -> CodeBlock.Measured {
        let measured = MarkdownBlockBuilder.make(source).measure(Self.width)
        let stack = try XCTUnwrap(measured as? BlockStack.Measured)
        return try XCTUnwrap(stack.children.first?.block as? CodeBlock.Measured)
    }

    /// Where a line's ink ends, in the card's coordinates. Trailing whitespace is
    /// not ink: the newline that ends each line of code reaches nothing.
    private func inkEnd(of line: TypesetText.Line, in card: CodeBlock.Measured) -> CGFloat {
        let advance = CGFloat(CTLineGetTypographicBounds(line.ctLine, nil, nil, nil))
        return card.textOrigin.x + line.origin.x + advance
            - CGFloat(CTLineGetTrailingWhitespaceWidth(line.ctLine))
    }

    private func box(of line: TypesetText.Line, in card: CodeBlock.Measured) -> CGRect {
        CGRect(
            x: card.textOrigin.x + line.origin.x, y: card.textOrigin.y + line.origin.y,
            width: .greatestFiniteMagnitude, height: line.ascent + line.descent + line.leading)
    }

    // MARK: - The chip

    func testALongFirstLineWrapsShortOfTheChip() throws {
        let labelled = try card("```swift\n\(Self.longLine)\n```")
        let bare = try card("```\n\(Self.longLine)\n```")
        let chip = try XCTUnwrap(labelled.badge, "premise: the card has a chip").rect

        let first = try XCTUnwrap(bare.text.lines.first)
        XCTAssertGreaterThan(
            inkEnd(of: first, in: bare), chip.minX,
            "premise: without the chip, the first line would run under it")

        let beside = labelled.text.lines.filter { box(of: $0, in: labelled).intersects(chip) }
        XCTAssertFalse(beside.isEmpty, "premise: some line sits beside the chip")
        for line in beside {
            XCTAssertLessThanOrEqual(
                inkEnd(of: line, in: labelled), chip.minX, "code runs under the chip")
        }
        XCTAssertEqual(
            labelled.text.lines.last.map { NSMaxRange($0.range) }, labelled.text.attributed.length,
            "the wrap lost text")
    }

    /// The chip costs nothing where there is nothing to move: a first line that
    /// stops short of it is broken exactly as it is without it.
    func testAShortFirstLineIsLaidOutAsIfThereWereNoChip() throws {
        let source = "let a = 1\n\(Self.longLine)\n"
        let labelled = try card("```swift\n\(source)```")
        let bare = try card("```\n\(source)```")

        XCTAssertNotNil(labelled.badge, "premise: the card has a chip")
        XCTAssertEqual(labelled.size, bare.size)
        XCTAssertEqual(labelled.text.lines.map(\.range), bare.text.lines.map(\.range))
    }

    // MARK: - The fill

    /// On every page it might be put on, the card is a visible step from the page
    /// and the chip a visible step from the card — darker on a light page,
    /// lighter on a dark one. The pages are the windows it has actually met
    /// (`#F1F2F2` is macOS 26's), plus plain white and the classic grey.
    func testTheCardAndChipStandOffAnyPageInBothAppearances() {
        let block = CodeBlock(text: .empty)
        let cases: [(NSAppearance.Name, pages: [CGFloat], darker: Bool)] = [
            (.aqua, pages: [0xFF, 0xF1, 0xEC], darker: true),
            (.darkAqua, pages: [0x1E, 0x28, 0x32], darker: false),
        ]
        for (name, pages, darker) in cases {
            let appearance = NSAppearance(named: name)!
            for page in pages.map({ $0 / 255 }) {
                let card = composite(block.backgroundColor, over: page, in: appearance)
                let chip = composite(block.badgeBackgroundColor, over: card, in: appearance)
                for (step, what) in [(card - page, "card on the page"), (chip - card, "chip on the card")] {
                    XCTAssertGreaterThanOrEqual(
                        darker ? -step : step, 8 / 255,
                        "\(what) in \(name.rawValue) on \(Int(page * 255)): step \(step * 255)")
                }
            }
        }
    }

    /// `color` resolved under `appearance` and composited over a grey `page`,
    /// as a grey level. The fills are black or white at some alpha, so one
    /// channel says it all.
    private func composite(
        _ color: NSColor, over page: CGFloat, in appearance: NSAppearance
    )
        -> CGFloat
    {
        var resolved = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? .clear
        }
        return page * (1 - resolved.alphaComponent) + resolved.greenComponent * resolved.alphaComponent
    }
}

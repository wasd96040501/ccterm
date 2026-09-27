import AppKit
import XCTest

@testable import TranscriptKit

/// The two rules the whole paint model rests on: **phase decides depth, emission
/// order decides ties**.
///
/// Asserted on pixels rather than on the list, because the claim is about what
/// ends up on screen. Reading back the list would only restate what the test
/// itself put in.
final class PaintItemTests: XCTestCase {

    // MARK: - Harness

    /// Plays `items` into a 4×4 bitmap and reads the middle pixel — i.e. "what
    /// won". Everything painted covers the whole square, so the answer is
    /// whichever stroke landed last.
    private func topmostColor(of items: [PaintItem]) throws -> NSColor {
        let side = 4
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        // Every phase, because the question here is what wins across the whole
        // order — slicing it is a surface's business, not the order's.
        items.paint(
            in: graphics.cgContext,
            dirty: CGRect(x: 0, y: 0, width: side, height: side),
            phases: PaintItem.Phase.all)
        NSGraphicsContext.restoreGraphicsState()

        return try XCTUnwrap(rep.colorAt(x: side / 2, y: side / 2))
    }

    private func assertColor(
        _ actual: NSColor, is expected: NSColor, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let a = try XCTUnwrap(actual.usingColorSpace(.deviceRGB))
        let b = try XCTUnwrap(expected.usingColorSpace(.deviceRGB))
        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.02, message, file: file, line: line)
        XCTAssertEqual(
            a.greenComponent, b.greenComponent, accuracy: 0.02, message, file: file, line: line)
        XCTAssertEqual(
            a.blueComponent, b.blueComponent, accuracy: 0.02, message, file: file, line: line)
    }

    private let square = CGRect(x: 0, y: 0, width: 4, height: 4)

    // MARK: - Phase beats emission order

    /// The property the selection band depends on: something emitted *first* but
    /// tagged `.content` still lands above something emitted later and tagged
    /// `.background`. Break this and a code card's fill covers the highlight —
    /// which is exactly the bug the phases exist to make unrepresentable.
    func testPhaseDecidesDepthRegardlessOfEmissionOrder() throws {
        let painted = try topmostColor(of: [
            .fill(square, .red, phase: .content),
            .fill(square, .blue, phase: .background),
        ])
        try assertColor(painted, is: .red, "content must land above background")
    }

    /// The four tiers in order, each emitted in reverse, so a single assertion
    /// covers every adjacent pair at once.
    func testTheFourPhasesStackInDeclarationOrder() throws {
        let reversed: [PaintItem] = [
            .fill(square, .yellow, phase: .overlay),
            .fill(square, .red, phase: .content),
            .fill(square, .green, phase: .decoration),
            .fill(square, .blue, phase: .background),
        ]
        try assertColor(topmostColor(of: reversed), is: .yellow)

        // And with the top tier withheld, the next one down wins — so the order
        // is a chain, not one special case.
        try assertColor(topmostColor(of: Array(reversed.dropFirst())), is: .red)
        try assertColor(topmostColor(of: Array(reversed.dropFirst(2))), is: .green)
    }

    // MARK: - Emission order breaks ties

    /// Within one phase the list is played in the order it was built. A table
    /// leans on this: its row tints and its dividers are both `.background`, and
    /// the dividers have to land on top. This is why the player buckets instead
    /// of sorting — `sort` is not documented as stable.
    func testEmissionOrderDecidesWithinAPhase() throws {
        try assertColor(
            topmostColor(of: [
                .fill(square, .red, phase: .background),
                .fill(square, .blue, phase: .background),
            ]), is: .blue)

        try assertColor(
            topmostColor(of: [
                .fill(square, .blue, phase: .background),
                .fill(square, .red, phase: .background),
            ]), is: .red)
    }

    // MARK: - Every primitive reaches the context

    func testEachPrimitivePaints() throws {
        let path = CGPath(rect: square, transform: nil)

        try assertColor(topmostColor(of: [.fill(square, .red)]), is: .red)
        try assertColor(topmostColor(of: [.fill(path, .green)]), is: .green)
        try assertColor(
            topmostColor(of: [.fill(roundedRect: square, radius: 0, .blue)]), is: .blue)

        // A stroke wide enough to cover the square it outlines, so the middle
        // pixel reports it.
        try assertColor(
            topmostColor(of: [.stroke(path, width: 8, .yellow, phase: .background)]),
            is: .yellow)
        try assertColor(
            topmostColor(of: [
                .stroke(roundedRect: square, radius: 0, width: 8, .red, phase: .background)
            ]), is: .red)
    }

    /// A run reaches the context too — asserted as "something was drawn" rather
    /// than as a colour, since glyph coverage at a given pixel is Core Text's
    /// business and not a stable thing to pin.
    func testARunPaints() throws {
        let text = ShapedText(
            "████",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 24, weight: .regular),
                .foregroundColor: NSColor.red,
            ]
        ).typeset(width: 200)

        let painted = try topmostColor(of: [.text(text, at: CGPoint(x: -2, y: -6))])
        XCTAssertGreaterThan(painted.alphaComponent, 0.1, "the text put nothing on the canvas")
    }

    // MARK: - Nothing paints immediately

    /// The property that keeps depth decidable: a block hands back *items*, and
    /// the caller chooses when and in what order they reach a context. Nothing
    /// touches `ctx` during `paint` — if anything did, that stroke would land
    /// wherever the walk happened to be, which is the shape this replaced.
    func testPaintingTouchesNoContext() {
        let block = MarkdownBlockBuilder.make("A paragraph, `code`, and a rule.\n\n---\n")
            .measure(200)

        var list: [PaintItem] = []
        block.paint(
            at: .zero, dirty: CGRect(x: 0, y: 0, width: 200, height: 400), into: &list)

        // No context was ever passed in — there is nowhere for a stray stroke to
        // have gone — and the walk still produced something to play.
        XCTAssertFalse(list.isEmpty)
    }

    // MARK: - Cutting the order

    /// `slices(cutAt:)` is what a row's composited surfaces are built from, and
    /// the only thing standing between the paint model and three silent failures:
    /// a gap (content nothing draws), an overlap (content drawn twice), and a pair
    /// in the wrong order (the model inverted for those phases).
    ///
    /// Small enough to check **exhaustively** rather than by example — four phases
    /// is sixteen possible cut sets, so this asserts the partition holds for every
    /// input the function has, not for the ones someone thought to write down.
    func testEveryCutProducesAPartitionOfTheOrder() {
        let all = PaintItem.Phase.allCases

        for mask in 0..<(1 << all.count) {
            let cuts = Set(all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            let slices = PaintItem.Phase.slices(cutAt: cuts)

            // Flattened, the slices are exactly the order — which is one assertion
            // for all three failures at once: a gap or an overlap changes the
            // contents, and a swapped pair changes the sequence.
            let covered = slices.flatMap { slice in all.filter { slice.contains($0) } }
            XCTAssertEqual(covered, all, "cuts \(cuts.map(\.rawValue).sorted()) do not partition")

            XCTAssertFalse(
                slices.contains { $0.lowerBound > $0.upperBound },
                "cuts \(cuts.map(\.rawValue).sorted()) produced an inverted slice")
        }
    }

    /// A cut where nothing is above or below it is not a cut. Callers ask for the
    /// phase they mean without first checking whether it divides anything, so the
    /// degenerate answers have to be the sensible ones rather than empty slices.
    func testACutAtTheEdgeDividesNothing() {
        XCTAssertEqual(PaintItem.Phase.slices(cutAt: []), [PaintItem.Phase.all])
        XCTAssertEqual(PaintItem.Phase.slices(cutAt: [.background]), [PaintItem.Phase.all])
        XCTAssertEqual(
            PaintItem.Phase.slices(cutAt: [.overlay]),
            [.background ... .content, .overlay ... .overlay])
    }
}

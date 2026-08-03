import AppKit
import XCTest

@testable import TranscriptKit

/// Dragging, copying, and letting go — driven through the responder methods
/// AppKit would call, because those are the surface, and asserted on what comes
/// back out of the pasteboard and off the canvas.
///
/// A window, because `makeFirstResponder` needs one. It is never made key, so
/// the selection renders in the unemphasised colour; no test here asserts a
/// colour, only that something changed.
@MainActor
final class BlockViewSelectionTests: XCTestCase {

    // MARK: - Harness

    private struct Mounted {
        let window: NSWindow
        let cell: BlockView
        let block: MeasuredBlock
    }

    private func mount(_ source: String, width: CGFloat = 400) -> Mounted {
        NSApplication.shared.setActivationPolicy(.prohibited)

        let block = MarkdownBlockBuilder.make(source).measure(width)
        let size = CGSize(width: width, height: block.size.height)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.alphaValue = 0.01

        let cell = BlockView()
        cell.frame = NSRect(origin: .zero, size: size)
        window.contentView?.addSubview(cell)
        cell.configure(with: block)
        window.orderFront(nil)

        return Mounted(window: window, cell: cell, block: block)
    }

    /// One press and one drag, in the cell's own (flipped) coordinates.
    private func drag(_ mounted: Mounted, from: CGPoint, to: CGPoint) {
        mounted.cell.mouseDown(with: event(mounted, at: from, .leftMouseDown))
        mounted.cell.mouseDragged(with: event(mounted, at: to, .leftMouseDragged))
    }

    private func event(
        _ mounted: Mounted, at point: CGPoint, _ type: NSEvent.EventType, clicks: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: mounted.cell.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: mounted.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func click(_ mounted: Mounted, at point: CGPoint, times: Int) {
        mounted.cell.mouseDown(with: event(mounted, at: point, .leftMouseDown, clicks: times))
    }

    /// Far outside the block on either side, at a given height — every block
    /// clamps a stray point to its nearest position, so this selects a whole line
    /// without the test having to know where any glyph sits.
    private func sweep(_ mounted: Mounted, atY y: CGFloat) {
        drag(mounted, from: CGPoint(x: -500, y: y), to: CGPoint(x: 5_000, y: y))
    }

    private func copiedText(_ mounted: Mounted) -> String? {
        NSPasteboard.general.clearContents()
        mounted.cell.copy(nil)
        return NSPasteboard.general.string(forType: .string)
    }

    private func canCopy(_ mounted: Mounted) -> Bool {
        mounted.cell.validateMenuItem(
            NSMenuItem(
                title: "Copy", action: #selector(BlockView.copy(_:)), keyEquivalent: "c"))
    }

    /// Renders the cell as it stands.
    ///
    /// `draw(_:)` directly rather than `cacheDisplay(in:to:)`: the cell is
    /// layer-backed with `.onSetNeedsDisplay`, so the caching path hands back
    /// whatever the layer already holds — for a view that has never been on
    /// screen, nothing at all.
    private func render(_ mounted: Mounted) throws -> NSBitmapImageRep {
        let cell = mounted.cell
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(cell.bounds.width), pixelsHigh: Int(cell.bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        // Flipped, to match the coordinates the cell draws in.
        graphics.cgContext.translateBy(x: 0, y: cell.bounds.height)
        graphics.cgContext.scaleBy(x: 1, y: -1)
        cell.draw(cell.bounds)
        NSGraphicsContext.restoreGraphicsState()

        return rep
    }

    /// How many pixels inside `rect` differ between two renders.
    ///
    /// A count over a region rather than one sampled point: a glyph covers the
    /// band it sits on, so any single pixel might be unchanged for a reason that
    /// has nothing to do with what is being asserted.
    private func changedPixels(
        _ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect
    )
        -> Int
    {
        var changed = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                if abs(p.redComponent - q.redComponent) > 0.01
                    || abs(p.greenComponent - q.greenComponent) > 0.01
                    || abs(p.blueComponent - q.blueComponent) > 0.01
                {
                    changed += 1
                }
            }
        }
        return changed
    }

    /// How many pixels in `rect` are dark enough to be glyph ink rather than any
    /// surface behind it — the card, the highlight, or the window.
    private func inkPixels(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
        var ink = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let luminance =
                    0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                if luminance < 0.5 { ink += 1 }
            }
        }
        return ink
    }

    // MARK: - Dragging

    func testADragSelectsTheTextItCrossed() throws {
        let mounted = mount("alpha beta gamma")
        sweep(mounted, atY: 4)

        XCTAssertEqual(copiedText(mounted), "alpha beta gamma")
    }

    func testACopyWithNothingSelectedIsUnavailable() {
        let mounted = mount("alpha beta gamma")
        XCTAssertFalse(canCopy(mounted))

        sweep(mounted, atY: 4)
        XCTAssertTrue(canCopy(mounted))
    }

    /// A click with no drag is a caret, not a selection.
    func testAClickWithoutADragSelectsNothing() {
        let mounted = mount("alpha beta gamma")
        mounted.cell.mouseDown(with: event(mounted, at: CGPoint(x: 20, y: 4), .leftMouseDown))

        XCTAssertFalse(canCopy(mounted))
    }

    // MARK: - Double and triple click

    /// Boundaries come from `NSAttributedString.doubleClick(at:)`, so a word is
    /// whatever `NSTextView` would call one — the point of asking AppKit rather
    /// than splitting on spaces.
    func testDoubleClickTakesTheWordUnderIt() throws {
        let mounted = mount("alpha beta gamma")
        let line = try XCTUnwrap(mounted.block.rects(from: 0, to: mounted.block.length).first)

        // Inside "beta": a third of the way along a line of three equal words.
        click(mounted, at: CGPoint(x: line.minX + line.width / 2, y: line.midY), times: 2)
        XCTAssertEqual(copiedText(mounted), "beta")
    }

    /// Verbatim text: a triple-click takes one logical line, because the
    /// separator inside a code card is a real newline.
    ///
    /// The newline comes with it. That is `paragraphRange(for:)`'s definition and
    /// `NSTextView`'s behaviour — its highlight runs past the last glyph to the
    /// end of the line — and it is what makes two triple-clicked lines paste as
    /// two lines rather than run together.
    func testTripleClickInACodeCardTakesOneLine() throws {
        let mounted = mount("```\nalpha\nbeta\ngamma\n```")
        let lines = mounted.block.rects(from: 0, to: mounted.block.length)
        XCTAssertEqual(lines.count, 3)

        click(mounted, at: CGPoint(x: lines[1].midX, y: lines[1].midY), times: 3)
        XCTAssertEqual(copiedText(mounted), "beta\n")
    }

    /// Prose: a hard break does not end a paragraph, so a triple-click runs
    /// straight through it. This is the reason the boundary comes from
    /// `paragraphRange(for:)` and not `lineRange(for:)` — a hard break is U+2028,
    /// which the latter treats as the end of a line and the former does not.
    func testTripleClickCrossesAHardBreak() throws {
        let mounted = mount("alpha\\\nbeta")
        let first = try XCTUnwrap(mounted.block.rects(from: 0, to: mounted.block.length).first)

        click(mounted, at: CGPoint(x: first.midX, y: first.midY), times: 3)
        let copied = try XCTUnwrap(copiedText(mounted))
        XCTAssertTrue(copied.contains("alpha"), copied)
        XCTAssertTrue(copied.contains("beta"), copied)
    }

    /// And in a grid, a triple-click takes the cell — the structure a reader is
    /// pointing at once they have stopped pointing at glyphs.
    func testTripleClickInATableTakesTheWholeCell() throws {
        let mounted = mount(
            """
            | a | b |
            |---|---|
            | one two | d |
            """)
        let bands = mounted.block.fullRects()
        XCTAssertEqual(bands.count, 4)

        click(mounted, at: CGPoint(x: bands[2].midX, y: bands[2].midY), times: 3)
        XCTAssertEqual(copiedText(mounted), "one two")
    }

    // MARK: - Letting go

    /// How a selection in one row disappears when the reader starts one in
    /// another: the cell drops its own on losing focus. Nothing coordinates it,
    /// and nothing here knows a second row exists.
    func testLosingFirstResponderClearsTheSelection() {
        let mounted = mount("alpha beta gamma")
        sweep(mounted, atY: 4)
        XCTAssertTrue(canCopy(mounted))

        _ = mounted.cell.resignFirstResponder()
        XCTAssertFalse(canCopy(mounted))
    }

    /// The recycling rule: a pooled cell handed a different document must arrive
    /// as empty as a fresh one, or a stale pair of indices would point into text
    /// that is no longer there.
    func testRebindingClearsTheSelection() {
        let mounted = mount("alpha beta gamma")
        sweep(mounted, atY: 4)
        XCTAssertTrue(canCopy(mounted))

        mounted.cell.configure(with: MarkdownBlockBuilder.make("something else").measure(400))
        XCTAssertFalse(canCopy(mounted))
    }

    // MARK: - What it looks like

    /// The case the whole paint model exists for. A code card fills an opaque
    /// rounded rect behind its text; before, a band drawn by this view landed
    /// under that fill and was never seen. Now the band is `.decoration` and the
    /// card is `.background`, so it lands between the card and the glyphs — and
    /// the card has no idea.
    func testTheBandIsVisibleInsideACodeCard() throws {
        let mounted = mount("```swift\nlet x = 1\n```")

        let before = try render(mounted)
        sweep(mounted, atY: 20)
        let after = try render(mounted)

        let band = try XCTUnwrap(mounted.block.rects(from: 0, to: mounted.block.length).first)
        XCTAssertTrue(canCopy(mounted), "the sweep selected nothing, so this proves nothing")

        // Most of the band is bare card between glyphs, so most of it should have
        // changed. A handful of changed pixels would mean an antialiasing shift,
        // not a highlight.
        let changed = changedPixels(before, after, in: band)
        XCTAssertGreaterThan(
            changed, Int(band.width * band.height) / 2,
            "the selection band never reached the canvas inside the card")
    }

    /// The other half of the claim, and the half that pins the phase down: the
    /// band goes **under** the glyphs. Painted over them the text would vanish,
    /// so the ink inside the band has to survive the highlight.
    ///
    /// This is what makes `.decoration` a choice rather than a label. Above
    /// `.background` is free — the cell appends after the whole walk, so within
    /// any one tier its band already lands last. Below `.content` is not: tag the
    /// band `.content` or `.overlay` and the glyphs disappear under it.
    func testTheGlyphsStayOnTopOfTheBand() throws {
        let mounted = mount("```swift\nlet x = 1\n```")

        let before = try render(mounted)
        sweep(mounted, atY: 20)
        let after = try render(mounted)

        let band = try XCTUnwrap(mounted.block.rects(from: 0, to: mounted.block.length).first)
        let inkBefore = inkPixels(before, in: band)
        let inkAfter = inkPixels(after, in: band)

        XCTAssertGreaterThan(inkBefore, 20, "no glyphs in the band to begin with")
        XCTAssertGreaterThan(
            inkAfter, inkBefore * 3 / 4, "the band was painted over the text, not under it")
    }

    /// And nothing outside the band moves.
    func testTheBandLeavesEverythingOutsideItAlone() throws {
        let mounted = mount("```swift\nlet x = 1\n```")

        let before = try render(mounted)
        sweep(mounted, atY: 20)
        let after = try render(mounted)

        let band = try XCTUnwrap(mounted.block.rects(from: 0, to: mounted.block.length).first)
        let belowTheBand = CGRect(
            x: band.minX, y: band.maxY + 1,
            width: band.width, height: mounted.block.size.height - band.maxY - 2)

        XCTAssertEqual(changedPixels(before, after, in: belowTheBand), 0)
    }

    // MARK: - Two dimensions

    /// End to end for the shape that motivated the endpoint pair: the cell knows
    /// only two indices, the table decides what lies between them, and what comes
    /// out is a rectangle rather than everything in reading order.
    func testDraggingDownATableColumnCopiesThatColumn() throws {
        let mounted = mount(
            """
            | a | b |
            |---|---|
            | c | d |
            | e | f |
            """)

        // Cell bands, row-major, from the table itself — so the drag is aimed at
        // real geometry rather than at numbers guessed here.
        let bands = mounted.block.fullRects()
        XCTAssertEqual(bands.count, 6)
        drag(
            mounted,
            from: CGPoint(x: bands[1].midX, y: bands[1].midY),
            to: CGPoint(x: bands[5].midX, y: bands[5].midY))

        XCTAssertEqual(copiedText(mounted), "b\nd\nf")
    }
}

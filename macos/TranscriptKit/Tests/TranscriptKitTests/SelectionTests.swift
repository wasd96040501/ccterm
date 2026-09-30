import AppKit
import ExactList
import XCTest

@testable import TranscriptKit

/// Selecting text — in one row and across several — driven through the
/// responder methods AppKit would call, and asserted on what comes back out of
/// the pasteboard, what each row is handed to draw, and what reaches the canvas.
///
/// Mounted in a real transcript, because the selection is the transcript's: a
/// row's view only reports the press and draws its part. The window is never made
/// key, so the selection renders in the unemphasised colour; no test here asserts
/// a colour, only that something changed.
@MainActor
final class SelectionTests: XCTestCase {

    private var mounted: MountedTranscript!

    /// Held by the test, because the transcript holds its data source weakly.
    private var host: SelectionHost!

    override func tearDown() {
        mounted?.teardown()
        mounted = nil
        host = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func mount(_ rows: [String], width: CGFloat = 400, height: CGFloat = 400) {
        host = SelectionHost(rows: rows)
        mounted = MountedTranscript(size: NSSize(width: width, height: height))
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.settle()
        mounted.transcript.reloadData()
        // A transcript loads at its tail; these tests read from the top.
        mounted.transcript.scrollToRow(at: 0, scrollPosition: .top)
        mounted.settle()
    }

    /// The view on screen serving `row`, and the tree it is drawing.
    private func cell(_ row: Int) throws -> (view: BlockView, block: MeasuredBlock) {
        let view = try XCTUnwrap(
            mounted.transcript.descendants(ofType: BlockView.self)
                .first { mounted.transcript.row(for: $0) == row },
            "row \(row) has no view on screen")
        return (view, try XCTUnwrap(view.block))
    }

    /// A mouse event at `point` in `view`'s own (flipped) coordinates.
    private func event(
        _ type: NSEvent.EventType, at point: CGPoint, in view: NSView, clicks: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: mounted.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// A press on `from` in `pressed`, dragged to `to` in `over`, then released.
    private func drag(
        _ pressed: NSView, from: CGPoint, to: CGPoint, over: NSView? = nil
    ) {
        mounted.press(
            pressed, with: event(.leftMouseDown, at: from, in: pressed),
            then: [event(.leftMouseDragged, at: to, in: over ?? pressed)])
    }

    /// Far outside the row on either side, at a given height — every block clamps
    /// a stray point to its nearest position, so this selects a whole line without
    /// the test having to know where any glyph sits.
    private func sweep(_ view: BlockView, atY y: CGFloat) {
        drag(view, from: CGPoint(x: -500, y: y), to: CGPoint(x: 5_000, y: y))
    }

    private func click(_ view: BlockView, at point: CGPoint, times: Int) {
        mounted.press(view, with: event(.leftMouseDown, at: point, in: view, clicks: times))
    }

    /// The row as the window server composited it — see `WindowCapture.bitmap(of:)`.
    /// One pixel per point with the rep's top-left at the view's, so the block's
    /// rectangles index it directly.
    private func render(_ view: BlockView) async throws -> NSBitmapImageRep {
        try await WindowCapture.bitmap(of: view)
    }

    /// The row before anything is done to it, to compare a later render against.
    ///
    /// Captured twice, keeping the second: the first capture of a freshly mounted
    /// transcript is not its settled composite. Measured, two captures with
    /// nothing done between them differed in four thousand pixels spread across
    /// the whole row — against which no count of what a selection changed means
    /// anything. It showed only when a test ran first in its process, which is
    /// why the suite as a whole stayed green through it.
    private func renderUntouched(_ view: BlockView) async throws -> NSBitmapImageRep {
        _ = try await render(view)
        return try await render(view)
    }

    /// How many pixels inside `rect` differ between two renders.
    ///
    /// A count over a region rather than one sampled point: a glyph covers the
    /// band it sits on, so any single pixel might be unchanged for a reason that
    /// has nothing to do with what is being asserted.
    private func changedPixels(
        _ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect
    ) -> Int {
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

    // MARK: - Dragging in one row

    func testADragSelectsTheTextItCrossed() throws {
        mount(["alpha beta gamma"])
        sweep(try cell(0).view, atY: 4)

        XCTAssertEqual(mounted.copy(), "alpha beta gamma")
    }

    func testACopyWithNothingSelectedIsUnavailable() throws {
        mount(["alpha beta gamma"])
        XCTAssertFalse(mounted.canCopy)

        sweep(try cell(0).view, atY: 4)
        XCTAssertTrue(mounted.canCopy)
    }

    /// A click with no drag is a caret, not a selection.
    func testAClickWithoutADragSelectsNothing() throws {
        mount(["alpha beta gamma"])
        click(try cell(0).view, at: CGPoint(x: 20, y: 4), times: 1)

        XCTAssertFalse(mounted.canCopy)
    }

    // MARK: - Double and triple click

    /// Boundaries come from `NSAttributedString.doubleClick(at:)`, so a word is
    /// whatever `NSTextView` would call one — the point of asking AppKit rather
    /// than splitting on spaces.
    func testDoubleClickTakesTheWordUnderIt() throws {
        mount(["alpha beta gamma"])
        let (view, block) = try cell(0)
        let line = try XCTUnwrap(block.fullRects().first)

        // Inside "beta": a third of the way along a line of three equal words.
        click(view, at: CGPoint(x: line.minX + line.width / 2, y: line.midY), times: 2)
        XCTAssertEqual(mounted.copy(), "beta")
    }

    /// Verbatim text: a triple-click takes one logical line, because the
    /// separator inside a code card is a real newline.
    ///
    /// The newline comes with it. That is `paragraphRange(for:)`'s definition and
    /// `NSTextView`'s behaviour — its highlight runs past the last glyph to the
    /// end of the line — and it is what makes two triple-clicked lines paste as
    /// two lines rather than run together.
    func testTripleClickInACodeCardTakesOneLine() throws {
        mount(["```\nalpha\nbeta\ngamma\n```"])
        let (view, block) = try cell(0)
        let lines = block.fullRects()
        XCTAssertEqual(lines.count, 3)

        click(view, at: CGPoint(x: lines[1].midX, y: lines[1].midY), times: 3)
        XCTAssertEqual(mounted.copy(), "beta\n")
    }

    /// Prose: a hard break does not end a paragraph, so a triple-click runs
    /// straight through it. This is the reason the boundary comes from
    /// `paragraphRange(for:)` and not `lineRange(for:)` — a hard break is U+2028,
    /// which the latter treats as the end of a line and the former does not.
    func testTripleClickCrossesAHardBreak() throws {
        mount(["alpha\\\nbeta"])
        let (view, block) = try cell(0)
        let first = try XCTUnwrap(block.fullRects().first)

        click(view, at: CGPoint(x: first.midX, y: first.midY), times: 3)
        let copied = try XCTUnwrap(mounted.copy())
        XCTAssertTrue(copied.contains("alpha"), copied)
        XCTAssertTrue(copied.contains("beta"), copied)
    }

    /// And in a grid, a triple-click takes the cell — the structure a reader is
    /// pointing at once they have stopped pointing at glyphs.
    func testTripleClickInATableTakesTheWholeCell() throws {
        mount(
            [
                """
                | a | b |
                |---|---|
                | one two | d |
                """
            ])
        let (view, block) = try cell(0)
        let bands = block.fullRects()
        XCTAssertEqual(bands.count, 4)

        click(view, at: CGPoint(x: bands[2].midX, y: bands[2].midY), times: 3)
        XCTAssertEqual(mounted.copy(), "one two")
    }

    // MARK: - Clicking past the end of a line
    //
    // The blank to the right of a line's last glyph. Line ranges are gapless, so
    // the caret index there is the *next* line's first character — and a unit
    // looked up at it used to come back as the next line's word or paragraph.
    // Hence `wordRange` / `paragraphRange` taking the point rather than an index.
    //
    // The drag test at the bottom is the other half of the pair, and the reason
    // this could not be settled inside `characterIndexForInsertion(at:)`: the same boundary value that
    // is wrong for a unit lookup is exactly what a drag to that spot needs.

    /// Far right of the first visual line of a paragraph that wraps.
    private func pastTheEnd(of line: CGRect) -> CGPoint {
        CGPoint(x: line.maxX + 30, y: line.midY)
    }

    func testDoubleClickPastAWrappedLineTakesThatLinesLastWord() throws {
        mount(["alpha beta gamma delta epsilon zeta eta theta"], width: 110)
        let (view, block) = try cell(0)
        let lines = block.fullRects()
        XCTAssertGreaterThan(lines.count, 1, "the text did not wrap, so this proves nothing")

        click(view, at: pastTheEnd(of: lines[0]), times: 2)
        // Not "gamma", which is where the first line's end index points.
        XCTAssertEqual(mounted.copy(), "beta")
    }

    /// The trailing space of a wrapped line is inside its range, so stepping back
    /// by one lands on blank rather than on a word — which is why the fallback is
    /// the last *non-blank* character rather than the last one.
    func testDoubleClickPastACodeLineTakesThatLinesLastWord() throws {
        mount(["```\nalpha\nbeta\ngamma\n```"])
        let (view, block) = try cell(0)
        let lines = block.fullRects()

        click(view, at: pastTheEnd(of: lines[1]), times: 2)
        XCTAssertEqual(mounted.copy(), "beta")
    }

    func testTripleClickPastACodeLineTakesThatLine() throws {
        mount(["```\nalpha\nbeta\ngamma\n```"])
        let (view, block) = try cell(0)
        let lines = block.fullRects()

        click(view, at: pastTheEnd(of: lines[1]), times: 3)
        XCTAssertEqual(mounted.copy(), "beta\n")
    }

    /// The right half of a word's last glyph. The caret there has already moved
    /// past the word onto the space after it, so a unit looked up at the caret
    /// index takes the *space* — which is why the point is converted to the
    /// character it is on before anything is asked of it.
    ///
    /// `NSTextView` behaves the same way: double-clicking anywhere in a word,
    /// including hard against its trailing edge, takes the word.
    func testDoubleClickOnAWordsTrailingEdgeStillTakesTheWord() throws {
        mount(["alpha beta gamma"])
        let (view, block) = try cell(0)
        // "beta" is 6..<10; the range through 10 includes the space after it, so
        // the word's own box is the first of the two.
        let beta = try XCTUnwrap(block.rects(from: 6, to: 10).first)

        click(view, at: CGPoint(x: beta.maxX - 1, y: beta.midY), times: 2)
        XCTAssertEqual(mounted.copy(), "beta")
    }

    /// A click to the *left* of a line takes its first word — the other end of
    /// the same clamp, and the guard on the caret→character step-back going one
    /// too far.
    func testDoubleClickLeftOfALineTakesItsFirstWord() throws {
        mount(["```\nalpha\nbeta\ngamma\n```"])
        let (view, block) = try cell(0)
        let lines = block.fullRects()

        click(view, at: CGPoint(x: lines[1].minX - 40, y: lines[1].midY), times: 2)
        XCTAssertEqual(mounted.copy(), "beta")
    }

    /// The constraint that makes the fix a new pair of methods rather than a
    /// smaller `characterIndexForInsertion(at:)`: a drag ending past the right edge of a line still
    /// has to reach the end of it, newline included.
    func testDraggingPastTheEndOfALineStillReachesTheLineEnd() throws {
        mount(["```\nalpha\nbeta\ngamma\n```"])
        let (view, block) = try cell(0)
        let lines = block.fullRects()

        drag(
            view, from: CGPoint(x: lines[1].minX, y: lines[1].midY), to: pastTheEnd(of: lines[1]))
        XCTAssertEqual(mounted.copy(), "beta\n")
    }

    // MARK: - Across rows

    /// The feature itself: a drag that leaves the row it started in keeps
    /// selecting, and a copy takes every row it crossed — a blank line between
    /// two, the way two messages paste.
    func testADragAcrossRowsCopiesEveryRowItCrossed() throws {
        mount(["alpha one", "beta two", "gamma three"])
        let first = try cell(0).view
        let last = try cell(2).view

        drag(first, from: CGPoint(x: -500, y: 4), to: CGPoint(x: 5_000, y: 4), over: last)
        XCTAssertEqual(mounted.copy(), "alpha one\n\nbeta two\n\ngamma three")
    }

    /// Each end is a position inside its row, not the row's edge: the first row is
    /// taken from where the press was, the last up to where the pointer is.
    func testTheEndsOfACrossRowSelectionAreWhereThePressAndThePointerAre() throws {
        mount(["alpha one", "beta two", "gamma three"])
        let (first, firstBlock) = try cell(0)
        let (last, lastBlock) = try cell(2)
        // The leading edge of "one" (6) and of "three" (6).
        let from = try XCTUnwrap(firstBlock.rects(from: 6, to: 9).first)
        let to = try XCTUnwrap(lastBlock.rects(from: 6, to: 11).first)

        drag(
            first, from: CGPoint(x: from.minX, y: from.midY), to: CGPoint(x: to.minX, y: to.midY),
            over: last)
        XCTAssertEqual(mounted.copy(), "one\n\nbeta two\n\ngamma ")
    }

    /// A drag runs in either direction, and upwards selects the same text.
    func testDraggingUpwardsSelectsTheSameText() throws {
        mount(["alpha one", "beta two", "gamma three"])
        let first = try cell(0).view
        let last = try cell(2).view

        drag(last, from: CGPoint(x: 5_000, y: 4), to: CGPoint(x: -500, y: 4), over: first)
        XCTAssertEqual(mounted.copy(), "alpha one\n\nbeta two\n\ngamma three")
    }

    /// What each row is handed to draw: the first from the press to its end, the
    /// middle one whole, the last from its start to the pointer.
    func testEachRowIsHandedItsPartOfTheSelection() throws {
        mount(["alpha one", "beta two", "gamma three"])
        let (first, _) = try cell(0)
        let (middle, middleBlock) = try cell(1)
        let (last, _) = try cell(2)

        drag(first, from: CGPoint(x: 5_000, y: 4), to: CGPoint(x: -500, y: 4), over: last)

        XCTAssertNil(first.selectedRange, "a press past the end of the first row selects none of it")
        XCTAssertEqual(middle.selectedRange, 0..<middleBlock.length)
        XCTAssertNil(last.selectedRange, "a drag ending before the last row's text selects none of it")
    }

    /// Past the last row is the end of the last row, so a drag that leaves the
    /// rows behind still takes everything it passed.
    func testDraggingBelowTheLastRowSelectsToTheEnd() throws {
        mount(["alpha one", "beta two"])
        let first = try cell(0).view

        drag(first, from: CGPoint(x: -500, y: 4), to: CGPoint(x: 20, y: 5_000))
        XCTAssertEqual(mounted.copy(), "alpha one\n\nbeta two")
    }

    /// A new press anywhere replaces the selection, in every row it covered.
    func testANewPressClearsEveryRowOfTheOldSelection() throws {
        mount(["alpha one", "beta two", "gamma three"])
        let (first, _) = try cell(0)
        let (middle, _) = try cell(1)
        let (last, _) = try cell(2)
        drag(first, from: CGPoint(x: -500, y: 4), to: CGPoint(x: 5_000, y: 4), over: last)
        XCTAssertNotNil(first.selectedRange)

        click(middle, at: CGPoint(x: 10, y: 4), times: 1)

        XCTAssertEqual([first, middle, last].map(\.selectedRange), [nil, nil, nil])
        XCTAssertFalse(mounted.canCopy)
    }

    /// The whole reason the selection is not held by the views: a row scrolled
    /// away gives its view up to another row, and coming back it has to be handed
    /// its part again.
    func testASelectedRowScrolledAwayAndBackIsStillSelected() throws {
        mount((0..<60).map { "row \($0) of a transcript long enough to scroll" }, height: 300)
        let first = try cell(0).view
        let fourth = try cell(3).view
        drag(first, from: CGPoint(x: -500, y: 4), to: CGPoint(x: 5_000, y: 4), over: fourth)
        let copied = mounted.copy()
        XCTAssertEqual(copied?.components(separatedBy: "\n\n").count, 4)

        mounted.transcript.scrollToRow(at: 59, scrollPosition: .bottom)
        mounted.settle()
        let rows = mounted.transcript.descendants(ofType: BlockView.self)
            .map { mounted.transcript.row(for: $0) }
        XCTAssertFalse(rows.contains(0), "row 0 is still on screen, so nothing was recycled")

        mounted.transcript.scrollToRow(at: 0, scrollPosition: .top)
        mounted.settle()
        for row in 0...3 {
            let (view, block) = try cell(row)
            XCTAssertEqual(view.selectedRange, 0..<block.length, "row \(row)")
        }
        XCTAssertNil(try cell(4).view.selectedRange)
        XCTAssertEqual(mounted.copy(), copied)
    }

    /// Content can move under a pointer that does not: the focus is re-read
    /// whenever either moves, so a wheel turned mid-drag carries the selection
    /// to the row that is under the pointer now — and takes the row the press
    /// started in off screen, which the gesture does not notice.
    func testTurningTheWheelMidDragCarriesTheSelectionWithIt() throws {
        mount((0..<60).map { "row \($0) of a transcript long enough to scroll" }, height: 300)
        let pressed = try cell(0).view
        let pointer = event(.leftMouseDragged, at: CGPoint(x: 5_000, y: 4), in: try cell(2).view)
        let wheel = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -1_200,
                wheel2: 0, wheel3: 0
            ).flatMap(NSEvent.init(cgEvent:)))

        mounted.press(
            pressed, with: event(.leftMouseDown, at: CGPoint(x: -500, y: 4), in: pressed),
            then: [pointer, wheel])
        mounted.settle()

        let under = row(under: pointer)
        XCTAssertGreaterThan(under, 10, "the wheel did not scroll the transcript")
        XCTAssertGreaterThan(
            mounted.scrollView.documentVisibleRect.minY, mounted.transcript.rect(ofRow: 0).maxY,
            "row 0 is still on screen")
        XCTAssertEqual(mounted.copy()?.components(separatedBy: "\n\n").count, under + 1)
    }

    /// A pointer held past the bottom edge keeps the rows coming without the
    /// mouse moving: each tick scrolls, and the selection follows to whatever is
    /// under the pointer then. A drag stops producing events the moment the hand
    /// stops, so a transcript that scrolled only on drags stalled there.
    func testHoldingThePointerPastTheEdgeKeepsScrolling() throws {
        mount((0..<60).map { "row \($0) of a transcript long enough to scroll" }, height: 300)
        let pressed = try cell(0).view
        let below = CGPoint(x: 5_000, y: mounted.scrollView.documentVisibleRect.maxY + 40)
        let pointer = event(.leftMouseDragged, at: below, in: table)
        // Ten events rather than one posted ten times: the queue hands a repeated
        // object back once.
        let ticks = (0..<10).map { _ in
            NSEvent.otherEvent(
                with: .periodic, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!
        }

        mounted.press(
            pressed, with: event(.leftMouseDown, at: CGPoint(x: -500, y: 4), in: pressed),
            then: [pointer] + ticks)
        mounted.settle()

        let top = mounted.scrollView.documentVisibleRect.minY
        XCTAssertGreaterThan(top, 200, "ten ticks at 40 points past the edge scrolled \(top)")
        let under = row(under: pointer)
        XCTAssertEqual(mounted.copy()?.components(separatedBy: "\n\n").count, under + 1)
    }

    /// Only the views whose part changed are repainted, so a drag inside one row
    /// costs what it did before selections could span rows: that row.
    ///
    /// Read off the surfaces' `contents`, which a repaint replaces: the gesture
    /// is tracked to its release inside `mouseDown`, and the window displays while
    /// it runs, so by the time it returns there is nothing left *waiting* to paint.
    func testADragInsideOneRowRepaintsOnlyThatRow() throws {
        mount(["alpha one", "beta two", "gamma three"])
        let surfaces = try (0...2).map { try XCTUnwrap(cell($0).view.layer?.sublayers?.first) }
        XCTAssertEqual(
            surfaces.map { $0.needsDisplay() }, [false, false, false],
            "rows still waiting to paint, so nothing below is measured")
        var repainted: Set<Int> = []
        let observations = surfaces.enumerated().map { row, surface in
            surface.observe(\.contents) { _, _ in repainted.insert(row) }
        }

        sweep(try cell(1).view, atY: 4)
        mounted.settle()

        XCTAssertEqual(repainted, [1])
        withExtendedLifetime(observations) {}
    }

    // MARK: - Across a mutation

    /// Rows inserted above renumber the selection; the same text stays selected.
    func testInsertingRowsAboveKeepsTheSameTextSelected() throws {
        mount(["alpha one", "beta two", "gamma three"])
        drag(
            try cell(1).view, from: CGPoint(x: -500, y: 4), to: CGPoint(x: 5_000, y: 4),
            over: try cell(2).view)
        let copied = mounted.copy()
        XCTAssertEqual(copied, "beta two\n\ngamma three")

        host.rows.insert(contentsOf: [.init(text: "new zero"), .init(text: "new one")], at: 0)
        mounted.transcript.insertRows(at: IndexSet(0..<2))
        mounted.settle()

        XCTAssertEqual(mounted.copy(), copied)
    }

    /// Removing a row the selection runs through takes it out of the copy and
    /// leaves the rest selected — the ends are found again by identity.
    func testRemovingARowInsideTheSelectionKeepsTheRest() throws {
        mount(["alpha one", "beta two", "gamma three", "delta four"])
        drag(
            try cell(0).view, from: CGPoint(x: -500, y: 4), to: CGPoint(x: 5_000, y: 4),
            over: try cell(2).view)

        host.rows.remove(at: 1)
        mounted.transcript.removeRows(at: IndexSet(integer: 1))
        mounted.settle()

        XCTAssertEqual(mounted.copy(), "alpha one\n\ngamma three")
    }

    /// Removing the row an end was in leaves nowhere for that end to be.
    func testRemovingARowAnEndIsInDropsTheSelection() throws {
        mount(["alpha one", "beta two", "gamma three"])
        let first = try cell(0).view
        drag(
            first, from: CGPoint(x: -500, y: 4), to: CGPoint(x: 5_000, y: 4),
            over: try cell(1).view)

        host.rows.remove(at: 0)
        mounted.transcript.removeRows(at: IndexSet(integer: 0))
        mounted.settle()

        XCTAssertFalse(mounted.canCopy)
        XCTAssertTrue(
            mounted.transcript.descendants(ofType: BlockView.self).allSatisfy { $0.selectedRange == nil })
    }

    /// A reload does not change who a row is, so the selection is found again by
    /// identity — here after the rows it covers moved.
    func testReloadingFindsTheSelectionAgainByIdentity() throws {
        mount(["alpha one", "beta two", "gamma three"])
        drag(
            try cell(1).view, from: CGPoint(x: -500, y: 4), to: CGPoint(x: 5_000, y: 4),
            over: try cell(2).view)

        host.rows.append(host.rows.removeFirst())
        mounted.transcript.reloadData()
        mounted.settle()

        XCTAssertEqual(mounted.copy(), "beta two\n\ngamma three")
        XCTAssertNotNil(try cell(0).view.selectedRange)
        XCTAssertNil(try cell(2).view.selectedRange)
    }

    // MARK: - Rows the host draws

    /// A host's row has no text the transcript can see: a selection runs through
    /// it and copies around it.
    func testASelectionPassesThroughAHostRow() throws {
        mount(["alpha one", SelectionHost.hostRow, "gamma three"])
        let first = try cell(0).view
        let last = try cell(2).view

        drag(first, from: CGPoint(x: -500, y: 4), to: CGPoint(x: 5_000, y: 4), over: last)
        XCTAssertEqual(mounted.copy(), "alpha one\n\ngamma three")
    }

    // MARK: - Beside the text

    /// The document under the rows, reached the way a press is when no row
    /// takes it.
    private var table: NSView {
        mounted.scrollView.documentView!
    }

    /// The last row starting at or above `event`'s pointer: the one a selection
    /// dragged there ends in, gap or not.
    private func row(under event: NSEvent) -> Int {
        let list = mounted.transcript.descendants(ofType: ExactListView.self)[0]
        let y = list.convert(event.locationInWindow, from: nil).y
        let top = list.rect(ofRow: 0).minY
        return list.rows(in: NSRect(x: 0, y: top, width: 1, height: y - top + 1)).upperBound - 1
    }

    /// A press in the margin the centred column leaves is a press in the
    /// document, as it is in `NSTextView`: it clears a selection, and a drag from
    /// there selects.
    func testAPressInTheMarginClearsTheSelection() throws {
        mount(["alpha one", "beta two"], width: 600)
        mounted.transcript.maxContentWidth = 300
        mounted.settle()
        sweep(try cell(0).view, atY: 4)
        XCTAssertTrue(mounted.canCopy)

        mounted.press(table, with: event(.leftMouseDown, at: CGPoint(x: 10, y: 10), in: table))
        XCTAssertFalse(mounted.canCopy)
    }

    func testADragFromTheMarginSelectsTheRowsItCrosses() throws {
        mount(["alpha one", "beta two"], width: 600)
        mounted.transcript.maxContentWidth = 300
        mounted.settle()
        let row1 = mounted.transcript.rect(ofRow: 1)

        drag(table, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 590, y: row1.midY))
        XCTAssertEqual(mounted.copy(), "alpha one\n\nbeta two")
    }

    // MARK: - Letting go

    /// How a selection disappears when the reader moves on — into an input bar,
    /// into another transcript: the list's document stops being first responder.
    func testLosingFirstResponderClearsTheSelection() throws {
        mount(["alpha one", "beta two"])
        let first = try cell(0).view
        drag(
            first, from: CGPoint(x: -500, y: 4), to: CGPoint(x: 5_000, y: 4),
            over: try cell(1).view)
        XCTAssertTrue(mounted.canCopy)

        mounted.window.makeFirstResponder(nil)
        XCTAssertFalse(mounted.canCopy)
        XCTAssertNil(first.selectedRange)
    }

    /// The recycling rule: a pooled view handed a different document arrives as
    /// empty as a fresh one, until the transcript says what its row's part is.
    func testRebindingAViewClearsWhatItShows() throws {
        mount(["alpha beta gamma"])
        let view = try cell(0).view
        sweep(view, atY: 4)
        XCTAssertNotNil(view.selectedRange)

        view.configure(with: MarkdownBlockBuilder.make("something else").measure(400))
        XCTAssertNil(view.selectedRange)
    }

    // MARK: - What it looks like

    /// The case the whole paint model exists for. A code card fills an opaque
    /// rounded rect behind its text; before, a band drawn by this view landed
    /// under that fill and was never seen. Now the band is `.decoration` and the
    /// card is `.background`, so it lands between the card and the glyphs — and
    /// the card has no idea.
    func testTheBandIsVisibleInsideACodeCard() async throws {
        mount(["```swift\nlet x = 1\n```"])
        let (view, block) = try cell(0)

        let before = try await renderUntouched(view)
        sweep(view, atY: 20)
        let after = try await render(view)

        let band = try XCTUnwrap(block.rects(from: 0, to: block.length).first)
        XCTAssertTrue(mounted.canCopy, "the sweep selected nothing, so this proves nothing")

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
    /// `.background` is free — the view appends after the whole walk, so within
    /// any one tier its band already lands last. Below `.content` is not: tag the
    /// band `.content` or `.overlay` and the glyphs disappear under it.
    func testTheGlyphsStayOnTopOfTheBand() async throws {
        mount(["```swift\nlet x = 1\n```"])
        let (view, block) = try cell(0)

        let before = try await renderUntouched(view)
        sweep(view, atY: 20)
        let after = try await render(view)

        let band = try XCTUnwrap(block.rects(from: 0, to: block.length).first)
        let inkBefore = inkPixels(before, in: band)
        let inkAfter = inkPixels(after, in: band)

        XCTAssertGreaterThan(inkBefore, 20, "no glyphs in the band to begin with")
        XCTAssertGreaterThan(
            inkAfter, inkBefore * 3 / 4, "the band was painted over the text, not under it")
    }

    /// And nothing outside the band moves.
    func testTheBandLeavesEverythingOutsideItAlone() async throws {
        mount(["```swift\nlet x = 1\n```"])
        let (view, block) = try cell(0)

        let before = try await renderUntouched(view)
        sweep(view, atY: 20)
        let after = try await render(view)

        let band = try XCTUnwrap(block.rects(from: 0, to: block.length).first)
        let belowTheBand = CGRect(
            x: band.minX, y: band.maxY + 1,
            width: band.width, height: block.size.height - band.maxY - 2)

        XCTAssertEqual(changedPixels(before, after, in: belowTheBand), 0)
    }

    // MARK: - Two dimensions

    /// End to end for the shape that motivated the endpoint pair: the transcript
    /// knows only two indices, the table decides what lies between them, and what
    /// comes out is a rectangle rather than everything in reading order.
    func testDraggingDownATableColumnCopiesThatColumn() throws {
        mount(
            [
                """
                | a | b |
                |---|---|
                | c | d |
                | e | f |
                """
            ])
        let (view, block) = try cell(0)

        // Cell bands, row-major, from the table itself — so the drag is aimed at
        // real geometry rather than at numbers guessed here.
        let bands = block.fullRects()
        XCTAssertEqual(bands.count, 6)
        drag(
            view,
            from: CGPoint(x: bands[1].midX, y: bands[1].midY),
            to: CGPoint(x: bands[5].midX, y: bands[5].midY))

        XCTAssertEqual(mounted.copy(), "b\nd\nf")
    }
}

/// Markdown rows from a list a test can rewrite, with one marker standing for a
/// row the host draws.
@MainActor
private final class SelectionHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {

    static let hostRow = "<host row>"

    /// A row's identity is minted with it, so a test inserting, removing or
    /// reordering rows is moving the *same* rows, as a host with stable message
    /// ids would.
    struct Row {
        let id = UUID()
        var text: String
    }

    var rows: [Row]

    init(rows: [String]) {
        self.rows = rows.map { Row(text: $0) }
    }

    func numberOfRows(in transcriptView: TranscriptView) -> Int { rows.count }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        let text = rows[row].text
        return TranscriptRow(id: rows[row].id, content: text == Self.hostRow ? .view : .markdown(text))
    }

    func transcriptView(
        _ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat
    ) -> CGFloat { 40 }

    func transcriptView(_ transcriptView: TranscriptView, viewForRow row: Int) -> NSView {
        transcriptView.makeView(withIdentifier: .init("test.selection.host")) { NSView() }
    }
}

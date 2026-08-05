import AppKit
import CoreText
import XCTest

@testable import TranscriptKit

/// Rows measured off the main actor and handed to `insertRows(at:prepared:)`.
///
/// The claim is a narrow one and it is worth stating before the assertions: a
/// prepared insert differs from a plain one **only in where the typesetting
/// ran**. So most of what is checked here is *sameness* — the same heights, the
/// same scroll offset, the same behaviour when the batch is wrong — against a
/// second transcript doing it the ordinary way, rather than against numbers
/// written down here. A number would be one more thing to keep in step with the
/// layout; a control transcript cannot drift.
///
/// **How seeding is observed.** That a prepared batch was *used* rather than
/// merely tolerated cannot be read from a height — a re-measure produces the
/// same one, which is the entire point. So it is read the way
/// `MarkdownGrowthTests` reads reuse: a `CTLine` is a reference type produced by
/// typesetting, so the same instance appearing in the row on screen and in the
/// batch that was prepared means that row's glyphs were laid out on the
/// background task and never again. Ordinary production state reached through
/// `@testable`, not a counter added for the test.
///
/// **What is not here, deliberately.** Nothing times anything. A test that
/// asserted a prepared insert is faster would be asserting the machine it runs
/// on; the reason to prefer one is that the work happens somewhere else, and
/// where it happened is what the `CTLine` check reads. Whether the window still
/// *feels* alive during a ten-thousand-row load is `make demo-kit`'s Cold load
/// buttons.
@MainActor
final class PreparedRowsTests: XCTestCase {

    private var mounted: [MountedTranscript] = []

    override func tearDown() {
        mounted.forEach { $0.teardown() }
        mounted = []
        super.tearDown()
    }

    // MARK: - Mounting

    /// Four documents' worth of shapes, so a row's height is a real measurement
    /// rather than one line of prose repeated.
    ///
    /// Every one of them is **long enough to wrap differently at 600 points than
    /// at 420**, which `testAStaleWidthFallsBackToMeasuring` depends on and
    /// asserts rather than assuming: with documents short enough to fit on one
    /// line at both widths, a transcript that ignored the width entirely would
    /// pass it.
    private static let sources = [
        """
        # First

        A paragraph with *emphasis*, `code`, and a [link](https://example.com),
        written long enough that where it breaks depends on how wide the column
        is — which is the whole of what a stale measurement gets wrong, and
        therefore the whole of what these documents have to be able to show.
        """,
        """
        ## Second

        - one, and a clause after it so the item wraps at a narrow measure
        - two, likewise, because a list of single words reflows identically at
          every width anybody would test at
        - three

        > and a quote, also long enough that its bar has more than one line of
        > glyphs to run beside
        """,
        """
        ### Third

        Prose above the fence, and a good deal of it, because a fenced block is
        the same height at every width — it scrolls rather than reflowing — so a
        document whose only variable part is one short sentence can measure to
        exactly the same number at two widths several hundred points apart.

        ```swift
        let x = 1
        let y = 2
        ```
        """,
        """
        #### Fourth

        | a | b |
        |---|---|
        | 1 | 2 |

        And a closing paragraph under the table, which has to be long enough to
        break in a different place at each of the two widths this suite mounts —
        a table's own height barely moves between them, since its columns are
        sized to their content and only give way once the sum stops fitting, so
        the prose beside it is what carries this document's sensitivity to width.
        """,
    ]

    /// A user's turn, long enough to wrap inside the bubble's three-quarter
    /// column. The other case the transcript draws itself, and the only one whose
    /// recipe is spelled twice — see `testPreparedAndOnDemandAgree`.
    private static let userTurn =
        SourceHost.userTurnPrefix
        + "What I actually typed, at enough length that the bubble wraps and its "
        + "height is a real measurement rather than one line's worth of padding."

    /// A transcript holding `sources`, mounted and settled. Tall enough that
    /// every row in these tests is on screen, which the `CTLine` reads need.
    private func mount(_ sources: [String], width: CGFloat = 600) -> (MountedTranscript, SourceHost) {
        let host = SourceHost(sources: sources)
        let transcript = MountedTranscript(size: NSSize(width: width, height: 900))
        mounted.append(transcript)
        transcript.transcript.dataSource = host
        transcript.transcript.delegate = host
        transcript.settle()
        transcript.transcript.reloadData()
        transcript.settle()
        return (transcript, host)
    }

    /// Every row's rectangle, which is what "the same layout" means here.
    private func rects(_ transcript: TranscriptView) -> [NSRect] {
        (0..<transcript.numberOfRows).map { transcript.rect(ofRow: $0) }
    }

    /// The `CTLine` row `row`'s first child is typeset into.
    private func firstLine(ofRow row: Int, in transcript: MountedTranscript) -> CTLine? {
        let view = transcript.transcript.descendants(ofType: BlockView.self)
            .first { transcript.transcript.row(for: $0) == row }
        guard let stack = view?.block as? BlockStack.Measured,
            let text = stack.children.first?.block as? MeasuredTextBlock
        else { return nil }
        return text.text.lines.first?.ctLine
    }

    /// The same, out of a batch that has not been inserted yet.
    private func firstLine(ofEntry offset: Int, in prepared: PreparedRows) -> CTLine? {
        guard let stack = prepared[offset]?.entry.measured as? BlockStack.Measured,
            let text = stack.children.first?.block as? MeasuredTextBlock
        else { return nil }
        return text.text.lines.first?.ctLine
    }

    // MARK: - The answer does not depend on where it was measured

    /// The property two comments in the package point at by name: a row prepared
    /// on a background task and the same row measured on demand come out
    /// identical. Both call sites reach `TranscriptRowContent.entry(width:)`
    /// through different paths — one through `RowCache`'s miss, one directly —
    /// and a disagreement between them would not fail, it would show up as a row
    /// whose height changes the first time anything re-measures it.
    func testPreparedAndOnDemandAgree() async {
        let (control, controlHost) = mount([Self.sources[0]])
        let (subject, subjectHost) = mount([Self.sources[0]])
        XCTAssertFalse(controlHost.contentCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.contentCalls.isEmpty, "the subject never laid out")

        // **Both** self-drawn cases, because they reach their recipe by
        // different routes: a document through `MarkdownMemo`, a bubble through
        // a `build` closure the cache holds. Only one of those routes is shared
        // with `prepareRows`, so a suite of documents alone would leave the
        // bubble's two spellings free to drift.
        let batch = Array(Self.sources.dropFirst()) + [Self.userTurn]

        controlHost.sources.insert(contentsOf: batch, at: 0)
        control.transcript.insertRows(at: IndexSet(0..<batch.count))
        control.settle()

        let prepared = await subject.transcript.prepareRows(batch.map(SourceHost.content(for:)))
        subjectHost.sources.insert(contentsOf: batch, at: 0)
        subject.transcript.insertRows(at: IndexSet(0..<batch.count), prepared: prepared)
        subject.settle()

        XCTAssertEqual(subject.transcript.numberOfRows, control.transcript.numberOfRows)
        XCTAssertEqual(rects(subject.transcript), rects(control.transcript))
    }

    /// The same text, prepared as one content case and inserted as another.
    ///
    /// **The defect this file was written to find.** A user's turn is measured
    /// into three quarters of the content column and a document into all of it,
    /// so one string has two heights; a seed that identified a measurement by its
    /// *text* would accept the document's answer onto the bubble's row. And the
    /// entry it wrote would be internally consistent — right source, right
    /// width — so nothing downstream would ever disagree with it. Not a wasted
    /// re-measure like every other mismatch here, but a row permanently the wrong
    /// height, which is the one outcome `RowCache`'s read-time validation cannot
    /// catch on its own.
    ///
    /// A host reaches this by handing `prepareRows` a batch built from a
    /// different mapping than its data source answers from — two spellings of
    /// "which case is this row", which is an easy thing to have.
    func testAnEntryWhoseCaseChangedIsNotSeeded() async {
        let (control, controlHost) = mount([Self.sources[0]])
        let (subject, subjectHost) = mount([Self.sources[0]])
        XCTAssertFalse(controlHost.contentCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.contentCalls.isEmpty, "the subject never laid out")

        // Prepared as a document …
        let prepared = await subject.transcript.prepareRows([.markdown(Self.userTurn)])
        // … and the host serves that very row as a bubble.
        XCTAssertEqual(SourceHost.content(for: Self.userTurn), .userMessage(Self.userTurn))

        controlHost.sources.insert(Self.userTurn, at: 0)
        control.transcript.insertRows(at: IndexSet(integer: 0))
        control.settle()

        subjectHost.sources.insert(Self.userTurn, at: 0)
        subject.transcript.insertRows(at: IndexSet(integer: 0), prepared: prepared)
        subject.settle()

        // The premise: the two cases really do measure differently, or this test
        // would pass against a seed that checked nothing at all.
        XCTAssertNotEqual(
            TranscriptRowContent.markdown(Self.userTurn).entry(width: 600)?.measured.size.height,
            TranscriptRowContent.userMessage(Self.userTurn).entry(width: 600)?.measured.size.height)

        XCTAssertEqual(
            rects(subject.transcript), rects(control.transcript),
            "the bubble was drawn at the height the same text measures to as a document")
    }

    /// And the batch really was what got used. Without this the suite would pass
    /// on a `insertRows(at:prepared:)` that ignored its argument entirely — every
    /// other assertion here is about sameness, and re-measuring produces the same
    /// answer.
    func testASeededRowDrawsTheTreeThatWasPrepared() async {
        let (transcript, host) = mount([Self.sources[0]])
        XCTAssertFalse(host.contentCalls.isEmpty, "the transcript never laid out")

        let batch = Array(Self.sources.dropFirst())
        let prepared = await transcript.transcript.prepareRows(batch.map { .markdown($0) })
        let offMain = firstLine(ofEntry: 0, in: prepared)
        XCTAssertNotNil(offMain, "nothing was measured off the main actor")

        host.sources.insert(contentsOf: batch, at: 0)
        transcript.transcript.insertRows(at: IndexSet(0..<batch.count), prepared: prepared)
        transcript.settle()

        XCTAssertIdentical(
            firstLine(ofRow: 0, in: transcript), offMain,
            "row 0 was typeset again on the main thread instead of taking the prepared tree")
    }

    /// A prepared row costs no more to **resize** than one the transcript
    /// measured itself.
    ///
    /// The defect this pins is the reason `RowCache.Body` has two cases rather
    /// than three. A batch that carried only its measurement across the actor
    /// boundary left every row it filed without a recipe, so the first width
    /// change re-parsed *and re-shaped* the whole transcript instead of only
    /// re-breaking its lines — on ten thousand rows, a resize that stops
    /// responding rather than one that takes a moment. It shipped that way for
    /// exactly as long as it took to drag a window.
    ///
    /// Read through the shaped `NSAttributedString`, which is what shaping
    /// produces and what a kept recipe lets a resize skip. Same instance across
    /// the width change means the row re-broke lines from a recipe it still had;
    /// a different one means it was built again from source. `MarkdownGrowthTests`
    /// reads the same property for the streaming case.
    func testAPreparedRowResizesFromItsRecipe() async {
        let (control, controlHost) = mount([Self.sources[0]])
        let (subject, subjectHost) = mount([Self.sources[0]])
        XCTAssertFalse(controlHost.contentCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.contentCalls.isEmpty, "the subject never laid out")

        let batch = [Self.sources[1]]
        controlHost.sources.insert(contentsOf: batch, at: 0)
        control.transcript.insertRows(at: IndexSet(integer: 0))
        control.settle()

        let prepared = await subject.transcript.prepareRows(batch.map(SourceHost.content(for:)))
        subjectHost.sources.insert(contentsOf: batch, at: 0)
        subject.transcript.insertRows(at: IndexSet(integer: 0), prepared: prepared)
        subject.settle()

        let controlBefore = shaped(ofRow: 0, in: control)
        let subjectBefore = shaped(ofRow: 0, in: subject)
        XCTAssertNotNil(controlBefore, "the control row was never shaped")
        XCTAssertNotNil(subjectBefore, "the prepared row was never shaped")

        control.setContentWidth(430)
        subject.setContentWidth(430)
        control.settle()
        subject.settle()

        // The premise: the resize really did re-measure, or "same shaped string"
        // would just mean "nothing happened".
        XCTAssertNotEqual(
            rects(subject.transcript), [NSRect](repeating: .zero, count: 2),
            "no geometry at all")
        XCTAssertEqual(rects(subject.transcript), rects(control.transcript))

        XCTAssertIdentical(
            shaped(ofRow: 0, in: control), controlBefore,
            "the control re-shaped on resize, so this test cannot tell the two apart")
        XCTAssertIdentical(
            shaped(ofRow: 0, in: subject), subjectBefore,
            "the prepared row was re-shaped from source on resize instead of "
                + "re-measured from the recipe it arrived with")
    }

    /// The shaped string row `row`'s first child was typeset from — the product of
    /// the expensive, width-independent half of the work.
    private func shaped(ofRow row: Int, in transcript: MountedTranscript) -> NSAttributedString? {
        let view = transcript.transcript.descendants(ofType: BlockView.self)
            .first { transcript.transcript.row(for: $0) == row }
        guard let stack = view?.block as? BlockStack.Measured,
            let text = stack.children.first?.block as? MeasuredTextBlock
        else { return nil }
        return text.text.attributed
    }

    /// `.view` rows ride along and carry nothing: their height is the delegate's,
    /// and asking for it off the main actor is not something this package can do.
    /// A host with mixed content therefore hands over the whole batch rather than
    /// filtering it and re-interleaving the result.
    func testViewRowsCarryNoMeasurementAndStillGetTheirHeight() async {
        let (transcript, host) = mount([Self.sources[0]])
        XCTAssertFalse(host.contentCalls.isEmpty, "the transcript never laid out")

        let contents: [TranscriptRowContent] = [.view, .markdown(Self.sources[1])]
        let prepared = await transcript.transcript.prepareRows(contents)

        XCTAssertEqual(prepared.count, 2)
        XCTAssertNil(prepared[0], "a .view row has nothing this package can measure")
        XCTAssertNotNil(prepared[1])

        host.sources.insert(contentsOf: [SourceHost.hostDrawn, Self.sources[1]], at: 0)
        transcript.transcript.insertRows(at: IndexSet(0..<2), prepared: prepared)
        transcript.settle()

        XCTAssertEqual(
            transcript.transcript.rect(ofRow: 0).height, SourceHost.hostRowHeight + Self.rowSpacing,
            "the .view row's height did not come from the delegate")
    }

    /// `NSTableView` centres the cell in a row rect this much taller; see
    /// `TranscriptView.rowSpacing`. Written here rather than derived so that the
    /// assertion above says what it means.
    private static let rowSpacing: CGFloat = 14

    // MARK: - A batch that no longer applies

    /// The window moved between the `await` and the insert, so every entry was
    /// measured into a width that is no longer the one in force. The transcript
    /// lands exactly where it would have with no preparation at all.
    ///
    /// **The premise is asserted, not assumed.** The layouts at the two widths
    /// have to actually differ, or a transcript that ignored the width outright
    /// would pass this — which is not hypothetical: the first version of this
    /// test used documents short enough to fit on one line at both widths, and
    /// stayed green through a break that filed every stale measurement as
    /// current.
    func testAStaleWidthFallsBackToMeasuring() async {
        let (control, controlHost) = mount([Self.sources[0]], width: 420)
        let (subject, subjectHost) = mount([Self.sources[0]], width: 600)
        XCTAssertFalse(controlHost.contentCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.contentCalls.isEmpty, "the subject never laid out")

        let batch = Array(Self.sources.dropFirst())
        // Measured at 600 …
        let prepared = await subject.transcript.prepareRows(batch.map { .markdown($0) })
        let heightsAt600 = batch.compactMap {
            TranscriptRowContent.markdown($0).entry(width: 600)?.measured.size.height
        }
        // … and inserted at 420.
        subject.setContentWidth(420)
        subject.settle()

        controlHost.sources.insert(contentsOf: batch, at: 0)
        control.transcript.insertRows(at: IndexSet(0..<batch.count))
        control.settle()

        subjectHost.sources.insert(contentsOf: batch, at: 0)
        subject.transcript.insertRows(at: IndexSet(0..<batch.count), prepared: prepared)
        subject.settle()

        let heightsAt420 = batch.compactMap {
            TranscriptRowContent.markdown($0).entry(width: 420)?.measured.size.height
        }
        XCTAssertEqual(heightsAt600.count, batch.count)
        for (index, pair) in zip(heightsAt600, heightsAt420).enumerated() {
            XCTAssertNotEqual(
                pair.0, pair.1,
                "document \(index) measures the same at both widths, so it cannot detect a stale one")
        }

        XCTAssertEqual(rects(subject.transcript), rects(control.transcript))
    }

    /// The host got the ordering wrong — it mutated across the `await`, so the
    /// rows the batch describes are not the rows it is being filed under. Per-row
    /// source checking catches it, and what is lost is the background work rather
    /// than the render.
    ///
    /// This is the assertion behind the claim that the rule on
    /// `insertRows(at:prepared:)` is documented rather than enforced: breaking it
    /// costs throughput, not correctness.
    func testAnEntryWhoseSourceMovedIsNotSeeded() async {
        let (control, controlHost) = mount([Self.sources[0]])
        let (subject, subjectHost) = mount([Self.sources[0]])
        XCTAssertFalse(controlHost.contentCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.contentCalls.isEmpty, "the subject never laid out")

        // Prepared for one document …
        let prepared = await subject.transcript.prepareRows([.markdown(Self.sources[1])])
        // … and a different one is what actually arrives at that index.
        let arrived = Self.sources[3]

        controlHost.sources.insert(arrived, at: 0)
        control.transcript.insertRows(at: IndexSet(integer: 0))
        control.settle()

        subjectHost.sources.insert(arrived, at: 0)
        subject.transcript.insertRows(at: IndexSet(integer: 0), prepared: prepared)
        subject.settle()

        XCTAssertEqual(
            rects(subject.transcript), rects(control.transcript),
            "the row rendered at the height of the document that was prepared, not the one present")
    }

    // MARK: - Everything else about the insert is unchanged

    /// Scroll anchoring does not know a prepared insert from a plain one, and
    /// this is what says so: the same prepend, from the same offset, lands on the
    /// same offset. Rule 2 covers it because it is the same code path — which is
    /// the property that would break if seeding ever moved outside `mutate`.
    func testAPreparedPrependHoldsTheViewportLikeAPlainOne() async {
        let filler = (0..<12).map { "Row \($0)\n\n\(Self.sources[1])" }
        let (control, controlHost) = mount(filler)
        let (subject, subjectHost) = mount(filler)
        XCTAssertFalse(controlHost.contentCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.contentCalls.isEmpty, "the subject never laid out")

        // Away from the tail, where holding still is the rule that applies.
        control.scroll(toY: 300)
        subject.scroll(toY: 300)
        control.settle()
        subject.settle()
        XCTAssertEqual(subject.scrollView.contentView.bounds.minY, 300, accuracy: 1)

        let batch = Self.sources
        let prepared = await subject.transcript.prepareRows(batch.map { .markdown($0) })

        controlHost.sources.insert(contentsOf: batch, at: 0)
        control.transcript.insertRows(at: IndexSet(0..<batch.count))
        control.settle()

        subjectHost.sources.insert(contentsOf: batch, at: 0)
        subject.transcript.insertRows(at: IndexSet(0..<batch.count), prepared: prepared)
        subject.settle()

        XCTAssertEqual(
            subject.scrollView.contentView.bounds.minY,
            control.scrollView.contentView.bounds.minY, accuracy: 0.5)
        XCTAssertGreaterThan(
            subject.scrollView.contentView.bounds.minY, 300,
            "nothing was prepended above the viewport, so the test proved nothing")
    }

    /// Cancelling stops the work rather than only discarding it, so what comes
    /// back is a batch with holes in it — which is a state the seed already
    /// handles, and not one a host has to.
    func testCancellationYieldsABatchTheInsertStillTolerates() async {
        let (transcript, host) = mount([Self.sources[0]])
        XCTAssertFalse(host.contentCalls.isEmpty, "the transcript never laid out")

        let batch = Self.sources
        let task = Task { await transcript.transcript.prepareRows(batch.map { .markdown($0) }) }
        task.cancel()
        let prepared = await task.value

        // The count is the batch's whatever happened to the entries: the array is
        // positional, and a hole is how a row says "measure me yourself".
        XCTAssertEqual(prepared.count, batch.count)

        host.sources.insert(contentsOf: batch, at: 0)
        transcript.transcript.insertRows(at: IndexSet(0..<batch.count), prepared: prepared)
        transcript.settle()

        XCTAssertEqual(transcript.transcript.numberOfRows, batch.count + 1)
        for row in 0..<transcript.transcript.numberOfRows {
            XCTAssertGreaterThan(
                transcript.transcript.rect(ofRow: row).height, Self.rowSpacing,
                "row \(row) came out empty")
        }
    }
}

/// A host whose rows are markdown documents, plus one sentinel that means "this
/// one is yours to draw".
///
/// No logic beyond that mapping: the mutators are the test's to call and the
/// announcement is the test's to make, so both halves of what a host does sit
/// next to each other at the call site.
@MainActor
private final class SourceHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {

    /// A source that means `.view` instead of a document. A sentinel rather than
    /// a second array, so a test's `insert(at:)` stays the one call a real host
    /// would make.
    static let hostDrawn = "\u{0}host-drawn"

    /// Prefix marking a source as a user's turn rather than a document — the
    /// other case the transcript draws itself, and the one whose recipe is named
    /// in two places (`TranscriptRowContent.measured(width:)` and the `build`
    /// closure in `TranscriptView.measuredBlock(forRow:content:)`). A suite of
    /// `.markdown` rows alone cannot see those two drift apart.
    static let userTurnPrefix = "\u{1}"

    static let hostRowHeight: CGFloat = 77

    var sources: [String]

    /// Which rows were asked about, in order — the evidence that the transcript
    /// was provoked at all. Every test opens on it, because a mount that silently
    /// never lays out makes every later assertion pass against an empty tree.
    private(set) var contentCalls: [Int] = []

    init(sources: [String]) {
        self.sources = sources
        super.init()
    }

    func numberOfRows(in transcriptView: TranscriptView) -> Int { sources.count }

    func transcriptView(
        _ transcriptView: TranscriptView, contentForRow row: Int
    ) -> TranscriptRowContent {
        contentCalls.append(row)
        return Self.content(for: sources[row])
    }

    /// The mapping, as a `static` so a test can build the batch it hands to
    /// `prepareRows(_:)` through the **same** function the data source answers
    /// from. A test that spelled the mapping a second time would be free to
    /// prepare a document for a row this host serves as a bubble — which is a
    /// host bug worth having a test of its own
    /// (`testAnEntryWhoseCaseChangedIsNotSeeded`), not one to reproduce by
    /// accident in every other test in the file.
    static func content(for source: String) -> TranscriptRowContent {
        if source == hostDrawn { return .view }
        if source.hasPrefix(userTurnPrefix) { return .userMessage(source) }
        return .markdown(source)
    }

    func transcriptView(
        _ transcriptView: TranscriptView, heightOfRow row: Int, width: CGFloat
    ) -> CGFloat {
        Self.hostRowHeight
    }

    func transcriptView(_ transcriptView: TranscriptView, viewForRow row: Int) -> NSView {
        transcriptView.makeView(withIdentifier: .hostDrawn) { NSView() }
    }
}

extension NSUserInterfaceItemIdentifier {
    fileprivate static let hostDrawn = NSUserInterfaceItemIdentifier("test.preparedRows.hostDrawn")
}

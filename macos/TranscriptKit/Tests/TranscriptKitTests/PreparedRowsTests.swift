import AppKit
import CoreText
import XCTest

@testable import TranscriptKit

/// Rows measured off the main actor and handed to `insertRows(at:warming:)`.
///
/// The claim is a narrow one and it is worth stating before the assertions: a
/// prepared insert differs from a plain one **only in where the typesetting
/// ran**. So most of what is checked here is *sameness* — the same heights, the
/// same scroll offset, the same behaviour when the batch is wrong — against a
/// second transcript doing it the ordinary way, rather than against numbers
/// written down here. A number would be one more thing to keep in step with the
/// layout; a control transcript cannot drift.
///
/// **How warming is observed.** That a prepared batch was *used* rather than
/// merely tolerated cannot be read from a height — a re-measure produces the
/// same one, which is the entire point. So it is read the way
/// `MarkdownGrowthTests` reads reuse: a `CTLine` is a reference type produced by
/// typesetting, so the same instance appearing in the row on screen and in the
/// batch that was prepared means that row's glyphs were laid out on the
/// background task and never again. Ordinary production state reached through
/// `@testable`, not a counter added for the test.
///
/// **Half of what this file used to check cannot happen any more.** A batch was
/// paired with an `IndexSet` by position, so it could be filed onto the wrong
/// rows, and there were tests for detecting that at the landing site. Since a
/// measurement is filed under the identity the data source gave the row it was
/// made for, there is no landing site and nothing to detect: what replaced those
/// tests is `testABatchSurvivesRenumbering`, which asserts the batch is still
/// *used* in the situation that used to discard it.
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
        return Self.firstLine(view?.block as? BlockStack.Measured)
    }

    /// The same, out of a batch that has not been inserted yet — found by the
    /// identity it was measured for, since that is the only thing a batch is
    /// ordered by now.
    private func firstLine(of id: UUID, in prepared: PreparedRows) -> CTLine? {
        Self.firstLine(prepared.entries[TranscriptRow.ID(id)]?.measured as? BlockStack.Measured)
    }

    private static func firstLine(_ stack: BlockStack.Measured?) -> CTLine? {
        guard let text = stack?.children.first?.block as? MeasuredTextBlock else { return nil }
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
        XCTAssertFalse(controlHost.rowCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.rowCalls.isEmpty, "the subject never laid out")

        // **Both** self-drawn cases, because they reach their recipe by
        // different routes: a document through `MarkdownMemo`, a bubble through
        // a `build` closure the cache holds. Only one of those routes is shared
        // with `prepareRows`, so a suite of documents alone would leave the
        // bubble's two spellings free to drift.
        let batch = (Array(Self.sources.dropFirst()) + [Self.userTurn]).map(SourceHost.Row.init)

        controlHost.rows.insert(contentsOf: batch, at: 0)
        control.transcript.insertRows(at: IndexSet(0..<batch.count))
        control.settle()

        let prepared = await subject.transcript.prepareRows(batch.map(\.described))
        subjectHost.rows.insert(contentsOf: batch, at: 0)
        subject.transcript.insertRows(at: IndexSet(0..<batch.count), warming: prepared)
        subject.settle()

        XCTAssertEqual(subject.transcript.numberOfRows, control.transcript.numberOfRows)
        XCTAssertEqual(rects(subject.transcript), rects(control.transcript))
    }

    /// The same text, prepared as one content case and served as another.
    ///
    /// **The defect this file was written to find.** A user's turn is measured
    /// into three quarters of the content column and a document into all of it,
    /// so one string has two heights; a cache that identified a measurement by its
    /// *text* would serve the document's answer to the bubble's row. And the entry
    /// it holds would be internally consistent — right source, right width — so
    /// nothing downstream would ever disagree with it. Not a wasted re-measure
    /// like every other mismatch here, but a row permanently the wrong height.
    ///
    /// The identity does not close this one: the row really is the row it claims
    /// to be, and what disagrees is only which case it arrives as. Comparing whole
    /// `TranscriptRowContent` values is what catches it, on read, in `RowCache`.
    ///
    /// **Both directions, because they are caught by different code.** A document
    /// filed onto a bubble is rejected by the bubble's path failing to find a
    /// `.block` body to re-measure from; a bubble filed onto a document is
    /// rejected only by the content comparison itself. This test asserted just the
    /// first for a while and stayed green through a break that reduced that
    /// comparison to its source text — §5's rule, met the hard way.
    ///
    /// A host reaches this by handing `prepareRows` a batch built from a
    /// different mapping than its data source answers from — two spellings of
    /// "which case is this row", which is an easy thing to have.
    func testAMeasurementPreparedAsTheWrongCaseIsNotUsed() async {
        let (control, controlHost) = mount([Self.sources[0]])
        let (subject, subjectHost) = mount([Self.sources[0]])
        XCTAssertFalse(controlHost.rowCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.rowCalls.isEmpty, "the subject never laid out")

        // A row the host serves as a bubble, and one it serves as a document.
        let batch = [SourceHost.Row(Self.userTurn), SourceHost.Row(Self.sources[1])]
        XCTAssertEqual(batch[0].described.content, .userMessage(Self.userTurn))
        XCTAssertEqual(batch[1].described.content, .markdown(Self.sources[1]))

        // Prepared under the right identities and the wrong cases — each as what
        // the other one is.
        let prepared = await subject.transcript.prepareRows([
            TranscriptRow(id: batch[0].id, content: .markdown(batch[0].source)),
            TranscriptRow(id: batch[1].id, content: .userMessage(batch[1].source)),
        ])
        XCTAssertEqual(prepared.count, 2, "nothing was prepared, so nothing is being rejected")

        controlHost.rows.insert(contentsOf: batch, at: 0)
        control.transcript.insertRows(at: IndexSet(0..<batch.count))
        control.settle()

        subjectHost.rows.insert(contentsOf: batch, at: 0)
        subject.transcript.insertRows(at: IndexSet(0..<batch.count), warming: prepared)
        subject.settle()

        // The premise: each string really does measure differently in the two
        // cases, or this test would pass against a cache that checked nothing.
        for source in [Self.userTurn, Self.sources[1]] {
            XCTAssertNotEqual(
                TranscriptRowContent.markdown(source).entry(width: 600)?.measured.size.height,
                TranscriptRowContent.userMessage(source).entry(width: 600)?.measured.size.height,
                "this source measures the same either way, so it cannot detect a wrong case")
        }

        XCTAssertEqual(
            rects(subject.transcript), rects(control.transcript),
            "a row was drawn at the height its text measures to in the other case")
    }

    /// A bubble whose text moved is measured again.
    ///
    /// Here rather than in `UserMessageRowTests` because what it pins is the same
    /// comparison as the test above — `RowCache` believing an entry only as far as
    /// its content still matches — approached from the other side: not a wrong
    /// case under the right identity, but the right case with the text changed
    /// underneath it. `MarkdownGrowthTests` covers this for documents in far more
    /// depth; the bubble had nothing, which a break of that comparison found by
    /// staying green through the whole suite.
    ///
    /// Not a hypothetical path either: it is what a user's turn does when the
    /// authoritative text replaces what was streamed, or when a retry rewrites it.
    func testABubbleWhoseTextChangedIsReMeasured() {
        let grown =
            Self.userTurn + " And then a further paragraph's worth of it, so that the "
            + "bubble certainly wraps onto more lines than it did before."
        let (control, controlHost) = mount([grown])
        let (subject, subjectHost) = mount([Self.userTurn])
        XCTAssertFalse(controlHost.rowCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.rowCalls.isEmpty, "the subject never laid out")

        let before = subject.transcript.rect(ofRow: 0)
        // The premise: the two texts really do measure to different heights.
        XCTAssertNotEqual(
            before.height, control.transcript.rect(ofRow: 0).height,
            "the two texts measure the same, so this cannot see a stale entry")

        subjectHost.rows[0].source = grown
        subject.transcript.reloadRows(at: IndexSet(integer: 0))
        subject.settle()

        XCTAssertEqual(
            rects(subject.transcript), rects(control.transcript),
            "the bubble kept the height of the text it used to hold")
    }

    /// And the batch really was what got used. Without this the suite would pass
    /// on an `insertRows(at:warming:)` that ignored its argument entirely — every
    /// other assertion here is about sameness, and re-measuring produces the same
    /// answer.
    func testAWarmedRowDrawsTheTreeThatWasPrepared() async {
        let (transcript, host) = mount([Self.sources[0]])
        XCTAssertFalse(host.rowCalls.isEmpty, "the transcript never laid out")

        let batch = Array(Self.sources.dropFirst()).map(SourceHost.Row.init)
        let prepared = await transcript.transcript.prepareRows(batch.map(\.described))
        let offMain = firstLine(of: batch[0].id, in: prepared)
        XCTAssertNotNil(offMain, "nothing was measured off the main actor")

        host.rows.insert(contentsOf: batch, at: 0)
        transcript.transcript.insertRows(at: IndexSet(0..<batch.count), warming: prepared)
        transcript.settle()

        XCTAssertIdentical(
            firstLine(ofRow: 0, in: transcript), offMain,
            "row 0 was typeset again on the main thread instead of taking the prepared tree")
    }

    /// **What the identity bought**, and the one test here that could not have
    /// been written before it.
    ///
    /// The host prepends rows *between* preparing a batch and inserting it, so
    /// every index the batch could have been paired with now means a different
    /// row. Under the positional pairing this discarded the batch entirely —
    /// worst on a prepend, which is exactly what loading history is — and the
    /// insert paid for the typesetting a second time. Filed under identity, the
    /// batch does not care.
    func testABatchSurvivesRenumbering() async {
        let (transcript, host) = mount([Self.sources[0]])
        XCTAssertFalse(host.rowCalls.isEmpty, "the transcript never laid out")

        let batch = Array(Self.sources.dropFirst()).map(SourceHost.Row.init)
        let prepared = await transcript.transcript.prepareRows(batch.map(\.described))
        let offMain = firstLine(of: batch[0].id, in: prepared)
        XCTAssertNotNil(offMain, "nothing was measured off the main actor")

        // Something else arrives first and renumbers everything.
        host.rows.insert(SourceHost.Row(Self.sources[0]), at: 0)
        transcript.transcript.insertRows(at: IndexSet(integer: 0))
        transcript.settle()

        host.rows.insert(contentsOf: batch, at: 0)
        transcript.transcript.insertRows(at: IndexSet(0..<batch.count), warming: prepared)
        transcript.settle()

        XCTAssertIdentical(
            firstLine(ofRow: 0, in: transcript), offMain,
            "the batch was thrown away because rows had been renumbered under it")
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
        XCTAssertFalse(controlHost.rowCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.rowCalls.isEmpty, "the subject never laid out")

        let batch = [SourceHost.Row(Self.sources[1])]
        controlHost.rows.insert(contentsOf: batch, at: 0)
        control.transcript.insertRows(at: IndexSet(integer: 0))
        control.settle()

        let prepared = await subject.transcript.prepareRows(batch.map(\.described))
        subjectHost.rows.insert(contentsOf: batch, at: 0)
        subject.transcript.insertRows(at: IndexSet(integer: 0), warming: prepared)
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

    /// `.view` rows ride along and produce nothing: their height is the
    /// delegate's, and asking for it off the main actor is not something this
    /// package can do. A host with mixed content therefore hands over the whole
    /// batch rather than filtering it — and since the result is keyed by identity
    /// there is nothing to re-interleave afterwards.
    func testViewRowsCarryNoMeasurementAndStillGetTheirHeight() async {
        let (transcript, host) = mount([Self.sources[0]])
        XCTAssertFalse(host.rowCalls.isEmpty, "the transcript never laid out")

        let batch = [SourceHost.hostDrawn, Self.sources[1]].map(SourceHost.Row.init)
        let prepared = await transcript.transcript.prepareRows(batch.map(\.described))

        XCTAssertEqual(prepared.count, 1, "a .view row has nothing this package can measure")
        XCTAssertNil(firstLine(of: batch[0].id, in: prepared))
        XCTAssertNotNil(firstLine(of: batch[1].id, in: prepared))

        host.rows.insert(contentsOf: batch, at: 0)
        transcript.transcript.insertRows(at: IndexSet(0..<2), warming: prepared)
        transcript.settle()

        XCTAssertEqual(
            transcript.transcript.rect(ofRow: 0).height, SourceHost.hostRowHeight + Self.rowSpacing,
            "the .view row's height did not come from the delegate")
    }

    /// `NSTableView` centres the cell in a row rect this much taller; see
    /// `TranscriptView.rowSpacing`. Written here rather than derived so that the
    /// assertion above says what it means.
    private static let rowSpacing: CGFloat = 14

    // MARK: - What the identity keeps bounded

    /// A reload after a reorder re-measures nothing.
    ///
    /// The positional cache could not do this: `reloadData()` discarded every
    /// entry, because row *n* meant something new and there was no way to say
    /// which. Filed under identity there is nothing to discard — the rows are the
    /// same rows.
    func testAReloadAfterAReorderReMeasuresNothing() {
        let (transcript, host) = mount(Array(Self.sources.prefix(3)))
        XCTAssertFalse(host.rowCalls.isEmpty, "the transcript never laid out")

        let before = (0..<3).map { firstLine(ofRow: $0, in: transcript) }
        XCTAssertNotNil(before[0], "nothing was typeset")
        // The premise: the three rows really are distinguishable by this read.
        XCTAssertNotIdentical(before[0], before[2])

        host.rows.reverse()
        transcript.transcript.reloadData()
        transcript.settle()

        XCTAssertIdentical(
            firstLine(ofRow: 0, in: transcript), before[2],
            "a reordered row was typeset again, though it is the same row")
        XCTAssertIdentical(firstLine(ofRow: 2, in: transcript), before[0])
    }

    /// A row that leaves takes its measurement with it.
    ///
    /// The other half of the trade above: a dictionary does not shrink on its
    /// own, so `removeRows` sweeps. Observed by bringing the same row back — same
    /// identity, same source — and checking it has to be typeset again. If the
    /// sweep had not run, the entry would still be there and this would be a
    /// cache hit.
    func testARemovedRowIsSweptFromTheCache() {
        let (transcript, host) = mount(Array(Self.sources.prefix(2)))
        XCTAssertFalse(host.rowCalls.isEmpty, "the transcript never laid out")

        let departing = host.rows[0]
        let before = firstLine(ofRow: 0, in: transcript)
        XCTAssertNotNil(before, "nothing was typeset")

        host.rows.remove(at: 0)
        transcript.transcript.removeRows(at: IndexSet(integer: 0))
        transcript.settle()

        host.rows.insert(departing, at: 0)
        transcript.transcript.insertRows(at: IndexSet(integer: 0))
        transcript.settle()

        let after = firstLine(ofRow: 0, in: transcript)
        XCTAssertNotNil(after, "the row came back without being typeset at all")
        XCTAssertNotIdentical(
            after, before,
            "the measurement of a removed row was still in the cache, so nothing bounds it")
    }

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
        XCTAssertFalse(controlHost.rowCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.rowCalls.isEmpty, "the subject never laid out")

        let batch = Array(Self.sources.dropFirst()).map(SourceHost.Row.init)
        // Measured at 600 …
        let prepared = await subject.transcript.prepareRows(batch.map(\.described))
        let heightsAt600 = batch.compactMap {
            TranscriptRowContent.markdown($0.source).entry(width: 600)?.measured.size.height
        }
        // … and inserted at 420.
        subject.setContentWidth(420)
        subject.settle()

        controlHost.rows.insert(contentsOf: batch, at: 0)
        control.transcript.insertRows(at: IndexSet(0..<batch.count))
        control.settle()

        subjectHost.rows.insert(contentsOf: batch, at: 0)
        subject.transcript.insertRows(at: IndexSet(0..<batch.count), warming: prepared)
        subject.settle()

        let heightsAt420 = batch.compactMap {
            TranscriptRowContent.markdown($0.source).entry(width: 420)?.measured.size.height
        }
        XCTAssertEqual(heightsAt600.count, batch.count)
        for (index, pair) in zip(heightsAt600, heightsAt420).enumerated() {
            XCTAssertNotEqual(
                pair.0, pair.1,
                "document \(index) measures the same at both widths, so it cannot detect a stale one")
        }

        XCTAssertEqual(rects(subject.transcript), rects(control.transcript))
    }

    /// A measurement for a row that never arrives is simply never found.
    ///
    /// The positional version of this was a host that mutated across the `await`
    /// and so filed a batch onto rows it was not measured for; the landing site
    /// had to compare content per row to catch it. There is no such situation
    /// left — a measurement is filed under an identity, and an identity nothing
    /// asks about is inert. What it costs is the background work, which is the
    /// claim being pinned here.
    func testAMeasurementForARowThatNeverArrivesIsInert() async {
        let (control, controlHost) = mount([Self.sources[0]])
        let (subject, subjectHost) = mount([Self.sources[0]])
        XCTAssertFalse(controlHost.rowCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.rowCalls.isEmpty, "the subject never laid out")

        // Prepared for one row …
        let prepared = await subject.transcript.prepareRows(
            [SourceHost.Row(Self.sources[1]).described])
        // … and a different row is what actually arrives.
        let arriving = SourceHost.Row(Self.sources[3])

        controlHost.rows.insert(arriving, at: 0)
        control.transcript.insertRows(at: IndexSet(integer: 0))
        control.settle()

        subjectHost.rows.insert(arriving, at: 0)
        subject.transcript.insertRows(at: IndexSet(integer: 0), warming: prepared)
        subject.settle()

        XCTAssertEqual(
            rects(subject.transcript), rects(control.transcript),
            "the row rendered at the height of the document that was prepared, not the one present")
    }

    // MARK: - Everything else about the insert is unchanged

    /// Scroll anchoring does not know a prepared insert from a plain one, and
    /// this is what says so: the same prepend, from the same offset, lands on the
    /// same offset. Rule 2 covers it because it is the same code path — which is
    /// the property that would break if warming ever moved outside `mutate`.
    func testAPreparedPrependHoldsTheViewportLikeAPlainOne() async {
        let filler = (0..<12).map { "Row \($0)\n\n\(Self.sources[1])" }
        let (control, controlHost) = mount(filler)
        let (subject, subjectHost) = mount(filler)
        XCTAssertFalse(controlHost.rowCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.rowCalls.isEmpty, "the subject never laid out")

        // Away from the tail, where holding still is the rule that applies.
        control.scroll(toY: 300)
        subject.scroll(toY: 300)
        control.settle()
        subject.settle()
        XCTAssertEqual(subject.scrollView.contentView.bounds.minY, 300, accuracy: 1)

        let batch = Self.sources.map(SourceHost.Row.init)
        let prepared = await subject.transcript.prepareRows(batch.map(\.described))

        controlHost.rows.insert(contentsOf: batch, at: 0)
        control.transcript.insertRows(at: IndexSet(0..<batch.count))
        control.settle()

        subjectHost.rows.insert(contentsOf: batch, at: 0)
        subject.transcript.insertRows(at: IndexSet(0..<batch.count), warming: prepared)
        subject.settle()

        XCTAssertEqual(
            subject.scrollView.contentView.bounds.minY,
            control.scrollView.contentView.bounds.minY, accuracy: 0.5)
        XCTAssertGreaterThan(
            subject.scrollView.contentView.bounds.minY, 300,
            "nothing was prepended above the viewport, so the test proved nothing")
    }

    /// Cancelling stops the work rather than only discarding it, so what comes
    /// back covers fewer rows than were asked for — which is a state the merge
    /// already handles, and not one a host has to.
    func testCancellationYieldsABatchTheInsertStillTolerates() async {
        let (transcript, host) = mount([Self.sources[0]])
        XCTAssertFalse(host.rowCalls.isEmpty, "the transcript never laid out")

        let batch = Self.sources.map(SourceHost.Row.init)
        let task = Task { await transcript.transcript.prepareRows(batch.map(\.described)) }
        task.cancel()
        let prepared = await task.value

        // A row that was never measured is simply absent, and absence is how it
        // says "measure me yourself".
        XCTAssertLessThanOrEqual(prepared.count, batch.count)

        host.rows.insert(contentsOf: batch, at: 0)
        transcript.transcript.insertRows(at: IndexSet(0..<batch.count), warming: prepared)
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

    /// One row: a source, and the identity its measurement is filed under.
    ///
    /// A test builds these **before** it prepares anything, which is the order a
    /// real host works in and the reason the type exists: the identity has to be
    /// decided before the measurement can be made for it, and the same value has
    /// to reach both `prepareRows(_:)` and the data source. Handing the batch
    /// around as `[Row]` is what makes that hard to get wrong here.
    struct Row {
        let id = UUID()

        /// Mutable, and only for the one test that needs a row whose *content*
        /// moved while its identity did not — which is what a stream is.
        var source: String

        init(_ source: String) { self.source = source }

        var described: TranscriptRow {
            TranscriptRow(id: id, content: SourceHost.content(for: source))
        }
    }

    /// A source that means `.view` instead of a document. A sentinel rather than
    /// a second array, so a test's `insert(at:)` stays the one call a real host
    /// would make.
    static let hostDrawn = "\u{0}host-drawn"

    /// Prefix marking a source as a user's turn rather than a document — the
    /// other case the transcript draws itself, and the one whose recipe is named
    /// in two places (`TranscriptRowContent.entry(width:)` and the `build`
    /// closure in `TranscriptView.measuredBlock(for:)`). A suite of `.markdown`
    /// rows alone cannot see those two drift apart.
    static let userTurnPrefix = "\u{1}"

    static let hostRowHeight: CGFloat = 77

    var rows: [Row]

    /// Which rows were asked about, in order — the evidence that the transcript
    /// was provoked at all. Every test opens on it, because a mount that silently
    /// never lays out makes every later assertion pass against an empty tree.
    private(set) var rowCalls: [Int] = []

    init(sources: [String]) {
        rows = sources.map(Row.init)
        super.init()
    }

    func numberOfRows(in transcriptView: TranscriptView) -> Int { rows.count }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        rowCalls.append(row)
        return rows[row].described
    }

    /// The mapping, as a `static` so a test can build the batch it hands to
    /// `prepareRows(_:)` through the **same** function the data source answers
    /// from. A test that spelled the mapping a second time would be free to
    /// prepare a document for a row this host serves as a bubble — which is a
    /// host bug worth having a test of its own
    /// (`testAMeasurementPreparedAsTheWrongCaseIsNotUsed`), not one to reproduce
    /// by accident in every other test in the file.
    nonisolated static func content(for source: String) -> TranscriptRowContent {
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

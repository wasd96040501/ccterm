import AppKit
import XCTest

@testable import TranscriptKit

/// A width change re-measures the rows off screen **off the main actor**, and
/// publishes them in one pass when they are all in.
///
/// The rest of the suite never sees this: its transcripts fit in their windows,
/// so every row is visible, and visible rows are re-measured synchronously by the
/// pass that changed the width. Everything here therefore starts by putting rows
/// off screen and checking they really are — a transcript that fits would make
/// every assertion below pass against a purely synchronous implementation.
///
/// **What is asserted is the window, not the speed.** That the work happens
/// somewhere else is read as "the correction has not landed yet, and lands
/// later"; timing would be asserting the machine. What the window *looks* like —
/// whether a row scrolled into during it reads as wrong — is `make demo-kit`'s,
/// on ten thousand rows.
///
/// **Two of the mechanism's parts are deliberately not covered, because nothing
/// can cover them.** Deleting the merge, or letting a superseded batch publish,
/// leaves this file green — the transcript stays correct either way, since
/// `noteHeightOfRows` makes the table re-ask and `RowCache` rejects anything
/// stale on read. What those parts buy is that the re-asking is answered from
/// cache instead of by measuring the working set on the main thread, which is a
/// difference only a measurement can see (§6 has it). Tried, so that nobody
/// re-derives it: breaks that stay green here are `finishRemeasuring`'s width
/// guard, its merge, the cancellation of a superseded batch, and the content
/// comparison inside `RowCache.merge(remeasured:at:)`.
@MainActor
final class ResizeRemeasureTests: XCTestCase {

    private var mounted: [MountedTranscript] = []

    override func tearDown() {
        mounted.forEach { $0.teardown() }
        mounted = []
        super.tearDown()
    }

    /// Long enough to wrap differently at the two widths these tests use, which
    /// every assertion here depends on and `testTheTwoWidthsDiffer` states.
    private static func document(_ index: Int) -> String {
        """
        ## Section \(index)

        A paragraph long enough that where it breaks depends on how wide the
        column is, which is the whole of what a width change has to correct, and
        therefore the whole of what these rows have to be able to show. Item
        \(index).

        - one, with a clause after it so the item wraps at a narrow measure
        - two, likewise, because a list of single words reflows identically
        """
    }

    private static let rowCount = 40
    private static let wide: CGFloat = 700
    private static let narrow: CGFloat = 430

    /// A transcript whose content is far taller than its window, walked end to end
    /// so the table has really measured the rows that are about to go stale.
    private func mount(width: CGFloat) -> (MountedTranscript, ResizeHost) {
        let host = ResizeHost(sources: (0..<Self.rowCount).map(Self.document))
        let transcript = MountedTranscript(size: NSSize(width: width, height: 300))
        mounted.append(transcript)
        transcript.transcript.dataSource = host
        transcript.transcript.delegate = host
        transcript.settle()
        transcript.transcript.reloadData()
        transcript.settle()
        // Walk to the end and back, so rows outside the first screen have real
        // heights rather than the table's extrapolation — an unmeasured row is
        // asked about on the spot and is not what this file is about.
        transcript.transcript.scrollToRow(at: Self.rowCount - 1, scrollPosition: .bottom)
        transcript.settle()
        transcript.transcript.scrollToRow(at: 0, scrollPosition: .top)
        transcript.settle()
        return (transcript, host)
    }

    private func rects(_ transcript: TranscriptView) -> [NSRect] {
        (0..<transcript.numberOfRows).map { transcript.rect(ofRow: $0) }
    }

    private func isOffscreen(row: Int, in transcript: MountedTranscript) -> Bool {
        !transcript.scrollView.documentVisibleRect.intersects(transcript.transcript.rect(ofRow: row))
    }

    /// The premise every other test here rests on.
    func testTheTwoWidthsDiffer() {
        let (wide, wideHost) = mount(width: Self.wide)
        let (narrow, narrowHost) = mount(width: Self.narrow)
        XCTAssertFalse(wideHost.rowCalls.isEmpty, "the wide transcript never laid out")
        XCTAssertFalse(narrowHost.rowCalls.isEmpty, "the narrow transcript never laid out")

        XCTAssertNotEqual(
            wide.transcript.rect(ofRow: 0).height, narrow.transcript.rect(ofRow: 0).height,
            "these two widths lay a row out identically, so nothing here can detect a stale one")
    }

    // MARK: - The window

    /// The rows on screen are correct immediately; the rows off screen are
    /// corrected on a later turn.
    ///
    /// Both halves in one test on purpose — either alone would be satisfied by an
    /// implementation that is entirely synchronous or entirely deferred, and the
    /// point is the split.
    func testOffscreenRowsAreCorrectedOnALaterTurn() async {
        let (control, controlHost) = mount(width: Self.narrow)
        let (subject, subjectHost) = mount(width: Self.wide)
        XCTAssertFalse(controlHost.rowCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.rowCalls.isEmpty, "the subject never laid out")

        let offscreen = Self.rowCount - 1
        XCTAssertTrue(
            isOffscreen(row: offscreen, in: subject), "row \(offscreen) is on screen after all")
        let staleRect = subject.transcript.rect(ofRow: offscreen)

        subject.setContentWidth(Self.narrow)
        subject.settle()

        // Provocation: the batch was actually started. Without this the two
        // assertions below could both hold because nothing happened at all.
        XCTAssertNotNil(subject.transcript.remeasuring, "no re-measure was started")

        XCTAssertEqual(
            subject.transcript.rect(ofRow: 0).height, control.transcript.rect(ofRow: 0).height,
            accuracy: 0.5,
            "the row on screen was not corrected inside the pass that changed the width")
        XCTAssertEqual(
            subject.transcript.rect(ofRow: offscreen).height, staleRect.height, accuracy: 0.001,
            "the off-screen rows were re-measured on the main thread after all")

        await subject.settleWidthChange()

        XCTAssertEqual(rects(subject.transcript), rects(control.transcript))
    }

    /// A second width change while the first is in flight wins.
    ///
    /// The first batch describes a layout nobody is asking for by the time it
    /// lands, and publishing it would be a transcript briefly laid out at a width
    /// it does not have.
    func testASecondWidthChangeSupersedesTheFirst() async {
        let (control, controlHost) = mount(width: Self.narrow)
        let (subject, subjectHost) = mount(width: Self.wide)
        XCTAssertFalse(controlHost.rowCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.rowCalls.isEmpty, "the subject never laid out")

        subject.setContentWidth(560)
        XCTAssertNotNil(subject.transcript.remeasuring, "no first re-measure was started")
        subject.setContentWidth(Self.narrow)

        await subject.settleWidthChange()

        XCTAssertEqual(rects(subject.transcript), rects(control.transcript))
    }

    /// The host may do anything while the batch is in flight.
    ///
    /// Announced content changes are the interesting case: the batch was measured
    /// from text that has since moved.
    ///
    /// What makes the result right is the comparison every *read* performs, not
    /// the one in `RowCache.merge(remeasured:at:)` — deleting that one leaves this
    /// test green, because the entry it then files is rejected the first time
    /// anything asks about the row. Which is worth knowing here rather than
    /// somewhere else: this test looks like it is covering the merge's check and
    /// is not. It covers the outcome, and the outcome has two defences.
    func testAContentChangeDuringTheWindowIsNotOverwritten() async {
        let replacement = "# Replaced\n\nA different document entirely, and a much shorter one."
        let (control, controlHost) = mount(width: Self.narrow)
        let (subject, subjectHost) = mount(width: Self.wide)
        XCTAssertFalse(controlHost.rowCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.rowCalls.isEmpty, "the subject never laid out")

        let changed = Self.rowCount - 1
        subject.setContentWidth(Self.narrow)
        // No `settle()` between, so the main actor has not yielded and the batch
        // provably cannot have landed yet.
        XCTAssertNotNil(subject.transcript.remeasuring, "no re-measure was started")

        subjectHost.sources[changed] = replacement
        subject.transcript.reloadRows(at: IndexSet(integer: changed))

        controlHost.sources[changed] = replacement
        control.transcript.reloadRows(at: IndexSet(integer: changed))
        control.settle()

        await subject.settleWidthChange()

        XCTAssertEqual(
            subject.transcript.rect(ofRow: changed).height,
            control.transcript.rect(ofRow: changed).height, accuracy: 0.5,
            "the row kept the height of the document it held when the batch was measured")
        XCTAssertEqual(rects(subject.transcript), rects(control.transcript))
    }

    /// Rows removed while the batch is in flight take their answers with them, and
    /// what is left is still right.
    func testARemovalDuringTheWindowLandsCorrectly() async {
        let (control, controlHost) = mount(width: Self.narrow)
        let (subject, subjectHost) = mount(width: Self.wide)
        XCTAssertFalse(controlHost.rowCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.rowCalls.isEmpty, "the subject never laid out")

        subject.setContentWidth(Self.narrow)
        XCTAssertNotNil(subject.transcript.remeasuring, "no re-measure was started")

        subjectHost.sources.removeFirst(3)
        subject.transcript.removeRows(at: IndexSet(0..<3))
        controlHost.sources.removeFirst(3)
        control.transcript.removeRows(at: IndexSet(0..<3))
        control.settle()

        await subject.settleWidthChange()

        XCTAssertEqual(subject.transcript.numberOfRows, Self.rowCount - 3)
        XCTAssertEqual(rects(subject.transcript), rects(control.transcript))
    }
}

/// Markdown rows a test can rewrite and renumber, with identities that survive
/// both.
@MainActor
private final class ResizeHost: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {

    private struct Row {
        let id = UUID()
        var source: String
    }

    private var rows: [Row]

    private(set) var rowCalls: [Int] = []

    /// The sources, as a test edits them — the identities underneath stay put,
    /// which is what a real host owes and what makes a rewrite a content change
    /// rather than a different row.
    var sources: [String] {
        get { rows.map(\.source) }
        set {
            for (index, source) in newValue.enumerated() where index < rows.count {
                rows[index].source = source
            }
            if newValue.count < rows.count { rows.removeLast(rows.count - newValue.count) }
        }
    }

    init(sources: [String]) {
        rows = sources.map { Row(source: $0) }
        super.init()
    }

    func numberOfRows(in transcriptView: TranscriptView) -> Int { rows.count }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        rowCalls.append(row)
        return TranscriptRow(id: rows[row].id, content: .markdown(rows[row].source))
    }
}

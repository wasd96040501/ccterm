import AppKit
import XCTest

@testable import TranscriptKit

/// A width change re-measures the rows off screen **off the main actor**, into
/// `RowCache`, while the list refreshes them on idle turns (ExactList W5) and
/// finds each answer already there.
///
/// The rest of the suite never sees this: its transcripts fit in their windows,
/// so every row is on screen, and the list re-measures those inside the pass
/// that changed the width (W3). Everything here therefore starts by putting rows
/// off screen and checking they really are.
///
/// **What is asserted is the window, not the speed.** That the work happens
/// somewhere else is read as "the correction has not landed yet, and lands
/// later"; timing would be asserting the machine. What it buys — the list's idle
/// questions answered by a lookup rather than by typesetting on the main thread —
/// is `make demo-kit`'s, on ten thousand rows.
///
/// **Several of the mechanism's parts are deliberately not covered, because
/// nothing can cover them.** The transcript is correct without any of them: the
/// list asks every stale row again, and `RowCache` rejects anything stale on
/// read. Breaks that stay green here are the merge's width guard, the
/// cancellation of a superseded run, the content comparison inside
/// `RowCache.merge(remeasured:at:)`, and queueing every row into the task group at
/// once instead of a core count at a time (`inFlightLimit` has the measurement).
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

    /// A transcript whose content is far taller than its window, read from the
    /// top. The list measured every row when it loaded (ExactList G2), so every
    /// row off screen is one the width change leaves stale.
    private func mount(width: CGFloat) -> (MountedTranscript, ResizeHost) {
        let host = ResizeHost(sources: (0..<Self.rowCount).map(Self.document))
        let transcript = MountedTranscript(size: NSSize(width: width, height: 300))
        mounted.append(transcript)
        transcript.transcript.dataSource = host
        transcript.transcript.delegate = host
        transcript.settle()
        transcript.transcript.reloadData()
        transcript.settle()
        // A transcript loads at its tail.
        transcript.transcript.scrollToRow(at: 0, scrollPosition: .top)
        transcript.settle()
        return (transcript, host)
    }

    private func rects(_ transcript: MountedTranscript) -> [NSRect] {
        (0..<transcript.transcript.numberOfRows).map { transcript.documentRect(ofRow: $0) }
    }

    private func isOffscreen(row: Int, in transcript: MountedTranscript) -> Bool {
        !transcript.scrollView.documentVisibleRect.intersects(transcript.documentRect(ofRow: row))
    }

    /// The re-measure's walks among everything the data source was asked: each
    /// run of calls that asks every row once. Nothing else does — the list asks
    /// for the rows it places, and on idle turns only for the rows still stale,
    /// never one it has measured at this width (ExactList W6).
    private func walks(in calls: [Int]) -> [[Int]] {
        guard calls.count >= Self.rowCount else { return [] }
        let every = Array(0..<Self.rowCount)
        return (0...(calls.count - Self.rowCount)).map { Array(calls[$0..<$0 + Self.rowCount]) }
            .filter { $0.sorted() == every }
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

    /// A width change that is not a drag — an editor opening beside this one, a
    /// zoom — puts the rows on screen at their new heights at once. Animated, the
    /// row views slide into place over a fifth of a second while the glyphs are
    /// already laid out for the new width, which reads as the text being squashed.
    func testAWidthChangeOutsideADragDoesNotAnimateTheRows() throws {
        let (subject, host) = mount(width: Self.wide)
        XCTAssertFalse(host.rowCalls.isEmpty, "the transcript never laid out")
        let before = subject.transcript.rect(ofRow: 0).height

        subject.setContentWidth(Self.narrow)
        subject.settle()

        XCTAssertNotEqual(
            subject.transcript.rect(ofRow: 0).height, before, "premise: the rows changed height")
        // A row in motion stands between where it was and where its row is, so
        // every cell standing exactly on some row's rect is a list at rest.
        let document = try XCTUnwrap(subject.scrollView.documentView)
        let rows = Set((0..<subject.transcript.numberOfRows).map { subject.documentRect(ofRow: $0) })
        let cells = subject.transcript.descendants(ofType: TranscriptCellView.self)
        XCTAssertFalse(cells.isEmpty, "premise: there are rows on screen")
        let moving = cells.map { $0.convert($0.bounds, to: document) }.filter { !rows.contains($0) }
        XCTAssertEqual(moving, [], "rows animating into place")
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
        let staleRect = subject.documentRect(ofRow: offscreen)

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
            subject.documentRect(ofRow: offscreen).height, staleRect.height, accuracy: 0.001,
            "the off-screen rows were re-measured inside the pass after all")

        await subject.settleWidthChange()

        XCTAssertEqual(rects(subject), rects(control))
    }

    /// A second width change while the first is in flight wins.
    ///
    /// The first run measures for a width nobody is asking for by the time it
    /// lands; what the transcript ends up with is the second width's layout.
    func testASecondWidthChangeSupersedesTheFirst() async {
        let (control, controlHost) = mount(width: Self.narrow)
        let (subject, subjectHost) = mount(width: Self.wide)
        XCTAssertFalse(controlHost.rowCalls.isEmpty, "the control never laid out")
        XCTAssertFalse(subjectHost.rowCalls.isEmpty, "the subject never laid out")
        await subject.settleWidthChange()
        subjectHost.forgetRowCalls()

        subject.setContentWidth(560)
        XCTAssertNotNil(subject.transcript.remeasuring, "no first re-measure was started")
        subject.setContentWidth(Self.narrow)

        await subject.settleWidthChange()

        XCTAssertEqual(rects(subject), rects(control))
        // The superseded run never took its first turn, so it walked nothing —
        // a walk is a data-source call per row on the main actor.
        XCTAssertEqual(walks(in: subjectHost.rowCalls).count, 1, "the superseded run walked the rows too")
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
        XCTAssertEqual(rects(subject), rects(control))
    }

    // MARK: - Where it starts, and what it does to the viewport

    /// The rows are re-measured outward from what the reader is looking at —
    /// the order the list's idle turns will ask for them in.
    ///
    /// Read off the order the data source was asked in, which is what the walk
    /// does and the only trace it leaves: it asks each row who it is until it has
    /// claimed every stale entry, in one run, and the order of that run is the
    /// order the rows are measured in.
    ///
    /// **From the tail**, so that "starts at the viewport" and "starts at row 0"
    /// are different answers — the walk then runs down to row 0 with one side
    /// exhausted from the outset. `testTheWalkInterleavesBothSides` is the other
    /// half, where both sides have rows.
    func testTheWalkStartsAtTheViewportAndWorksOutward() async throws {
        let (subject, host) = mount(width: Self.wide)
        XCTAssertFalse(host.rowCalls.isEmpty, "the subject never laid out")

        subject.transcript.scrollToRow(at: Self.rowCount - 1, scrollPosition: .bottom)
        subject.settle()
        host.forgetRowCalls()

        subject.setContentWidth(Self.narrow)
        subject.settle()
        XCTAssertNotNil(subject.transcript.remeasuring, "no re-measure was started")
        await subject.settleWidthChange()

        // Every row exactly once — a walk that dropped rows would leave them to
        // the list, measured one main-thread row at a time.
        let walks = walks(in: host.rowCalls)
        XCTAssertEqual(walks.count, 1, "not one walk that covers every row: \(host.rowCalls)")
        let walk = try XCTUnwrap(walks.first)

        let first = walk[0]
        XCTAssertGreaterThan(first, 0, "the walk started at the top, not at the viewport")
        XCTAssertEqual(
            walk, Array(first..<Self.rowCount) + Array((0..<first).reversed()),
            "the walk did not run outward from the viewport")
    }

    /// With rows on both sides of the viewport, the walk alternates between them
    /// rather than finishing one side first.
    ///
    /// Asserted as "it goes above the viewport before it reaches the last row",
    /// which is the cheapest thing that a one-side-at-a-time walk cannot do. The
    /// obvious assertion — that distance from the viewport never decreases — is
    /// worse than useless here: it needs the viewport, and inferring that from the
    /// walk itself makes a walk that ran to the end and came back look like a very
    /// wide viewport followed by one side. Tried, and it passed against exactly the
    /// bug it was written for.
    func testTheWalkInterleavesBothSides() async throws {
        let (subject, host) = mount(width: Self.wide)
        XCTAssertFalse(host.rowCalls.isEmpty, "the subject never laid out")

        subject.transcript.scrollToRow(at: Self.rowCount / 2, scrollPosition: .center)
        subject.settle()
        host.forgetRowCalls()

        subject.setContentWidth(Self.narrow)
        subject.settle()
        XCTAssertNotNil(subject.transcript.remeasuring, "no re-measure was started")
        await subject.settleWidthChange()

        let walks = walks(in: host.rowCalls)
        XCTAssertEqual(walks.count, 1, "not one walk that covers every row: \(host.rowCalls)")
        let walk = try XCTUnwrap(walks.first)
        // The rows on screen come first, so this is the topmost of them — and
        // anything below it in the walk is a row above the viewport.
        let firstVisible = walk[0]
        XCTAssertGreaterThan(firstVisible, 0, "the walk started at the top, not at the viewport")
        XCTAssertLessThan(
            firstVisible, Self.rowCount - 1,
            "the viewport reached the tail, so only one side has rows")

        let goesAbove = walk.firstIndex { $0 < firstVisible }
        let reachesTheEnd = walk.firstIndex(of: Self.rowCount - 1)
        XCTAssertNotNil(goesAbove)
        XCTAssertNotNil(reachesTheEnd)
        XCTAssertLessThan(
            goesAbove ?? .max, reachesTheEnd ?? .max,
            "the walk finished one side before starting the other: \(walk)")
    }

    /// A correction landing on a later turn does not move what the reader is
    /// looking at.
    ///
    /// The synchronous half of a width change cannot anchor — §2 says why — so the
    /// content does settle somewhere new when the width moves. What must not happen
    /// is that it settles *again* every time a batch of off-screen rows comes in,
    /// which is what the reader would meet as the page stepping under them while
    /// they read.
    func testTheDeferredCorrectionsHoldTheViewportStill() async {
        let (subject, host) = mount(width: Self.wide)
        XCTAssertFalse(host.rowCalls.isEmpty, "the subject never laid out")

        // Mid-transcript, so there are stale rows *above* the viewport — the ones
        // whose heights move the content. At the tail there would be none.
        subject.transcript.scrollToRow(at: Self.rowCount / 2, scrollPosition: .center)
        subject.settle()

        subject.setContentWidth(Self.narrow)
        subject.settle()
        let settled = viewport(of: subject)

        await subject.settleWidthChange()

        let corrected = viewport(of: subject)
        XCTAssertEqual(corrected.row, settled.row, "the viewport landed on a different row")
        XCTAssertEqual(
            corrected.offsetIntoRow, settled.offsetIntoRow, accuracy: 0.5,
            "the viewport moved within the row it was on")
    }

    /// Which row the viewport starts on, and how far into it — `sampledAnchor()`'s
    /// question, asked from outside through the geometry AppKit publishes.
    private func viewport(of transcript: MountedTranscript) -> (row: Int, offsetIntoRow: CGFloat) {
        let visible = transcript.scrollView.documentVisibleRect
        for row in 0..<transcript.transcript.numberOfRows {
            let rect = transcript.documentRect(ofRow: row)
            guard rect.maxY > visible.minY else { continue }
            return (row, visible.minY - rect.minY)
        }
        return (transcript.transcript.numberOfRows - 1, 0)
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
        XCTAssertEqual(rects(subject), rects(control))
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

    /// Drops what has been recorded so far, so that a test can read one pass's
    /// calls rather than every pass since it mounted.
    func forgetRowCalls() { rowCalls = [] }

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

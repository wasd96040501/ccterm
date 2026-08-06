import AppKit
import CoreText
import XCTest

@testable import TranscriptKit

/// A markdown row whose source grows under it — the streaming case, driven the
/// way a host drives it: change the model, then `reloadRows(at:)`.
///
/// Three things are worth asserting and none of them is "does it look right".
/// That the answer does not depend on how the row got there; that the blocks
/// which did not change were not laid out a second time; and that a reader's
/// selection in the row survives the row growing under it.
///
/// **How reuse is observed.** A `CTLine` is a reference type produced by
/// typesetting, and an `NSAttributedString` a reference type produced by
/// shaping — so the same instance coming back out means that work did not happen
/// again. Both are ordinary production state reached through `@testable`, not a
/// counter added for the test to read: §5's rule is that a test drives the public
/// surface and asserts on observable output, and this is the observable output of
/// "was anything re-typeset".
@MainActor
final class MarkdownGrowthTests: XCTestCase {

    private var mounted: MountedTranscript!
    private var host: GrowingHost!

    /// Three top-level blocks, so there is something above the one that grows.
    private static let opening = """
        # Heading

        A settled paragraph that nothing in this test touches.

        A second paragraph, which is the one that grows.
        """

    override func tearDown() {
        mounted?.teardown()
        mounted = nil
        host = nil
        super.tearDown()
    }

    @discardableResult
    private func mount(_ sources: [String], width: CGFloat = 600) -> GrowingHost {
        let host = GrowingHost(sources: sources)
        self.host = host
        mounted = MountedTranscript(size: NSSize(width: width, height: 400))
        mounted.transcript.dataSource = host
        mounted.settle()
        mounted.transcript.reloadData()
        mounted.settle()
        return host
    }

    /// Change the model and announce it, which is the whole of what a streaming
    /// host does.
    private func grow(_ row: Int, by text: String) {
        host.sources[row] += text
        mounted.transcript.reloadRows(at: IndexSet(integer: row))
        mounted.settle()
    }

    // MARK: - Reaching into the row

    private func blockView(ofRow row: Int) -> BlockView? {
        mounted.transcript.descendants(ofType: BlockView.self)
            .first { mounted.transcript.row(for: $0) == row }
    }

    /// The Core Text line child `child` of row `row` is typeset into, and the
    /// attributed string it was shaped from.
    private func typeset(row: Int, child: Int) -> (line: CTLine, shaped: NSAttributedString)? {
        guard let stack = blockView(ofRow: row)?.block as? BlockStack.Measured,
            child < stack.children.count,
            let text = stack.children[child].block as? MeasuredTextBlock,
            let line = text.text.lines.first
        else { return nil }
        return (line.ctLine, text.text.attributed)
    }

    // MARK: - The answer does not depend on how the row got there

    /// Reuse is only ever an optimisation, so the tree a grown row ends up with
    /// has to be the tree it would have had if the whole source had arrived at
    /// once. Height and copied text between them cover geometry and index space.
    func testAGrownRowMatchesOneBuiltOutright() {
        let tail = "\n\nAnd a third paragraph, arriving late."
        mount([Self.opening, Self.opening + tail])

        // The provocation check: a mount that never laid out would leave both
        // rows at zero and make the comparison below vacuous.
        XCTAssertGreaterThan(mounted.transcript.rect(ofRow: 0).height, 0)

        grow(0, by: tail)

        XCTAssertEqual(
            mounted.transcript.rect(ofRow: 0).height, mounted.transcript.rect(ofRow: 1).height)

        let grown = blockView(ofRow: 0)?.block
        let outright = blockView(ofRow: 1)?.block
        XCTAssertEqual(grown?.length, outright?.length)
        XCTAssertEqual(
            grown?.text(from: 0, to: grown?.length ?? 0),
            outright?.text(from: 0, to: outright?.length ?? 0))
    }

    // MARK: - Only what changed is laid out again

    /// The heading and the settled paragraph above the growing one keep the
    /// exact lines they were typeset into; the one that grew does not.
    func testGrowingARowLaysOutOnlyTheBlockThatChanged() {
        mount([Self.opening])
        let view = blockView(ofRow: 0)
        XCTAssertNotNil(view)

        let heading = typeset(row: 0, child: 0)
        let settled = typeset(row: 0, child: 1)
        let growing = typeset(row: 0, child: 2)
        XCTAssertNotNil(growing)

        grow(0, by: " It just got longer.")

        XCTAssertTrue(heading?.line === typeset(row: 0, child: 0)?.line)
        XCTAssertTrue(settled?.line === typeset(row: 0, child: 1)?.line)
        XCTAssertFalse(growing?.line === typeset(row: 0, child: 2)?.line)

        // And the view itself was never rebuilt — which is the other half of what
        // keeps a selection in it alive.
        XCTAssertTrue(view === blockView(ofRow: 0))
    }

    /// A host announcing a row it did not actually change — a frame ticker firing
    /// while nothing arrived — lays nothing out.
    ///
    /// A property rather than one mechanism, and deliberately: `RowCache` answers
    /// this without parsing and `MarkdownMemo` answers it again after parsing, so
    /// removing either alone leaves this green and removing both turns it red.
    /// What a host relies on is the property; the two guards are how far apart
    /// this package has decided to place the free case.
    func testReloadingAnUnchangedRowLaysOutNothing() {
        mount([Self.opening])
        let before = (0..<3).map { typeset(row: 0, child: $0)?.line }
        XCTAssertEqual(before.compactMap { $0 }.count, 3)

        mounted.transcript.reloadRows(at: IndexSet(integer: 0))
        mounted.settle()

        for child in 0..<3 {
            XCTAssertTrue(before[child] === typeset(row: 0, child: child)?.line)
        }
    }

    /// The other axis, and the one that was already there: a width change
    /// re-breaks lines without re-shaping a glyph. Asserted here because growth
    /// and resize now share one store, and it is the reuse that is easiest to
    /// lose while adding the other.
    func testAWidthChangeReTypesetsWithoutReshaping() {
        mount([Self.opening], width: 700)
        let before = typeset(row: 0, child: 1)
        XCTAssertNotNil(before)

        mounted.setContentWidth(320)
        mounted.settle()

        let after = typeset(row: 0, child: 1)
        XCTAssertTrue(before?.shaped === after?.shaped)
        XCTAssertFalse(before?.line === after?.line)
    }

    // MARK: - Selection

    /// A reader selecting text in a row that is still streaming keeps it. The
    /// blocks before the divergence parse the same, so the endpoints still name
    /// the characters they named.
    func testGrowingARowKeepsTheSelectionInIt() {
        mount([Self.opening])
        guard let view = blockView(ofRow: 0) else { return XCTFail("no row to select in") }

        sweep(view, atY: 4)
        let selected = copiedText(view)
        XCTAssertEqual(selected, "Heading")

        grow(0, by: " It just got longer.")

        XCTAssertEqual(copiedText(view), selected)
    }

    /// The other branch, and the reason the first one cannot simply always
    /// apply: a row handed a document that is not an extension of the one it was
    /// showing is a different document, and a highlight left over it would be a
    /// selection over words the reader never dragged across.
    func testReplacingARowsDocumentDropsTheSelection() {
        mount([Self.opening])
        guard let view = blockView(ofRow: 0) else { return XCTFail("no row to select in") }

        sweep(view, atY: 4)
        XCTAssertEqual(copiedText(view), "Heading")

        host.sources[0] = "# Something else entirely\n\nWith nothing in common."
        mounted.transcript.reloadRows(at: IndexSet(integer: 0))
        mounted.settle()

        XCTAssertNil(copiedText(view))
    }

    // MARK: - Driving a selection

    /// Far outside the block on either side, at a given height — every block
    /// clamps a stray point to its nearest position, so this selects a whole line
    /// without the test having to know where any glyph sits. Same sweep
    /// `BlockViewSelectionTests` uses.
    private func sweep(_ view: BlockView, atY y: CGFloat) {
        view.mouseDown(with: event(view, at: CGPoint(x: -500, y: y), .leftMouseDown))
        view.mouseDragged(with: event(view, at: CGPoint(x: 5_000, y: y), .leftMouseDragged))
    }

    private func event(_ view: BlockView, at point: CGPoint, _ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: mounted.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Cleared first, because `copy(_:)` writes nothing when there is no
    /// selection — without the clear, "nothing was copied" and "the last copy is
    /// still there" would read the same.
    private func copiedText(_ view: BlockView) -> String? {
        NSPasteboard.general.clearContents()
        view.copy(nil)
        return NSPasteboard.general.string(forType: .string)
    }
}

/// Markdown for every row, from sources a test can rewrite between reloads.
@MainActor
private final class GrowingHost: NSObject, TranscriptViewDataSource {

    var sources: [String]

    /// Fixed at construction, so rewriting `sources[row]` is a row whose *content*
    /// moved rather than a different row — which is the whole subject of this
    /// file. A host that minted a fresh identity per frame would make every
    /// assertion below about reuse fail, and correctly.
    private let ids: [UUID]

    init(sources: [String]) {
        self.sources = sources
        ids = sources.map { _ in UUID() }
        super.init()
    }

    func numberOfRows(in transcriptView: TranscriptView) -> Int { sources.count }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        TranscriptRow(id: ids[row], content: content(forRow: row))
    }

    private func content(forRow row: Int) -> TranscriptRowContent {
        .markdown(sources[row])
    }
}

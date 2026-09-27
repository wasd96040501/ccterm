import AppKit
import CoreText
import XCTest

@testable import TranscriptKit

/// What `RowCache` keeps typeset, and what it keeps only as a height.
///
/// The claim is that memory is bounded by `RowCache.residentBudget` rather than
/// by the length of the transcript, **without** any row answering differently:
/// every row still has its height, and a row whose tree was evicted draws exactly
/// as it did before. So each test here asserts one half of that — something was
/// evicted, and nothing that matters changed.
///
/// Rows are sized as fractions of the budget rather than written out, so every
/// test's premise ("these are more than the cache holds") is a line of arithmetic
/// that is asserted, not a number that has to be kept in step with the constant.
@MainActor
final class RowCacheTests: XCTestCase {

    private static let width: CGFloat = 600

    /// `count` distinct documents, each `1 / fraction` of the budget.
    private static func rows(_ count: Int, fraction: Int = 16) -> [TranscriptRow] {
        let bytes = RowCache.residentBudget / fraction
        return (0..<count).map { index in
            let sentence = "Row \(index) says enough to wrap at any width this suite uses. "
            let text = String(repeating: sentence, count: bytes / sentence.utf8.count)
            return TranscriptRow(id: UUID(), content: .markdown(text))
        }
    }

    private static func totalCost(_ rows: [TranscriptRow]) -> Int {
        rows.reduce(0) { $0 + RowCache.cost(of: $1.content) }
    }

    private func resident(_ rows: [TranscriptRow], in cache: RowCache) -> [Bool] {
        rows.map { cache.cachedMeasured(for: $0, width: Self.width) != nil }
    }

    // MARK: - The budget

    func testTheTreesKeptFitTheBudgetAndEveryRowKeepsItsHeight() throws {
        let cache = RowCache()
        let rows = Self.rows(32)
        let heights = rows.map { cache.height(for: $0, width: Self.width) }
        let kept = resident(rows, in: cache)

        XCTAssertGreaterThan(
            Self.totalCost(rows), RowCache.residentBudget,
            "premise: the rows are more than the budget holds")
        XCTAssertTrue(kept.contains(true), "premise: something stayed typeset")
        XCTAssertTrue(kept.contains(false), "nothing was evicted")
        XCTAssertLessThanOrEqual(
            Self.totalCost(zip(rows, kept).filter(\.1).map(\.0)), RowCache.residentBudget)

        // Asked again, every row answers from the height it kept — so the same
        // numbers, and no tree rebuilt to produce them.
        XCTAssertEqual(rows.map { cache.height(for: $0, width: Self.width) }, heights)
        XCTAssertEqual(resident(rows, in: cache), kept, "a height question rebuilt a tree")

        let evicted = rows[try XCTUnwrap(kept.firstIndex(of: false))]
        XCTAssertEqual(
            cache.height(for: evicted, width: Self.width),
            evicted.content.entry(width: Self.width, reusing: nil)?.height,
            "an evicted row answers a different height than measuring it does")
    }

    /// Eviction goes by what was last *drawn*. A row on screen survives any number
    /// of rows only measured for their height — which is every row of a reload.
    func testARowBeingDrawnOutlivesRowsOnlyMeasured() {
        let cache = RowCache()
        let rows = Self.rows(32)
        XCTAssertNotNil(cache.measured(for: rows[0], width: Self.width))
        for row in rows.dropFirst() { _ = cache.height(for: row, width: Self.width) }

        XCTAssertTrue(resident(rows, in: cache).contains(false), "premise: something was evicted")
        XCTAssertNotNil(
            cache.cachedMeasured(for: rows[0], width: Self.width),
            "the drawn row was evicted to make room for rows nobody drew")
    }

    func testAnEvictedRowIsTypesetAgainWhenDrawn() {
        let cache = RowCache()
        let rows = Self.rows(32)
        let heights = rows.map { cache.height(for: $0, width: Self.width) }
        guard let index = resident(rows, in: cache).firstIndex(of: false) else {
            return XCTFail("premise: something was evicted")
        }

        let drawn = cache.measured(for: rows[index], width: Self.width)
        XCTAssertEqual(drawn?.size.height, heights[index])
        XCTAssertNotNil(cache.cachedMeasured(for: rows[index], width: Self.width))
    }

    /// A width change reaches an evicted row through `remeasured(at:)`, on the
    /// pool. It has no recipe to re-break, so it is rebuilt from its content — and
    /// comes back evicted, or correcting a resize would make every row resident.
    func testAnEvictedEntryRemeasuresFromItsContentAndStaysEvicted() throws {
        let content = Self.rows(1)[0].content
        let wide = try XCTUnwrap(content.entry(width: 600, reusing: nil))
        let narrow = wide.evicted.remeasured(at: 420)

        XCTAssertNotEqual(wide.height, narrow.height, "premise: the two widths lay out differently")
        XCTAssertEqual(narrow.height, content.entry(width: 420, reusing: nil)?.height)
        XCTAssertEqual(narrow.measuredWidth, 420)
        XCTAssertNil(narrow.tree)
    }

    // MARK: - A prepared batch

    /// A batch larger than the budget keeps trees for its tail only — the rows
    /// that land against the reader when it is prepended — and a height for all.
    func testAPreparedBatchKeepsTreesOnlyForTheTailTheBudgetHolds() async {
        let mounted = MountedTranscript(size: NSSize(width: Self.width, height: 400))
        defer { mounted.teardown() }
        mounted.settle()
        let rows = Self.rows(32)
        let prepared = await mounted.transcript.prepareRows(rows)
        let kept = rows.map { prepared.entries[$0.id]?.tree != nil }

        XCTAssertGreaterThan(prepared.width, 0, "premise: the transcript was laid out")
        XCTAssertEqual(prepared.count, rows.count, "premise: every row was measured")
        XCTAssertGreaterThan(Self.totalCost(rows), RowCache.residentBudget)
        XCTAssertEqual(kept.last, true, "the row nearest the reader lost its tree")
        XCTAssertEqual(kept.first, false, "the whole batch kept its trees")
        XCTAssertEqual(kept, kept.sorted { !$0 && $1 }, "the trees kept are not the batch's tail")
        XCTAssertLessThanOrEqual(
            Self.totalCost(zip(rows, kept).filter(\.1).map(\.0)), RowCache.residentBudget)
        XCTAssertTrue(
            rows.allSatisfy { (prepared.entries[$0.id]?.height ?? 0) > 0 },
            "a row that lost its tree lost its height too")
    }

    // MARK: - In a transcript

    /// The whole loop, through the table: scroll far enough that the first row is
    /// the least recently drawn and gets evicted, come back, and it draws again at
    /// exactly the height the table has been holding for it all along.
    func testAnEvictedRowDrawsAtTheHeightTheTableHasForIt() throws {
        let mounted = MountedTranscript(size: NSSize(width: Self.width, height: 400))
        defer { mounted.teardown() }
        let host = Host(rows: Self.rows(80, fraction: 64))
        mounted.transcript.dataSource = host
        mounted.transcript.delegate = host
        mounted.settle()
        mounted.transcript.reloadData()
        mounted.settle()
        let before = try XCTUnwrap(firstLine(ofRow: 0, in: mounted), "premise: row 0 was drawn")
        let drawnHeight = blockView(ofRow: 0, in: mounted)?.block?.size.height
        let rect = mounted.transcript.rect(ofRow: 0)
        XCTAssertGreaterThan(
            Self.totalCost(host.rows), RowCache.residentBudget,
            "premise: the transcript is more than the budget holds")

        for row in 1..<host.rows.count {
            mounted.transcript.scrollToRow(at: row, scrollPosition: .top)
            mounted.settle()
        }
        mounted.transcript.scrollToRow(at: 0, scrollPosition: .top)
        mounted.settle()

        let view = try XCTUnwrap(blockView(ofRow: 0, in: mounted), "row 0 is not on screen")
        let after = try XCTUnwrap(firstLine(ofRow: 0, in: mounted))
        XCTAssertFalse(before === after, "premise: row 0 was evicted and typeset again")
        // Against what it drew before the eviction rather than against the row's
        // rectangle, which also holds the spacing between rows.
        XCTAssertEqual(view.block?.size.height, drawnHeight)
        XCTAssertEqual(mounted.transcript.rect(ofRow: 0), rect)
    }

    private func blockView(ofRow row: Int, in mounted: MountedTranscript) -> BlockView? {
        mounted.transcript.descendants(ofType: BlockView.self)
            .first { mounted.transcript.row(for: $0) == row }
    }

    /// The first `CTLine` of the row's first child — a reference type produced by
    /// typesetting, so a different instance means the row was typeset again.
    private func firstLine(ofRow row: Int, in mounted: MountedTranscript) -> CTLine? {
        let stack = blockView(ofRow: row, in: mounted)?.block as? BlockStack.Measured
        let text = stack?.children.first?.block as? MeasuredTextBlock
        return text?.text.lines.first?.ctLine
    }
}

private final class Host: NSObject, TranscriptViewDataSource, TranscriptViewDelegate {

    let rows: [TranscriptRow]

    init(rows: [TranscriptRow]) {
        self.rows = rows
    }

    func numberOfRows(in transcriptView: TranscriptView) -> Int { rows.count }

    func transcriptView(_ transcriptView: TranscriptView, rowAt row: Int) -> TranscriptRow {
        rows[row]
    }
}

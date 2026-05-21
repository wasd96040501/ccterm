import XCTest

@testable import ccterm

/// Pure-function tests for `Transcript2ViewportSlicer.slice` — the
/// orthogonal primitive shared between `Transcript2Controller.setHistory`
/// (first-load path) and the upcoming `Transcript2Coordinator.materialize`
/// (reentry path).
///
/// **Why deterministic `rowHeight`:** the production overload computes
/// heights via `Transcript2Coordinator.makeLayout`, which depends on
/// Core Text font metrics and isn't stable across system-font updates.
/// Tests use the closure-form overload with a fixed `20pt per block`
/// stub so slice boundaries can be asserted exactly against fixture
/// data. This decouples slicer correctness from font-metric stability.
@MainActor
final class Transcript2ViewportSlicerTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Fixtures

    private func blocks(_ count: Int) -> [Block] {
        (0..<count).map { i in
            Block(
                id: UUID(),
                kind: .paragraph(inlines: [.text("p\(i)")]))
        }
    }

    /// All blocks reported as 20pt tall. Viewport of 100pt fits 5 rows.
    private let fixedHeight: (Block) -> CGFloat = { _ in 20 }

    // MARK: - Tests: empty / degenerate inputs

    func testEmptyBlocks_returnsEmptyRange() {
        let slice = Transcript2ViewportSlicer.slice(
            blocks: [],
            anchor: .bottom,
            viewportHeight: 100,
            rowHeight: fixedHeight)
        XCTAssertEqual(slice, 0..<0)
    }

    func testZeroViewportHeight_fallsBackToAnchorBlockOnly_forBottom() {
        let bs = blocks(10)
        let slice = Transcript2ViewportSlicer.slice(
            blocks: bs,
            anchor: .bottom,
            viewportHeight: 0,
            rowHeight: fixedHeight)
        // Zero viewport degenerates to "anchor block only" — keeps
        // Phase 1 non-empty so a downstream materialize has *something*
        // to insert before Phase 2 lands.
        XCTAssertEqual(slice, 9..<10)
    }

    func testZeroViewportHeight_fallsBackToAnchorBlockOnly_forTop() {
        let bs = blocks(10)
        let slice = Transcript2ViewportSlicer.slice(
            blocks: bs,
            anchor: .top(id: bs[3].id),
            viewportHeight: 0,
            rowHeight: fixedHeight)
        XCTAssertEqual(slice, 3..<4)
    }

    // MARK: - Tests: `.bottom` anchor

    func testBottomAnchor_shortTranscriptFitsEntirely() {
        // 3 rows × 20pt = 60pt, fits in 100pt viewport with room to spare.
        let bs = blocks(3)
        let slice = Transcript2ViewportSlicer.slice(
            blocks: bs,
            anchor: .bottom,
            viewportHeight: 100,
            rowHeight: fixedHeight)
        XCTAssertEqual(slice, 0..<3, "all 3 blocks should be included")
    }

    func testBottomAnchor_exactlyFittingTranscript() {
        // 5 rows × 20pt = 100pt, exactly fills 100pt viewport.
        let bs = blocks(5)
        let slice = Transcript2ViewportSlicer.slice(
            blocks: bs,
            anchor: .bottom,
            viewportHeight: 100,
            rowHeight: fixedHeight)
        XCTAssertEqual(slice, 0..<5)
    }

    func testBottomAnchor_tallTranscript_returnsTailSlice() {
        // 20 rows × 20pt = 400pt, viewport 100pt → tail 5 rows cover
        // viewport. `.bottom` walks from index 19 backward, accumulating
        // until coverage. Each row is 20pt. After 5 rows: 100pt. Breaks.
        // Returns 15..<20.
        let bs = blocks(20)
        let slice = Transcript2ViewportSlicer.slice(
            blocks: bs,
            anchor: .bottom,
            viewportHeight: 100,
            rowHeight: fixedHeight)
        XCTAssertEqual(slice, 15..<20)
    }

    func testBottomAnchor_oneTallBlockExceedsViewport() {
        // Single block 200pt tall, viewport 100pt → slice includes that
        // one block (overshoots viewport rather than undershoots, per
        // doc invariant).
        let bs = blocks(1)
        let slice = Transcript2ViewportSlicer.slice(
            blocks: bs,
            anchor: .bottom,
            viewportHeight: 100
        ) { _ in 200 }
        XCTAssertEqual(slice, 0..<1)
    }

    // MARK: - Tests: `.top(id)` anchor

    func testTopAnchor_walksForwardFromAnchorBlock() {
        // 20 rows × 20pt, viewport 100pt, anchor at index 7.
        // Walk forward from 7: 7..11 (5 rows = 100pt covered).
        let bs = blocks(20)
        let slice = Transcript2ViewportSlicer.slice(
            blocks: bs,
            anchor: .top(id: bs[7].id),
            viewportHeight: 100,
            rowHeight: fixedHeight)
        XCTAssertEqual(slice, 7..<12)
    }

    func testTopAnchor_atTail_truncatesToAvailable() {
        // Anchor at index 18 (only 2 rows available forward). Viewport
        // 100pt → only 40pt covered (rows 18, 19); slice is 18..<20.
        let bs = blocks(20)
        let slice = Transcript2ViewportSlicer.slice(
            blocks: bs,
            anchor: .top(id: bs[18].id),
            viewportHeight: 100,
            rowHeight: fixedHeight)
        XCTAssertEqual(slice, 18..<20)
    }

    func testTopAnchor_unknownId_fallsBackToBottom() {
        let bs = blocks(20)
        let unknownId = UUID()
        let slice = Transcript2ViewportSlicer.slice(
            blocks: bs,
            anchor: .top(id: unknownId),
            viewportHeight: 100,
            rowHeight: fixedHeight)
        // Falls back to .bottom: tail 5 rows.
        XCTAssertEqual(slice, 15..<20)
    }

    // MARK: - Tests: `.bottomTo(id)` anchor

    func testBottomToAnchor_walksBackwardFromAnchorBlock() {
        // 20 rows × 20pt, viewport 100pt, anchor at index 12.
        // Walk backward from 12: 8..13 (5 rows = 100pt covered).
        let bs = blocks(20)
        let slice = Transcript2ViewportSlicer.slice(
            blocks: bs,
            anchor: .bottomTo(id: bs[12].id),
            viewportHeight: 100,
            rowHeight: fixedHeight)
        XCTAssertEqual(slice, 8..<13)
    }

    func testBottomToAnchor_nearStart_truncatesToAvailable() {
        // Anchor at index 2: only 3 rows available backward (0, 1, 2).
        // 60pt total < 100pt viewport. Slice is 0..<3.
        let bs = blocks(20)
        let slice = Transcript2ViewportSlicer.slice(
            blocks: bs,
            anchor: .bottomTo(id: bs[2].id),
            viewportHeight: 100,
            rowHeight: fixedHeight)
        XCTAssertEqual(slice, 0..<3)
    }

    func testBottomToAnchor_unknownId_fallsBackToBottom() {
        let bs = blocks(20)
        let unknownId = UUID()
        let slice = Transcript2ViewportSlicer.slice(
            blocks: bs,
            anchor: .bottomTo(id: unknownId),
            viewportHeight: 100,
            rowHeight: fixedHeight)
        XCTAssertEqual(slice, 15..<20)
    }

    // MARK: - Tests: variable-height (the realistic case)

    func testVariableHeight_bottomAnchor_picksMixedSlice() {
        // Heights: [10, 50, 30, 80, 20] tall (last → first).
        // Walking from index 4 backward, accumulating until ≥ 100pt:
        //   - i=4: +20 = 20 (continue)
        //   - i=3: +80 = 100 → ≥ 100, break
        // Slice: 3..<5.
        let bs = blocks(5)
        let heights: [CGFloat] = [10, 50, 30, 80, 20]
        let slice = Transcript2ViewportSlicer.slice(
            blocks: bs,
            anchor: .bottom,
            viewportHeight: 100
        ) { block in
            heights[bs.firstIndex(of: block) ?? 0]
        }
        XCTAssertEqual(slice, 3..<5)
    }

    func testVariableHeight_topAnchor_picksMixedSlice() {
        let bs = blocks(5)
        let heights: [CGFloat] = [10, 50, 30, 80, 20]
        // From index 1 (height 50) forward:
        //   - i=1: +50 = 50 (continue)
        //   - i=2: +30 = 80 (continue)
        //   - i=3: +80 = 160 → ≥ 100, break
        // Slice: 1..<4.
        let slice = Transcript2ViewportSlicer.slice(
            blocks: bs,
            anchor: .top(id: bs[1].id),
            viewportHeight: 100
        ) { block in
            heights[bs.firstIndex(of: block) ?? 0]
        }
        XCTAssertEqual(slice, 1..<4)
    }
}

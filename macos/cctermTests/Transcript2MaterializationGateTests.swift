import XCTest

@testable import ccterm

/// Pure tests for `Transcript2MaterializationGate` — the AppKit/data
/// visibility mediator that backs the phased materialize rollout.
///
/// **What's pinned here vs in the live-coordinator tests:** the gate
/// is a sum-type lookup; its correctness is entirely about how its
/// three cases map `(blocks.count, row)` to AppKit-visible answers.
/// Pure tests cover that exhaustively. The integration of the gate
/// with `Transcript2Coordinator` (which mutation paths route through
/// which branch, how the rollout phases transition the gate) is
/// covered by the live-Coordinator tests in
/// `Transcript2CoordinatorAttachTests` / future
/// `Transcript2CoordinatorMaterializeInPhasesTests`.
final class Transcript2MaterializationGateTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - `.full`

    func testFull_numberOfRowsMatchesBlocksCount() {
        let gate: Transcript2MaterializationGate = .full
        XCTAssertEqual(gate.numberOfRows(blocksCount: 0), 0)
        XCTAssertEqual(gate.numberOfRows(blocksCount: 1), 1)
        XCTAssertEqual(gate.numberOfRows(blocksCount: 361), 361)
    }

    func testFull_rowMapsIdentity() {
        let gate: Transcript2MaterializationGate = .full
        XCTAssertEqual(gate.dataIndex(forRow: 0, blocksCount: 10), 0)
        XCTAssertEqual(gate.dataIndex(forRow: 5, blocksCount: 10), 5)
        XCTAssertEqual(gate.dataIndex(forRow: 9, blocksCount: 10), 9)
    }

    func testFull_rowOutOfRangeReturnsNil() {
        let gate: Transcript2MaterializationGate = .full
        XCTAssertNil(gate.dataIndex(forRow: -1, blocksCount: 10))
        XCTAssertNil(gate.dataIndex(forRow: 10, blocksCount: 10))
        XCTAssertNil(gate.dataIndex(forRow: 0, blocksCount: 0))
    }

    func testFull_predicates() {
        let gate: Transcript2MaterializationGate = .full
        XCTAssertTrue(gate.isFull)
        XCTAssertFalse(gate.isSuppressed)
    }

    // MARK: - `.suppressed`

    func testSuppressed_alwaysZeroRows() {
        let gate: Transcript2MaterializationGate = .suppressed
        XCTAssertEqual(gate.numberOfRows(blocksCount: 0), 0)
        XCTAssertEqual(gate.numberOfRows(blocksCount: 361), 0)
    }

    func testSuppressed_alwaysNoMapping() {
        let gate: Transcript2MaterializationGate = .suppressed
        XCTAssertNil(gate.dataIndex(forRow: 0, blocksCount: 0))
        XCTAssertNil(gate.dataIndex(forRow: 0, blocksCount: 10))
        XCTAssertNil(gate.dataIndex(forRow: 5, blocksCount: 10))
    }

    func testSuppressed_predicates() {
        let gate: Transcript2MaterializationGate = .suppressed
        XCTAssertFalse(gate.isFull)
        XCTAssertTrue(gate.isSuppressed)
    }

    // MARK: - `.visible(slice)`

    func testVisible_numberOfRowsMatchesSliceCount() {
        // Slice covering 5 rows starting at index 10.
        let gate: Transcript2MaterializationGate = .visible(slice: 10..<15)
        XCTAssertEqual(gate.numberOfRows(blocksCount: 20), 5)
    }

    func testVisible_rowMapsToBlocksWithOffset() {
        // Slice 10..<15: AppKit row 0 → blocks[10], row 4 → blocks[14].
        let gate: Transcript2MaterializationGate = .visible(slice: 10..<15)
        XCTAssertEqual(gate.dataIndex(forRow: 0, blocksCount: 20), 10)
        XCTAssertEqual(gate.dataIndex(forRow: 1, blocksCount: 20), 11)
        XCTAssertEqual(gate.dataIndex(forRow: 4, blocksCount: 20), 14)
    }

    func testVisible_rowOutOfSliceReturnsNil() {
        let gate: Transcript2MaterializationGate = .visible(slice: 10..<15)
        XCTAssertNil(gate.dataIndex(forRow: -1, blocksCount: 20))
        // AppKit's row index space is 0..<slice.count, so row 5 with a
        // 5-row slice is out of bounds.
        XCTAssertNil(gate.dataIndex(forRow: 5, blocksCount: 20))
        XCTAssertNil(gate.dataIndex(forRow: 100, blocksCount: 20))
    }

    func testVisible_predicates() {
        let gate: Transcript2MaterializationGate = .visible(slice: 0..<5)
        XCTAssertFalse(gate.isFull)
        XCTAssertFalse(gate.isSuppressed)
    }

    // MARK: - `.visible(slice)` defensive: blocks shrunk under the slice

    /// If the blocks array shrinks below the slice's `upperBound`
    /// (e.g. a `.remove` raced into the rollout window), the gate
    /// clamps `numberOfRows` to the intersection so AppKit never asks
    /// `heightOfRow` for an out-of-bounds index. Phase 2's main hop
    /// re-derives the slice from current blocks and reconciles.
    func testVisible_blocksShrunkBelowSlice_clampsRowCount() {
        let gate: Transcript2MaterializationGate = .visible(slice: 10..<15)
        // Blocks shrank from 20 to 12. Slice 10..<15 intersects to 10..<12.
        XCTAssertEqual(gate.numberOfRows(blocksCount: 12), 2)
    }

    func testVisible_blocksShrunkBelowSlice_dataIndexClampsByBlocksBound() {
        let gate: Transcript2MaterializationGate = .visible(slice: 10..<15)
        // AppKit's row 0 (slice.lowerBound=10) — if blocksCount=12,
        // dataIdx=10 is valid. row 2 (dataIdx=12) is past the array → nil.
        XCTAssertEqual(gate.dataIndex(forRow: 0, blocksCount: 12), 10)
        XCTAssertNil(gate.dataIndex(forRow: 2, blocksCount: 12))
    }

    func testVisible_blocksShrunkBelowSliceLowerBound() {
        // Pathological: blocksCount=8, slice=10..<15. The slice's
        // start is past the end of the array. numberOfRows clamps to 0.
        let gate: Transcript2MaterializationGate = .visible(slice: 10..<15)
        XCTAssertEqual(gate.numberOfRows(blocksCount: 8), 0)
    }

    // MARK: - Equatable

    func testEquatable() {
        XCTAssertEqual(
            Transcript2MaterializationGate.full,
            Transcript2MaterializationGate.full)
        XCTAssertEqual(
            Transcript2MaterializationGate.suppressed,
            Transcript2MaterializationGate.suppressed)
        XCTAssertEqual(
            Transcript2MaterializationGate.visible(slice: 0..<10),
            Transcript2MaterializationGate.visible(slice: 0..<10))
        XCTAssertNotEqual(
            Transcript2MaterializationGate.full,
            Transcript2MaterializationGate.suppressed)
        XCTAssertNotEqual(
            Transcript2MaterializationGate.visible(slice: 0..<10),
            Transcript2MaterializationGate.visible(slice: 0..<11))
    }
}

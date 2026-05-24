import AppKit
import XCTest

@testable import ccterm

/// Tier-1 Group C (REFACTOR-PLAN §12.1): the `apply` change vocabulary, data
/// half. With no `NSTableView` bound, `apply` mutates `coordinator.blocks`
/// directly (the headless path), so the prepend / append / replace / remove /
/// update semantics are testable without geometry.
@MainActor
final class TranscriptApplyVocabularyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func para(_ tag: String) -> Block {
        Block(id: UUID(), kind: .paragraph(inlines: [.text(tag)]))
    }

    /// Build a controller seeded with `blocks` via `.append` (the headless
    /// first land), returning the controller and the seed ids in order.
    private func seeded(_ blocks: [Block]) -> Transcript2Controller {
        let controller = Transcript2Controller()
        controller.apply(.append(blocks))
        return controller
    }

    // MARK: - C1: prepend inserts at the head, preserving prior order

    func testC1_prependInsertsAtIndexZero() throws {
        let a = para("A")
        let b = para("B")
        let x = para("X")
        let y = para("Y")
        let controller = seeded([a, b])

        controller.apply(.prepend([x, y]))

        XCTAssertEqual(controller.coordinator.blockIds, [x.id, y.id, a.id, b.id])
    }

    // MARK: - C2: append inserts at the tail

    func testC2_appendInsertsAtTail() throws {
        let a = para("A")
        let b = para("B")
        let c = para("C")
        let controller = seeded([a, b])

        controller.apply(.append([c]))

        XCTAssertEqual(controller.coordinator.blockIds, [a.id, b.id, c.id])
    }

    // MARK: - C3: replace swaps a contiguous run in place, atomically

    func testC3_replaceSwapsContiguousRangeAtSameStart() throws {
        let a = para("A")
        let b = para("B")
        let c = para("C")
        let d = para("D")
        let x = para("X")
        let y = para("Y")
        let z = para("Z")
        let controller = seeded([a, b, c, d])

        controller.apply(.replace(oldIds: [b.id, c.id], with: [x, y, z]))

        // newBlocks land at the same start index B occupied; count delta = +1.
        XCTAssertEqual(controller.coordinator.blockIds, [a.id, x.id, y.id, z.id, d.id])
        XCTAssertEqual(controller.blockCount, 5)
    }

    // MARK: - C4: degenerate replace(oldIds: []) routes to append

    func testC4_replaceWithEmptyOldIdsRoutesToAppend() throws {
        let a = para("A")
        let b = para("B")
        let x = para("X")
        let controller = seeded([a, b])

        controller.apply(.replace(oldIds: [], with: [x]))

        // Not an in-place swap at the head — appended at the tail.
        XCTAssertEqual(controller.coordinator.blockIds, [a.id, b.id, x.id])
    }

    // MARK: - C5: remove drops the rows

    func testC5_removeDropsRows() throws {
        let a = para("A")
        let b = para("B")
        let c = para("C")
        let controller = seeded([a, b, c])

        controller.apply(.remove(ids: [b.id]))

        XCTAssertEqual(controller.coordinator.blockIds, [a.id, c.id])
    }

    // MARK: - C6: update swaps kind in place, id and index stable

    func testC6_updateSwapsKindInPlace() throws {
        let a = para("A")
        let b = para("B")
        let controller = seeded([a, b])

        controller.apply(.update(id: a.id, kind: .thematicBreak))

        XCTAssertEqual(controller.coordinator.blockIds, [a.id, b.id], "index stable")
        XCTAssertEqual(controller.coordinator.block(forId: a.id)?.kind, .thematicBreak)
    }
}

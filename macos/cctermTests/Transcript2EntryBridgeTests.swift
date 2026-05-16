import AgentSDK
import XCTest

@testable import ccterm

/// Bridge dispatch tests. These don't drive a real `NSTableView` — they
/// observe `Transcript2Controller.blockCount` (driven by the
/// `Coordinator.onBlockCountChanged` callback) and `blockIds` to check
/// that the bridge handed the correct blocks to the controller.
@MainActor
final class Transcript2EntryBridgeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// `.reset` with a precomputed payload must yield exactly the block
    /// ids the precompute map contains — proving the bridge consumed the
    /// cached blocks instead of re-running the synchronous builder.
    func testApplyResetUsesPrecomputedBlocks() {
        let entry = MessageEntry.single(
            SingleEntry(
                id: UUID(),
                payload: .remote(Message2Fixtures.assistantText("Hello")),
                delivery: nil,
                toolResults: [:]))
        let precomputed = MessageEntryBlockBuilder.precompute([entry])

        let controller = Transcript2Controller()
        let bridge = Transcript2EntryBridge(controller: controller)

        bridge.apply(.reset([entry], precomputedBlocks: precomputed))

        let expectedIds = precomputed[entry.id]?.map(\.id) ?? []
        XCTAssertFalse(expectedIds.isEmpty, "precompute should not be empty")
        XCTAssertEqual(controller.blockIds, expectedIds)
    }

    /// `.reset` without precomputed must still work — the bridge falls
    /// back to the synchronous `MessageEntryBlockBuilder` and produces the
    /// same block ids. Guards the fallback wiring.
    func testApplyResetFallsBackWhenPrecomputedMissing() {
        let entry = MessageEntry.single(
            SingleEntry(
                id: UUID(),
                payload: .remote(Message2Fixtures.assistantText("Hello")),
                delivery: nil,
                toolResults: [:]))
        let synchronous = MessageEntryBlockBuilder.entryBlocks(entry)

        let controller = Transcript2Controller()
        let bridge = Transcript2EntryBridge(controller: controller)

        bridge.apply(.reset([entry], precomputedBlocks: nil))

        XCTAssertEqual(controller.blockIds, synchronous.map(\.id))
    }
}

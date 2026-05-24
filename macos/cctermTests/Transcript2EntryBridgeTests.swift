import AgentSDK
import XCTest

@testable import ccterm

/// Bridge dispatch tests for the **live** path — the only path the bridge owns
/// after the load-path collapse (history flows through
/// `TranscriptBackfillPipeline`, not the bridge). Observes both the bridge's
/// reverse map (`entryOrder` / `entryBlockIds`) and the controller's block
/// order, no `NSTableView` mount required.
@MainActor
final class Transcript2EntryBridgeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func single(_ message: Message2) -> MessageEntry {
        .single(SingleEntry(id: UUID(), payload: .remote(message), delivery: nil, toolResults: [:]))
    }

    /// `.appended` records the entry's blocks and appends them at the tail.
    func testAppendRecordsAndAppendsAtTail() {
        let controller = Transcript2Controller()
        let bridge = Transcript2EntryBridge(controller: controller)

        let a = single(Message2Fixtures.assistantText("first"))
        let b = single(Message2Fixtures.assistantText("second"))
        bridge.apply(.appended(a))
        bridge.apply(.appended(b))

        XCTAssertEqual(bridge.entryOrder, [a.id, b.id])
        let expected = (bridge.entryBlockIds[a.id] ?? []) + (bridge.entryBlockIds[b.id] ?? [])
        XCTAssertEqual(controller.coordinator.blockIds, expected, "blocks land in append order")
    }

    /// `.updated` with an identical id sequence (the 95% tool_result-merge
    /// case) updates in place — order and ids unchanged.
    func testUpdateSameIdSequenceKeepsOrder() {
        let controller = Transcript2Controller()
        let bridge = Transcript2EntryBridge(controller: controller)

        let entry = single(Message2Fixtures.assistantText("body"))
        bridge.apply(.appended(entry))
        let before = controller.coordinator.blockIds

        // Re-send the same entry as an update; same content → same block ids.
        bridge.apply(.updated(entry))

        XCTAssertEqual(controller.coordinator.blockIds, before, "in-place update preserves order")
        XCTAssertEqual(bridge.entryBlockIds[entry.id], before)
    }

    /// `.removed` drops the entry's blocks and forgets it.
    func testRemoveDropsBlocks() {
        let controller = Transcript2Controller()
        let bridge = Transcript2EntryBridge(controller: controller)

        let a = single(Message2Fixtures.assistantText("keep"))
        let b = single(Message2Fixtures.assistantText("drop"))
        bridge.apply(.appended(a))
        bridge.apply(.appended(b))
        bridge.apply(.removed(b))

        XCTAssertEqual(bridge.entryOrder, [a.id])
        XCTAssertNil(bridge.entryBlockIds[b.id])
        XCTAssertEqual(controller.coordinator.blockIds, bridge.entryBlockIds[a.id] ?? [])
    }

    /// `pushHistoricalStatuses` is the pipeline's status entry point; calling it
    /// with non-tool entries is a harmless no-op (no crash, no block changes).
    func testHistoricalStatusPushNoToolsIsNoOp() {
        let controller = Transcript2Controller()
        let bridge = Transcript2EntryBridge(controller: controller)
        bridge.pushHistoricalStatuses(for: [single(Message2Fixtures.assistantText("text only"))])
        XCTAssertEqual(controller.blockCount, 0, "status push alone applies no blocks")
    }
}

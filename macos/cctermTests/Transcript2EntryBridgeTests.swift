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

    /// An assistant entry whose text grows by a whole new block (the streaming
    /// shape: paragraphs accruing) updates **append-only** — the already-shown
    /// block ids are preserved as a prefix and only the new block is added.
    /// This is what keeps settled rows from being torn out + re-faded on every
    /// paragraph boundary.
    func testUpdateAppendOnlyGrowthPreservesSettledBlocks() {
        let controller = Transcript2Controller()
        let bridge = Transcript2EntryBridge(controller: controller)

        let entryId = UUID()
        func entry(_ text: String) -> MessageEntry {
            .single(
                SingleEntry(
                    id: entryId,
                    payload: .remote(Message2Fixtures.assistantText(text, messageId: "m1")),
                    delivery: nil, toolResults: [:]))
        }

        bridge.apply(.appended(entry("para one")))
        let afterFirst = controller.coordinator.blockIds
        XCTAssertFalse(afterFirst.isEmpty)

        // Grow with a second, then a third paragraph.
        bridge.apply(.updated(entry("para one\n\npara two")))
        let afterSecond = controller.coordinator.blockIds
        XCTAssertEqual(
            Array(afterSecond.prefix(afterFirst.count)), afterFirst,
            "the first block keeps its id (no remove/insert churn)")
        XCTAssertGreaterThan(afterSecond.count, afterFirst.count, "the new paragraph was added")

        bridge.apply(.updated(entry("para one\n\npara two\n\npara three")))
        let afterThird = controller.coordinator.blockIds
        XCTAssertEqual(
            Array(afterThird.prefix(afterSecond.count)), afterSecond,
            "earlier blocks keep their ids as more paragraphs stream in")
        XCTAssertEqual(bridge.entryBlockIds[entryId], afterThird, "reverse map stays in sync")
    }

    /// Regression for the streaming-text-then-tool flicker: when an assistant
    /// entry grows from text-only to text + tool_use (append-only growth), the
    /// settled text block above the new tool block must be **inserted past, not
    /// removed and re-faded**. The block-id list alone cannot catch this — a
    /// remove+reinsert of the same id leaves an identical final list (which is
    /// exactly why `testUpdateAppendOnlyGrowthPreservesSettledBlocks` passed
    /// against the buggy `.replace(boundary)` too). We witness via
    /// coordinator-side status state instead: `.remove` drops `statusStates[id]`
    /// (Coordinator's `.remove` arm), while `.insert` leaves it untouched. So a
    /// surviving status proves the boundary row was never torn out.
    func testAppendOnlyGrowthDoesNotEvictBoundaryBlock() throws {
        let controller = Transcript2Controller()
        let bridge = Transcript2EntryBridge(controller: controller)

        let entryId = UUID()
        let textOnly = MessageEntry.single(
            SingleEntry(
                id: entryId,
                payload: .remote(
                    Message2Fixtures.assistantText("Let me check.", messageId: "m1")),
                delivery: nil, toolResults: [:]))
        bridge.apply(.appended(textOnly))
        let beforeIds = controller.coordinator.blockIds
        let boundaryId = try XCTUnwrap(beforeIds.last, "text-only entry produced a block")

        // Seed a coordinator-side status on the settled text block. The old
        // `.replace([boundary], [boundary, tool])` would `.remove` the boundary
        // and drop this; the new `.insert(after: boundary, [tool])` leaves it.
        controller.setToolStatus(id: boundaryId, status: .running)
        XCTAssertEqual(controller.coordinator.status(for: boundaryId), .running)

        // Same entry id grows to text + a Read tool_use — append-only growth.
        let textThenTool = MessageEntry.single(
            SingleEntry(
                id: entryId,
                payload: .remote(
                    Message2Fixtures.assistantTextThenRead(
                        "Let me check.", toolUseId: "tool_1",
                        filePath: "a.swift", messageId: "m1")),
                delivery: nil, toolResults: [:]))
        bridge.apply(.updated(textThenTool))

        let afterIds = controller.coordinator.blockIds
        XCTAssertEqual(
            Array(afterIds.prefix(beforeIds.count)), beforeIds,
            "the settled text block keeps its id and position")
        XCTAssertGreaterThan(afterIds.count, beforeIds.count, "the tool block was appended")
        XCTAssertEqual(
            controller.coordinator.status(for: boundaryId), .running,
            "the boundary text block was not removed — its status survives; a "
                + "`.replace` boundary-restate would have dropped it")
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

import AgentSDK
import XCTest

@testable import ccterm

/// Bridge dispatch tests. Observes the bridge's internal reverse map
/// (`entryBlockIds`) instead of `Transcript2Controller.blockIds` so the
/// tests don't require a real `NSTableView` mount — the bridge's
/// contract is "the reverse map matches the precomputed block ids" and
/// that's what we check.
@MainActor
final class Transcript2EntryBridgeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// `.reset` with a precomputed payload must record exactly those
    /// block ids in the bridge's reverse map — proving the bridge
    /// consumed the cached blocks instead of re-running the builder.
    func testApplyResetUsesPrecomputedBlocks() {
        let entry = MessageEntry.single(
            SingleEntry(
                id: UUID(),
                payload: .remote(Message2Fixtures.assistantText("Hello")),
                delivery: nil,
                toolResults: [:]))
        let precomputed = MessageEntryBlockBuilder.precompute([entry])
        let expectedIds = precomputed[entry.id]?.map(\.id) ?? []
        XCTAssertFalse(expectedIds.isEmpty, "precompute should not be empty")

        let bridge = Transcript2EntryBridge(controller: Transcript2Controller())
        bridge.apply(.reset([entry], precomputedBlocks: precomputed))

        XCTAssertEqual(bridge.entryOrder, [entry.id])
        XCTAssertEqual(bridge.entryBlockIds[entry.id], expectedIds)
    }

    /// `.reset` without precomputed must still work — the bridge falls
    /// back to the synchronous `MessageEntryBlockBuilder` and produces
    /// the same block ids. Guards the fallback wiring.
    func testApplyResetFallsBackWhenPrecomputedMissing() {
        let entry = MessageEntry.single(
            SingleEntry(
                id: UUID(),
                payload: .remote(Message2Fixtures.assistantText("Hello")),
                delivery: nil,
                toolResults: [:]))
        let synchronousIds = MessageEntryBlockBuilder.entryBlocks(entry).map(\.id)

        let bridge = Transcript2EntryBridge(controller: Transcript2Controller())
        bridge.apply(.reset([entry], precomputedBlocks: nil))

        XCTAssertEqual(bridge.entryBlockIds[entry.id], synchronousIds)
    }

    /// `.prepended` reuses the precomputed payload and prepends the entry
    /// ids to `entryOrder`. Covers the Phase B path.
    func testApplyPrependUsesPrecomputedBlocks() {
        let tail = MessageEntry.single(
            SingleEntry(
                id: UUID(),
                payload: .remote(Message2Fixtures.assistantText("tail")),
                delivery: nil,
                toolResults: [:]))
        let prefix = MessageEntry.single(
            SingleEntry(
                id: UUID(),
                payload: .remote(Message2Fixtures.assistantText("prefix")),
                delivery: nil,
                toolResults: [:]))
        let precomputed = MessageEntryBlockBuilder.precompute([prefix])

        let bridge = Transcript2EntryBridge(controller: Transcript2Controller())
        // Seed with the tail entry first so the prepend has something to
        // anchor in front of.
        bridge.apply(.reset([tail], precomputedBlocks: nil))
        bridge.apply(.prepended([prefix], precomputedBlocks: precomputed))

        XCTAssertEqual(
            bridge.entryOrder, [prefix.id, tail.id],
            "prefix entry id must end up at the head of entryOrder")
        XCTAssertEqual(
            bridge.entryBlockIds[prefix.id],
            precomputed[prefix.id]?.map(\.id))
    }
}

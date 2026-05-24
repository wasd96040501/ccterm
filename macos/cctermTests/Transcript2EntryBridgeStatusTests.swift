import AgentSDK
import XCTest

@testable import ccterm

/// Status-derivation rules in `Transcript2EntryBridge`:
///
/// - `pushHistoricalStatuses` (history loaded by the backfill pipeline) →
///   tool_use without a matching `tool_result` resolves to `.completed`,
///   not `.running`. Historical sessions never paint an abandoned spinner.
/// - `.appended` / `.updated` (live CLI) → tool_use without a matching
///   `tool_result` resolves to `.running`. Standard in-flight render.
/// - `handleTurnFinished()` (runtime `.result` arrived) → every tool
///   surface currently `.running` flips to `.completed` in one pass.
///   `.failed` and `.cancelled` survive.
///
/// Tests assert via `Transcript2Controller.toolStatus(for:)` — the
/// symmetric reader for `setToolStatus(id:status:)`. No NSTableView is
/// mounted; status mutations on `Transcript2Coordinator` apply to the
/// sparse `statusStates` dict regardless of table attachment.
@MainActor
final class Transcript2EntryBridgeStatusTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Build a single-entry MessageEntry whose assistant message holds
    /// exactly one Read tool_use with the given `toolUseId`. No
    /// `tool_result` is attached — that's the running/completed pivot.
    private func entryWithUnresolvedRead(toolUseId: String) -> (MessageEntry, UUID) {
        let id = UUID()
        let entry = MessageEntry.single(
            SingleEntry(
                id: id,
                payload: .remote(
                    Message2Fixtures.assistantRead(
                        toolUseId: toolUseId, filePath: "/tmp/x.txt")),
                delivery: nil,
                toolResults: [:]))
        return (entry, id)
    }

    private func childIdFor(toolUseId: String) -> UUID {
        StableBlockID.derive("tool", toolUseId)
    }

    private func groupIdFor(entryId: UUID, toolUseIndex: Int) -> UUID {
        StableBlockID.derive(
            "entry", entryId.uuidString, "tg", String(toolUseIndex))
    }

    // MARK: - Historical mode (pipeline-loaded history)

    /// History tools routed through `pushHistoricalStatuses` (the backfill
    /// pipeline's status entry point) must NOT be marked `.running`. History
    /// replay's abandoned tools render as `.completed`.
    func testHistoricalUnresolvedToolIsCompleted() {
        let (entry, entryId) = entryWithUnresolvedRead(toolUseId: "tu-hist")
        let controller = Transcript2Controller()
        let bridge = Transcript2EntryBridge(controller: controller)

        bridge.pushHistoricalStatuses(for: [entry])

        XCTAssertEqual(
            controller.toolStatus(for: childIdFor(toolUseId: "tu-hist")),
            .completed,
            "historical tool_use should not be marked .running")
        XCTAssertEqual(
            controller.toolStatus(
                for: groupIdFor(entryId: entryId, toolUseIndex: 0)),
            .completed,
            "single-tool host group should mirror child .completed")
    }

    /// A batch of history entries all settle `.completed` under historical
    /// derivation (mirrors the multi-page backfill the pipeline feeds).
    func testHistoricalBatchAllCompleted() {
        let (a, idA) = entryWithUnresolvedRead(toolUseId: "tu-h1")
        let (b, idB) = entryWithUnresolvedRead(toolUseId: "tu-h2")

        let controller = Transcript2Controller()
        let bridge = Transcript2EntryBridge(controller: controller)
        bridge.pushHistoricalStatuses(for: [a, b])

        XCTAssertEqual(controller.toolStatus(for: childIdFor(toolUseId: "tu-h1")), .completed)
        XCTAssertEqual(controller.toolStatus(for: childIdFor(toolUseId: "tu-h2")), .completed)
        XCTAssertEqual(
            controller.toolStatus(for: groupIdFor(entryId: idA, toolUseIndex: 0)), .completed)
        XCTAssertEqual(
            controller.toolStatus(for: groupIdFor(entryId: idB, toolUseIndex: 0)), .completed)
    }

    // MARK: - Live mode (.appended)

    /// `.appended` with an unresolved tool_use must mark it `.running`.
    /// Contrast with `testResetMapsUnresolvedToolToCompleted` — the only
    /// difference is which `MessagesChange` variant the bridge sees.
    func testAppendedMapsUnresolvedToolToRunning() {
        let (entry, entryId) = entryWithUnresolvedRead(toolUseId: "tu-live")
        let controller = Transcript2Controller()
        let bridge = Transcript2EntryBridge(controller: controller)

        bridge.apply(.appended(entry))

        XCTAssertEqual(
            controller.toolStatus(for: childIdFor(toolUseId: "tu-live")),
            .running,
            "live tool_use without result must show .running")
        XCTAssertEqual(
            controller.toolStatus(
                for: groupIdFor(entryId: entryId, toolUseIndex: 0)),
            .running,
            "single-tool host group mirrors its child")
    }

    // MARK: - Turn-end clearing

    /// `Transcript2Controller.clearAllRunningStatuses()` flips every
    /// `.running` entry to `.completed`. Non-running entries are
    /// untouched.
    func testClearAllRunningStatusesFlipsRunningToCompleted() {
        let controller = Transcript2Controller()
        // Inject a running surface via the live path.
        let (entry, entryId) = entryWithUnresolvedRead(toolUseId: "tu-clear")
        Transcript2EntryBridge(controller: controller).apply(.appended(entry))
        XCTAssertEqual(
            controller.toolStatus(for: childIdFor(toolUseId: "tu-clear")),
            .running)

        // Seed an unrelated `.failed` to confirm it survives the sweep.
        let failedId = UUID()
        controller.setToolStatus(id: failedId, status: .failed(message: nil))

        controller.clearAllRunningStatuses()

        XCTAssertEqual(
            controller.toolStatus(for: childIdFor(toolUseId: "tu-clear")),
            .completed,
            ".running must flip to .completed")
        XCTAssertEqual(
            controller.toolStatus(
                for: groupIdFor(entryId: entryId, toolUseIndex: 0)),
            .completed,
            "group host follows the same sweep")
        XCTAssertEqual(
            controller.toolStatus(for: failedId),
            .failed(message: nil),
            ".failed must survive the sweep")
    }

    /// Bridge's `handleTurnFinished()` is a thin forwarder over
    /// `controller.clearAllRunningStatuses()`. Verifies the wiring used
    /// from `Session.wireRuntimeMessagesSink`.
    func testHandleTurnFinishedClearsRunning() {
        let (entry, _) = entryWithUnresolvedRead(toolUseId: "tu-turn-end")
        let controller = Transcript2Controller()
        let bridge = Transcript2EntryBridge(controller: controller)
        bridge.apply(.appended(entry))
        XCTAssertEqual(
            controller.toolStatus(for: childIdFor(toolUseId: "tu-turn-end")),
            .running)

        bridge.handleTurnFinished()

        XCTAssertEqual(
            controller.toolStatus(for: childIdFor(toolUseId: "tu-turn-end")),
            .completed)
    }
}

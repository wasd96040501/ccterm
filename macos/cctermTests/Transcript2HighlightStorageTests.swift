import XCTest

@testable import ccterm

/// Per-scope dedup tests for `Transcript2HighlightStorage`. The behaviour
/// this file pins is: a `schedule(_:)` call whose block kind changed
/// because **one child's payload** changed must not invalidate the other
/// children's already-cached tokens.
///
/// Pre-fix, `Coordinator.applyStructuralChange.update` called
/// `highlightStorage.drop(blockId:)` before `schedule`, wiping every
/// scope's tokens; the visible row flashed plain → coloured during
/// streaming. The fix moves dedup inside `schedule` (per-scope
/// fingerprint compare), so unchanged sibling scopes retain their
/// tokens across the call. These tests exercise the storage directly
/// (no coordinator, no NSTableView).
@MainActor
final class Transcript2HighlightStorageTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func makeEngine() async -> SyntaxHighlightEngine {
        let engine = SyntaxHighlightEngine()
        await engine.load()
        return engine
    }

    private func makeBashChild(id: UUID, command: String) -> ToolGroupBlock.Child {
        .bash(
            BashChild(
                id: id,
                label: "Ran",
                activeLabel: "Running",
                command: command,
                stdout: nil,
                stderr: nil))
    }

    private func makeFileEditChild(
        id: UUID,
        oldString: String?,
        newString: String,
        filePath: String = "/tmp/foo.swift"
    ) -> ToolGroupBlock.Child {
        .fileEdit(
            FileEditChild(
                id: id,
                label: "Edit",
                activeLabel: "Editing",
                filePath: filePath,
                diff: DiffBlock(
                    filePath: filePath,
                    oldString: oldString,
                    newString: newString)))
    }

    private func makeToolGroupBlock(
        id: UUID,
        children: [ToolGroupBlock.Child]
    ) -> Block {
        Block(
            id: id,
            kind: .toolGroup(
                ToolGroupBlock(
                    activeTitle: "Running",
                    expandedActiveTitle: "Running",
                    completedTitle: "Ran",
                    children: children)))
    }

    /// Drive the storage's async writeback to completion. `schedule`
    /// kicks an unstructured `Task` whose final `MainActor.run` fires
    /// `onDidFill`. Wait for that, with a generous CI-friendly timeout.
    private func waitForFill(
        on storage: Transcript2HighlightStorage,
        for blockId: UUID,
        timeout: TimeInterval = 5
    ) async {
        let expectation = expectation(description: "onDidFill \(blockId.uuidString.prefix(8))")
        storage.onDidFill = { id in
            if id == blockId { expectation.fulfill() }
        }
        await fulfillment(of: [expectation], timeout: timeout)
        storage.onDidFill = nil
    }

    // MARK: - Tests

    /// Sanity: a fresh `schedule(_:)` on a tool group with one fileEdit
    /// and one bash child writes both children's values. Confirms the
    /// per-scope batch landing path before the dedup tests below
    /// depend on it.
    func testScheduleLandsTokensForEveryChild() async {
        let engine = await makeEngine()
        let storage = Transcript2HighlightStorage(engine: engine)
        let blockId = UUID()
        let fileEditId = UUID()
        let bashId = UUID()
        let block = makeToolGroupBlock(
            id: blockId,
            children: [
                makeFileEditChild(
                    id: fileEditId,
                    oldString: "let x = 1\n",
                    newString: "let x = 1\nlet y = 2\n"),
                makeBashChild(id: bashId, command: "echo hello"),
            ])

        storage.schedule(block)
        await waitForFill(on: storage, for: blockId)

        XCTAssertNotNil(
            storage.lineMap(blockId: blockId, scope: .toolGroupChild(itemId: fileEditId)),
            "fileEdit scope should land a lineMap")
        XCTAssertNotNil(
            storage.tokens(blockId: blockId, scope: .toolGroupChild(itemId: bashId)),
            "bash scope should land a tokens array")
    }

    /// **Root fix smoke test.** Build a tool group with two children,
    /// fill it. Build a second tool group whose `kind` differs only in
    /// the bash command — fileEdit child is byte-identical. Call
    /// `schedule(_:)` with the new block and verify:
    ///
    /// 1. The fileEdit's lineMap is **still present synchronously**
    ///    after the call (pre-fix, this would be `nil` because
    ///    `Coordinator.update` called `drop(blockId:)` first).
    /// 2. Once the second schedule's writeback lands, the fileEdit's
    ///    lineMap is the same content as before (its sourceKey didn't
    ///    change, so it was never resubmitted to the engine).
    /// 3. The bash scope's tokens reflect the new command.
    func testScheduleKeepsUnchangedSiblingTokensThroughPartialUpdate() async {
        let engine = await makeEngine()
        let storage = Transcript2HighlightStorage(engine: engine)
        let blockId = UUID()
        let fileEditId = UUID()
        let bashId = UUID()

        let fileEdit = makeFileEditChild(
            id: fileEditId,
            oldString: "let x = 1\n",
            newString: "let x = 1\nlet y = 2\n")
        let firstBlock = makeToolGroupBlock(
            id: blockId,
            children: [
                fileEdit,
                makeBashChild(id: bashId, command: "echo hello"),
            ])
        storage.schedule(firstBlock)
        await waitForFill(on: storage, for: blockId)
        let lineMapBefore = storage.lineMap(
            blockId: blockId, scope: .toolGroupChild(itemId: fileEditId))
        XCTAssertNotNil(lineMapBefore, "fileEdit must have a lineMap after the first schedule")

        // Second block: identical fileEdit child, different bash command.
        let secondBlock = makeToolGroupBlock(
            id: blockId,
            children: [
                fileEdit,
                makeBashChild(id: bashId, command: "echo goodbye"),
            ])
        storage.schedule(secondBlock)

        // Synchronous claim: the fileEdit lineMap is untouched right
        // now (no drop happened). Pre-fix this is `nil`.
        let lineMapDuring = storage.lineMap(
            blockId: blockId, scope: .toolGroupChild(itemId: fileEditId))
        XCTAssertNotNil(
            lineMapDuring,
            "fileEdit lineMap must survive a partial update on a sibling scope")
        XCTAssertEqual(
            lineMapBefore?.keys.sorted(),
            lineMapDuring?.keys.sorted(),
            "fileEdit lineMap keys must be unchanged immediately after partial update")

        await waitForFill(on: storage, for: blockId)
        let lineMapAfter = storage.lineMap(
            blockId: blockId, scope: .toolGroupChild(itemId: fileEditId))
        XCTAssertEqual(
            lineMapBefore?.keys.sorted(),
            lineMapAfter?.keys.sorted(),
            "fileEdit lineMap must persist verbatim across the bash-only update")
        XCTAssertNotNil(
            storage.tokens(blockId: blockId, scope: .toolGroupChild(itemId: bashId)),
            "bash tokens for the new command must be present after the writeback")
    }

    /// Idempotent schedule: scheduling the exact same block twice in a
    /// row produces no writeback the second time (every scope's
    /// fingerprint matches). The contract is "no `onDidFill` fires for
    /// a no-op schedule" — observable signal that the engine wasn't
    /// re-invoked.
    func testRescheduleWithIdenticalContentIsNoOp() async {
        let engine = await makeEngine()
        let storage = Transcript2HighlightStorage(engine: engine)
        let blockId = UUID()
        let bashId = UUID()
        let block = makeToolGroupBlock(
            id: blockId,
            children: [makeBashChild(id: bashId, command: "echo hi")])

        storage.schedule(block)
        await waitForFill(on: storage, for: blockId)

        // Arm a fresh expectation that we _don't_ want to see fulfilled.
        let unwanted = expectation(description: "no onDidFill on no-op schedule")
        unwanted.isInverted = true
        storage.onDidFill = { _ in unwanted.fulfill() }

        storage.schedule(block)

        await fulfillment(of: [unwanted], timeout: 0.5)
    }

    /// A removed child's scope is wiped on the next `schedule(_:)`,
    /// even though `Coordinator.applyStructuralChange.update` no longer
    /// calls `drop`. Covers the "tool group shrank" path.
    func testRescheduleWipesScopesThatDisappearFromBlock() async {
        let engine = await makeEngine()
        let storage = Transcript2HighlightStorage(engine: engine)
        let blockId = UUID()
        let fileEditId = UUID()
        let bashId = UUID()
        let firstBlock = makeToolGroupBlock(
            id: blockId,
            children: [
                makeFileEditChild(
                    id: fileEditId,
                    oldString: "let x = 1\n",
                    newString: "let x = 1\nlet y = 2\n"),
                makeBashChild(id: bashId, command: "echo hello"),
            ])
        storage.schedule(firstBlock)
        await waitForFill(on: storage, for: blockId)
        XCTAssertNotNil(
            storage.tokens(blockId: blockId, scope: .toolGroupChild(itemId: bashId)))

        // Second block drops the bash child entirely.
        let secondBlock = makeToolGroupBlock(
            id: blockId,
            children: [
                makeFileEditChild(
                    id: fileEditId,
                    oldString: "let x = 1\n",
                    newString: "let x = 1\nlet y = 2\n")
            ])
        storage.schedule(secondBlock)
        XCTAssertNil(
            storage.tokens(blockId: blockId, scope: .toolGroupChild(itemId: bashId)),
            "removed child's scope must be wiped synchronously on reschedule")
        XCTAssertNotNil(
            storage.lineMap(blockId: blockId, scope: .toolGroupChild(itemId: fileEditId)),
            "surviving child's tokens must persist")
    }

    /// `drop(blockId:)` (called from `.remove`) wipes every scope this
    /// block carries. Sanity check that the per-scope generation
    /// counter is still bumped so any in-flight writeback for the
    /// block can't commit afterward — observable by scheduling again
    /// after drop and verifying tokens come back through the writeback
    /// (rather than being already-cached).
    func testDropClearsEveryScopeForBlock() async {
        let engine = await makeEngine()
        let storage = Transcript2HighlightStorage(engine: engine)
        let blockId = UUID()
        let fileEditId = UUID()
        let bashId = UUID()
        let block = makeToolGroupBlock(
            id: blockId,
            children: [
                makeFileEditChild(
                    id: fileEditId,
                    oldString: "let x = 1\n",
                    newString: "let x = 1\nlet y = 2\n"),
                makeBashChild(id: bashId, command: "echo hi"),
            ])

        storage.schedule(block)
        await waitForFill(on: storage, for: blockId)
        XCTAssertNotNil(
            storage.lineMap(blockId: blockId, scope: .toolGroupChild(itemId: fileEditId)))
        XCTAssertNotNil(
            storage.tokens(blockId: blockId, scope: .toolGroupChild(itemId: bashId)))

        storage.drop(blockId: blockId)
        XCTAssertNil(
            storage.lineMap(blockId: blockId, scope: .toolGroupChild(itemId: fileEditId)),
            "drop must wipe every scope for the block")
        XCTAssertNil(
            storage.tokens(blockId: blockId, scope: .toolGroupChild(itemId: bashId)))

        // Scheduling the same content again must re-fire (sourceKeys
        // were cleared by drop), proving the dedup state was reset.
        storage.schedule(block)
        await waitForFill(on: storage, for: blockId)
        XCTAssertNotNil(
            storage.lineMap(blockId: blockId, scope: .toolGroupChild(itemId: fileEditId)))
        XCTAssertNotNil(
            storage.tokens(blockId: blockId, scope: .toolGroupChild(itemId: bashId)))
    }
}

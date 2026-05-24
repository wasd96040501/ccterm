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

    // MARK: - C7: isLoading is derived from historyLoadState, not a stored flag

    /// §8a: "is history still loading" is a data-pipeline fact owned by
    /// `SessionRuntime.historyLoadState` and forwarded verbatim by `Session`.
    /// It is **derived** (`isLoading ≡ state != .loaded`), never a shadow flag
    /// on the controller / coordinator. Walk the lifecycle and assert the
    /// derived relationship; assert the controller's only loading-ish boolean —
    /// `loadingPillVisible`, the *running* pill — is independent of the
    /// history-load state (no coupling, no shadow copy).
    func testC7_isLoadingDerivedFromHistoryLoadState() throws {
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString, repository: InMemorySessionRepository())
        let session = ccterm.Session(
            runtime: runtime, cliClientFactory: { _ in FakeCLIClient() })

        func isLoading(_ s: SessionRuntime.HistoryLoadState) -> Bool {
            s != .loaded
        }

        let cases: [(SessionRuntime.HistoryLoadState, Bool)] = [
            (.notLoaded, true),
            (.loading, true),
            (.loaded, false),
        ]
        for (state, expected) in cases {
            runtime.historyLoadState = state
            XCTAssertEqual(
                session.historyLoadState, state, "Session forwards historyLoadState verbatim")
            XCTAssertEqual(
                isLoading(session.historyLoadState), expected,
                "isLoading derived for \(state)")
            // The controller has no history-loading field — its only loading-ish
            // bool tracks the running pill and stays put across load transitions.
            XCTAssertFalse(
                session.controller.loadingPillVisible,
                "history-load transitions must not flip a controller flag (§8a)")
        }
    }

    // MARK: - C8: apply is the only path that reaches blocks (setHistory gone)

    /// §10: `setHistory` is deleted; the `apply` vocabulary is the single
    /// mutation entry. A mixed sequence composes into exactly the expected
    /// block list — there is no second channel to reach `coordinator.blocks`.
    func testC8_mixedSequenceComposesThroughApplyOnly() throws {
        let a = para("A")
        let b = para("B")
        let c = para("C")
        let controller = seeded([a, b, c])

        let head = para("head")
        let tail = para("tail")
        let swap = para("swap")
        controller.apply(.prepend([head]))  // head, A, B, C
        controller.apply(.append([tail]))  // head, A, B, C, tail
        controller.apply(.replace(oldIds: [b.id], with: [swap]))  // head, A, swap, C, tail
        controller.apply(.remove(ids: [a.id]))  // head, swap, C, tail

        XCTAssertEqual(
            controller.coordinator.blockIds,
            [head.id, swap.id, c.id, tail.id],
            "the apply vocabulary is the sole mutation path; no setHistory escape hatch")
    }
}

import AppKit
import XCTest

@testable import ccterm

/// Tier-2 anchor probes: the viewport-stability claims, measured on a
/// mounted offscreen table.
///
/// - **U2** anchor invariant — a `.prepend` with `.saveVisible(.visualTop)`
///   keeps the visual-top row pinned on screen; the clip origin shifts down by
///   exactly the inserted batch's height. Holds across repeated ticks (no
///   jitter).
/// - **U3** in-tick stability — the anchor is correct in the SAME source phase
///   the prepend ran, before any runloop drain. Falsifies a deferred-
///   compensation regression (the deleted `mutationCounter` path).
/// - **U7** per-case scroll intent — `.update` / `.replace` riding
///   `.saveVisible` preserve the viewport while scrolled mid-document.
/// - **U8** live/load non-conflict — a tail `.append` and a head `.prepend` in
///   the same region of time land at opposite ends without disturbing each
///   other's position or the anchor.
///
/// No `Snapshot` suffix — CI merge gate.
@MainActor
final class TranscriptBackfillAnchorTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let blockCount = 60
    private static let anchorTolerance: CGFloat = 1.5

    private func makeBlocks(_ count: Int, prefix: String = "line") -> [Block] {
        (0..<count).map { i in
            Block(
                id: UUID(),
                kind: .paragraph(inlines: [
                    .text(
                        "\(prefix) \(i): the rain in spain falls mainly on the plain, "
                            + "and the quick brown fox jumps over the lazy dog.")
                ]))
        }
    }

    private func rowIndex(of id: UUID, in controller: Transcript2Controller) -> Int? {
        controller.blockIds.firstIndex(of: id)
    }

    // MARK: - U2: anchor invariant across repeated prepend ticks

    func testU2_prependPreservesVisualTopAcrossTicks() throws {
        let controller = Transcript2Controller()
        controller.apply(.append(makeBlocks(Self.blockCount)))
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }
        mounted.drain()

        // Scrolled to the tail at mount — there's content above the viewport,
        // so the visual-top row is a real mid-document anchor.
        for tick in 0..<3 {
            guard let topRow = mounted.visualTopRow else {
                XCTFail("no visible row at tick \(tick)")
                return
            }
            let anchorId = controller.blockIds[topRow]
            let beforeScreenY = mounted.onScreenTop(ofRow: topRow)
            let beforeClipY = mounted.clip.bounds.origin.y
            let beforeDocHeight = mounted.table.frame.height

            controller.apply(
                .prepend(makeBlocks(4, prefix: "pre\(tick)")),
                scroll: .saveVisible(.visualTop))

            guard let newRow = rowIndex(of: anchorId, in: controller) else {
                XCTFail("anchor id vanished at tick \(tick)")
                return
            }
            let afterScreenY = mounted.onScreenTop(ofRow: newRow)
            let afterClipY = mounted.clip.bounds.origin.y
            let afterDocHeight = mounted.table.frame.height
            let insertedHeight = afterDocHeight - beforeDocHeight

            XCTAssertEqual(
                afterScreenY, beforeScreenY, accuracy: Self.anchorTolerance,
                "tick \(tick): anchor row jumped on screen "
                    + "(\(beforeScreenY) → \(afterScreenY))")
            XCTAssertEqual(
                afterClipY - beforeClipY, insertedHeight, accuracy: Self.anchorTolerance,
                "tick \(tick): clip origin should shift down by the inserted "
                    + "batch height (\(insertedHeight))")
            XCTAssertGreaterThan(
                insertedHeight, 0, "tick \(tick): prepend should grow the document")
        }
    }

    // MARK: - U3: anchor is correct in-tick, before any runloop drain

    func testU3_prependAnchorIsStableInSameTickWithoutDrain() throws {
        let controller = Transcript2Controller()
        controller.apply(.append(makeBlocks(Self.blockCount)))
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }
        mounted.drain()

        guard let topRow = mounted.visualTopRow else {
            XCTFail("no visible row")
            return
        }
        let anchorId = controller.blockIds[topRow]
        let beforeScreenY = mounted.onScreenTop(ofRow: topRow)

        controller.apply(
            .prepend(makeBlocks(6, prefix: "intick")),
            scroll: .saveVisible(.visualTop))

        // NO drain — measure right after `apply` returns, same source phase.
        guard let newRow = rowIndex(of: anchorId, in: controller) else {
            XCTFail("anchor id vanished")
            return
        }
        let afterScreenY = mounted.onScreenTop(ofRow: newRow)

        XCTAssertEqual(
            afterScreenY, beforeScreenY, accuracy: Self.anchorTolerance,
            "in-tick: rect(ofRow:) + clip compensation must be real immediately "
                + "after apply — no 'next tick fixes it' (\(beforeScreenY) → \(afterScreenY))")
    }

    // MARK: - U7: .update / .replace ride saveVisible and preserve the viewport

    func testU7_updateAndReplacePreserveViewportMidDocument() throws {
        let controller = Transcript2Controller()
        controller.apply(.append(makeBlocks(Self.blockCount)))
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }
        // Scroll to a mid-document position so there is content above AND below.
        controller.coordinator.scrollBlockIntoView(blockId: controller.blockIds[30])
        mounted.drain()

        guard let topRow = mounted.visualTopRow else {
            XCTFail("no visible row")
            return
        }
        let anchorId = controller.blockIds[topRow]
        let beforeScreenY = mounted.onScreenTop(ofRow: topRow)

        // .update an off-tail row ABOVE the viewport (changing its height) with
        // the per-case preserve-viewport intent.
        let aboveId = controller.blockIds[5]
        controller.apply(
            .update(
                id: aboveId,
                kind: .paragraph(inlines: [
                    .text("rewritten and substantially longer ".repeated(8))
                ])),
            scroll: .saveVisible(.visualTop))

        guard let row1 = rowIndex(of: anchorId, in: controller) else {
            XCTFail("anchor vanished after update")
            return
        }
        let afterUpdateY = mounted.onScreenTop(ofRow: row1)
        XCTAssertEqual(
            afterUpdateY, beforeScreenY, accuracy: Self.anchorTolerance,
            "update above viewport must not move the anchor (\(beforeScreenY) → \(afterUpdateY))")

        // .replace a contiguous run ABOVE the viewport with a different-sized
        // segment, again preserving the viewport.
        let replaceIds = Array(controller.blockIds[8...10])
        controller.apply(
            .replace(oldIds: replaceIds, with: makeBlocks(5, prefix: "swap")),
            scroll: .saveVisible(.visualTop))

        guard let row2 = rowIndex(of: anchorId, in: controller) else {
            XCTFail("anchor vanished after replace")
            return
        }
        let afterReplaceY = mounted.onScreenTop(ofRow: row2)
        XCTAssertEqual(
            afterReplaceY, beforeScreenY, accuracy: Self.anchorTolerance,
            "replace above viewport must not move the anchor (\(beforeScreenY) → \(afterReplaceY))")
    }

    // MARK: - U8: live tail .append + backfill head .prepend don't conflict

    func testU8_liveAppendAndBackfillPrependLandIndependently() throws {
        let controller = Transcript2Controller()
        controller.apply(.append(makeBlocks(Self.blockCount)))
        let originalIds = controller.blockIds
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }
        mounted.drain()

        guard let topRow = mounted.visualTopRow else {
            XCTFail("no visible row")
            return
        }
        let anchorId = controller.blockIds[topRow]
        let beforeScreenY = mounted.onScreenTop(ofRow: topRow)

        // Interleave in the same region of time: a head prepend (backfill,
        // viewport-preserving) and a tail append (live CLI event).
        let prependBatch = makeBlocks(4, prefix: "older")
        let liveBlock = Block(id: UUID(), kind: .paragraph(inlines: [.text("live tail event")]))
        controller.apply(.prepend(prependBatch), scroll: .saveVisible(.visualTop))
        controller.apply(.append([liveBlock]))

        // Both landed; document order is prepend-batch ‖ originals ‖ live.
        let ids = controller.blockIds
        XCTAssertEqual(ids.count, originalIds.count + 5, "both batches landed")
        XCTAssertEqual(Array(ids.prefix(4)), prependBatch.map(\.id), "prepend at the head")
        XCTAssertEqual(ids.last, liveBlock.id, "live append at the tail")
        XCTAssertEqual(
            Array(ids[4..<(4 + originalIds.count)]), originalIds,
            "original blocks unshifted relative to each other")

        // The head prepend preserved the viewport; the tail append (off-screen)
        // did not disturb it.
        guard let newRow = rowIndex(of: anchorId, in: controller) else {
            XCTFail("anchor vanished")
            return
        }
        let afterScreenY = mounted.onScreenTop(ofRow: newRow)
        XCTAssertEqual(
            afterScreenY, beforeScreenY, accuracy: Self.anchorTolerance,
            "interleaved prepend+append must not move the anchor "
                + "(\(beforeScreenY) → \(afterScreenY))")
    }
}

extension String {
    fileprivate func repeated(_ n: Int) -> String {
        String(repeating: self, count: n)
    }
}

import AppKit
import XCTest

@testable import ccterm

/// Regression for the streaming "append a tool after settled markdown" bug.
///
/// When an assistant message grows from `[text]` to `[text, toolUse]`, the
/// bridge's append-only path re-states the unchanged trailing markdown block to
/// anchor the insert: `.replace(oldIds: [md], with: [md, toolGroup])`.
///
/// `Transcript2Coordinator.applyStructuralChange(.replace)` keeps the shared
/// leading id-prefix in place instead of removing + re-inserting it. Without
/// that, the unchanged markdown row gets a needless `.effectFade` crossfade and
/// its layout / highlight cache is dropped — the row visibly blinks out as the
/// tool appears.
@MainActor
final class Transcript2ReplacePrefixTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func md(_ s: String) -> Block { Block(id: UUID(), kind: .paragraph(inlines: [.text(s)])) }

    /// The shared, unchanged leading block is neither removed nor recomputed;
    /// only the genuinely-new tail lays out.
    func testAppendOnlyReplaceKeepsUnchangedBoundaryInPlace() {
        let controller = Transcript2Controller()
        let userBubble = Block(id: UUID(), kind: .userBubble(text: "hi", isQueued: false))
        let boundary = md("settled markdown")
        controller.apply(.append([userBubble, boundary]))
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }
        mounted.drain()  // warm the layout cache for every visible row

        var recomputed: [UUID] = []
        controller.coordinator.onLayoutCacheWriteForDebug = { id, _ in recomputed.append(id) }

        let tool = md("tool group")  // stand-in for a toolGroup block
        controller.apply(.replace(oldIds: [boundary.id], with: [boundary, tool]))
        mounted.drain()

        XCTAssertFalse(
            recomputed.contains(boundary.id),
            "unchanged boundary was recomputed → it was removed+reinserted (the blink root cause)")
        XCTAssertEqual(
            controller.blockIds, [userBubble.id, boundary.id, tool.id],
            "markdown survives in place, tool appended after it")
        XCTAssertEqual(mounted.table.numberOfRows, controller.blockIds.count)
    }

    /// A shared prefix block whose *kind* changed is updated in place (a single
    /// `reloadData(forRowIndexes:)` recompute, no remove+reinsert), so a genuine
    /// content edit on the boundary still lands without structural churn.
    func testSharedPrefixKindChangeUpdatesInPlace() {
        let controller = Transcript2Controller()
        let boundary = md("v1")
        controller.apply(.append([boundary]))
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }
        mounted.drain()

        var recomputed: [UUID] = []
        controller.coordinator.onLayoutCacheWriteForDebug = { id, _ in recomputed.append(id) }

        let edited = Block(id: boundary.id, kind: .paragraph(inlines: [.text("v1 v2")]))
        let tool = md("tool group")
        controller.apply(.replace(oldIds: [boundary.id], with: [edited, tool]))
        mounted.drain()

        XCTAssertEqual(controller.blockIds, [boundary.id, tool.id], "order preserved, no churn")
        XCTAssertTrue(
            recomputed.contains(boundary.id),
            "a genuine boundary content edit recomputes the row in place")
        XCTAssertEqual(mounted.table.numberOfRows, controller.blockIds.count)
    }

    /// Divergent middle insert (text → text+tool+text) still swaps correctly.
    func testDivergentSuffixReplaceStillSwaps() {
        let controller = Transcript2Controller()
        let a = md("A")
        let bPrev = md("B-prev")
        controller.apply(.append([a, bPrev]))
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }
        mounted.drain()

        let tool = md("tool")
        let bNew = md("B-new")
        controller.apply(.replace(oldIds: [a.id, bPrev.id], with: [a, tool, bNew]))
        mounted.drain()

        XCTAssertEqual(controller.blockIds, [a.id, tool.id, bNew.id])
        XCTAssertEqual(mounted.table.numberOfRows, controller.blockIds.count)
    }

    /// Net-shrink replace (the existing `U5` shape) is unaffected.
    func testNetShrinkReplaceUnaffected() {
        let controller = Transcript2Controller()
        let a = md("A")
        let b = md("B")
        let c = md("C")
        controller.apply(.append([a, b, c]))
        let mounted = MountedTranscript.mount(controller: controller)
        defer { mounted.teardown() }
        mounted.drain()

        let swap = md("swap")
        controller.apply(.replace(oldIds: [b.id, c.id], with: [swap]))
        mounted.drain()

        XCTAssertEqual(controller.blockIds, [a.id, swap.id])
        XCTAssertEqual(mounted.table.numberOfRows, controller.blockIds.count)
    }
}

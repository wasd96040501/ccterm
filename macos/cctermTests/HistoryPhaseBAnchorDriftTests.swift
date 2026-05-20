import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Quantitative test for Phase A → Phase B visual anchor stability.
///
/// Drives the renderer through the *exact same `Transcript2Controller`
/// / coordinator entry points the production bridge uses* — but skips
/// the `SessionRuntime.loadHistory` orchestrator and its JSONL +
/// SwiftUI environment plumbing entirely. This isolates the layout
/// behavior we're asserting against (Phase A's first-screen anchor +
/// Phase B's `.saveVisible` prepend) from anything else that might
/// trip up the offscreen XCTest environment.
///
/// Sequence per scenario:
/// 1. Mount a fresh `NativeTranscript2View` + controller in a 600×600
///    offscreen window. Let AppKit tile the table to its real width.
/// 2. **Phase A**: `controller.setHistory(tail, anchor: .bottom)`.
///    Settle. Record the bottommost visible block's clip-view-relative
///    y via `RowAnchorTracker`.
/// 3. **Phase B**: call `controller.coordinator.applyInBackground(
///    [.insert(after: nil, prefix)], scroll: .saveVisible(.visualTop))`
///    — the same shape `Transcript2EntryBridge.applyPrepend` uses.
///    Settle. Record again.
/// 4. Assert: the bottommost visible block from step 2 still sits at
///    the same clip-view y in step 4 (drift ≤ 2pt).
///
/// The bridge uses `.visualTop` per
/// `Transcript2EntryBridge.applyPrepend`; we forward the same value so
/// the test exercises the production-shape change.
///
/// Two scenarios:
///   - **filled**: tail produces enough blocks that the table content
///     covers the viewport. Phase B should be a no-visual-change
///     prepend.
///   - **short**: tail produces 11 blocks (matches the existing PNG
///     fixture's Phase A blockCount) — content height < viewport.
///     Without the clip-view fix, Phase A's anchor row sits at the
///     visible top while Phase B's prepend forces the row down by
///     the empty-band height. With the fix, the table pins to the
///     visible content area's bottom in both phases, so no drift.
@MainActor
final class HistoryPhaseBAnchorDriftTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Short tail — content height is less than the visible content
    /// area (600 − 44 top inset − 180 bottom inset = 376pt). With 2
    /// paragraphs (~150pt total at the test fixture width), short
    /// is guaranteed. The interesting case: the fix in
    /// `Transcript2ClipView.constrainBoundsRect` should keep the
    /// bottommost block visually pinned across the prepend by
    /// pinning the documentView to the visible bottom in both Phase A
    /// and Phase B. Without the fix, NSClipView's default constraint
    /// stops Phase A's scroll at the top of the clip; Phase B's
    /// prepend then jumps the latest message down to the visible
    /// bottom, producing a ~visible-area-minus-content-height drift
    /// the user reads as a flicker.
    ///
    /// `prefixCount=80` brings the post-prepend total above the
    /// viewport so the "short → tall" transition is real.
    func testShortTailAnchorStableAcrossPhaseBPrepend() async throws {
        try await runAnchorStabilityScenario(tailCount: 1, prefixCount: 80)
    }

    /// Long tail — content fills the viewport. Default NSClipView
    /// already keeps anchor stable here; this scenario is the
    /// regression net to make sure the constrainBoundsRect override
    /// doesn't degrade the previously-correct case.
    func testFilledTailAnchorStableAcrossPhaseBPrepend() async throws {
        try await runAnchorStabilityScenario(tailCount: 30, prefixCount: 30)
    }

    // MARK: - Scenario runner

    private func runAnchorStabilityScenario(
        tailCount: Int, prefixCount: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let tail = Self.makeBlocks(prefix: "TAIL", count: tailCount)
        let prefix = Self.makeBlocks(prefix: "PFX", count: prefixCount)

        let controller = Transcript2Controller()
        let size = CGSize(width: 600, height: 600)
        let view = NativeTranscript2View(controller: controller)
            .environment(\.syntaxEngine, SyntaxHighlightEngine())
        let hosting = NSHostingController(rootView: AnyView(view))
        hosting.view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(
                origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.contentViewController = hosting
        window.ccterm_orderFrontForTesting()
        defer {
            window.contentViewController = nil
            window.close()
        }

        // Let the offscreen table tile to its production width
        // (column autoresize is one runloop pass after layout) so
        // setHistory's real-width Phase 1 fires.
        settle(hosting: hosting, duration: 0.6)

        // ── Phase A: setHistory at .bottom ──────────────────
        controller.setHistory(tail, anchor: .bottom)
        // setHistory's own Phase 1 inserts a viewport slice synchronously;
        // its Phase 2 (off-main, applyInBackground) drops the rest in.
        // Wait for ALL `tail` blocks to land before snapshotting, so
        // `blockCount` is the stable baseline `prefix.count` is compared
        // against in Phase B. Otherwise setHistory's late Phase 2 hop
        // races with the Phase B prepend.
        let phaseAFilled = await waitUntil(
            hosting: hosting, deadlineSeconds: 3
        ) {
            controller.blockCount == tail.count
        }
        XCTAssertTrue(
            phaseAFilled,
            "setHistory Phase 2 did not finish within 3s — "
                + "blockCount is \(controller.blockCount), expected \(tail.count)",
            file: file, line: line)
        XCTAssertTrue(
            controller.isAnchorSettled,
            "Phase A must settle (markAnchorSettled inside Phase 1 of setHistory)",
            file: file, line: line)

        var tracker = RowAnchorTracker()
        tracker.record(from: controller, tick: 1)
        let actualA = actualContentHeight(of: controller)
        guard let phaseA = tracker.lastSnapshot() else {
            return XCTFail(
                "RowAnchorTracker captured no snapshot in Phase A",
                file: file, line: line)
        }
        XCTAssertNotNil(
            phaseA.lastVisibleBlockId,
            "Phase A must have a bottommost visible block id",
            file: file, line: line)
        // The block we expect to see at the bottom of the viewport.
        // setHistory(.bottom) puts the last passed block there.
        XCTAssertEqual(
            phaseA.lastVisibleBlockId, tail.last?.id,
            "Phase A's bottommost visible block must be the tail's last",
            file: file, line: line)
        // Chat convention: the latest message lives at the visible
        // content area's bottom (= clipH − bottomInset), with empty
        // space above it when content is short. Production's
        // NativeTranscript2View configures the scroll view with
        // `contentInsets = (top:44, bottom:180)` at clipH=600 so the
        // expected y is 600 − 180 = 420. The chat-bottom pin lives
        // in `Transcript2ClipView.constrainBoundsRect` combined with
        // `Transcript2Coordinator.scrollRowToBottom` no longer
        // clamping its target. Without that pair, short content
        // sticks to the top of the clip view and the latest message
        // sits ~`-topInset + actualH` from the visible content area's
        // top — wrong end of the viewport.
        let visibleContentBottom: CGFloat = 600 - 180
        XCTAssertEqual(
            phaseA.lastVisibleViewportMaxY ?? -.infinity,
            visibleContentBottom, accuracy: 2.0,
            "Phase A's latest message must sit at the visible content "
                + "area's bottom (chat convention)",
            file: file, line: line)

        // ── Phase B: applyInBackground prepend with saveVisible.visualTop
        // (same shape Transcript2EntryBridge.applyPrepend uses)
        let blocksBeforeB = controller.blockCount
        controller.coordinator.applyInBackground(
            [.insert(after: nil, prefix)],
            scroll: .saveVisible(.visualTop))
        // applyInBackground is fire-and-forget; spin the runloop until
        // the precompute task's main hop lands and `blockCount` reflects
        // the prepended rows. Without this the assertion below would
        // trivially pass on the un-prepended state (same content, same
        // bottom block, drift=0).
        let prepended = await waitUntil(
            hosting: hosting, deadlineSeconds: 5
        ) {
            controller.blockCount == blocksBeforeB + prefix.count
        }
        XCTAssertTrue(
            prepended,
            "Phase B's `applyInBackground` did not land within 5s — "
                + "block count is \(controller.blockCount), expected "
                + "\(blocksBeforeB + prefix.count)",
            file: file, line: line)
        // Extra settle for AppKit's structural change to recompute
        // visible-row geometry. `applyInBackground`'s main hop has
        // landed; `noteHeightOfRows` resolves on the next layout pass.
        settle(hosting: hosting, duration: 0.3)

        tracker.record(from: controller, tick: 2)
        let actualB = actualContentHeight(of: controller)
        guard let phaseB = tracker.lastSnapshot() else {
            return XCTFail(
                "RowAnchorTracker captured no snapshot in Phase B",
                file: file, line: line)
        }
        XCTAssertEqual(
            phaseB.lastVisibleBlockId, tail.last?.id,
            "Phase B's bottommost visible block must still be the tail's last "
                + "— prepend grows the head, doesn't disturb the tail",
            file: file, line: line)

        // `doc` is tableView.frame.height (potentially padded by
        // NSScrollView for contentInsets); `actualH` is the sum of
        // row heights via rect(ofRow:last).maxY, captured at the
        // moment of each snapshot.
        let summary =
            "phaseA fill=\(String(format: "%.2f", phaseA.fillRatio)) "
            + "scroll=\(String(format: "%.1f", phaseA.scrollY)) "
            + "bot.vpY=\(phaseA.lastVisibleViewportMaxY.map { String(format: "%.1f", $0) } ?? "nil") "
            + "doc=\(String(format: "%.1f", phaseA.contentHeight)) "
            + "actualH=\(String(format: "%.1f", actualA))\n"
            + "phaseB fill=\(String(format: "%.2f", phaseB.fillRatio)) "
            + "scroll=\(String(format: "%.1f", phaseB.scrollY)) "
            + "bot.vpY=\(phaseB.lastVisibleViewportMaxY.map { String(format: "%.1f", $0) } ?? "nil") "
            + "doc=\(String(format: "%.1f", phaseB.contentHeight)) "
            + "actualH=\(String(format: "%.1f", actualB))"
        print("[anchor]\n\(summary)")
        // Attach to xcresult so the values survive test stdout capture.
        let attach = XCTAttachment(string: summary)
        attach.name = "anchor-summary"
        attach.lifetime = .keepAlways
        add(attach)

        // The KEY assertion: the same blockId must sit at the same
        // clip-view-relative y in both phases. Tolerance 2pt — sub-row
        // quantization on AppKit re-layout. Anything larger is the
        // user-visible drift the principle "Phase A settled directly
        // goes on screen" forbids.
        if let id = phaseA.lastVisibleBlockId,
            let drift = tracker.lastVisibleDrift(
                of: id, from: phaseA, to: phaseB)
        {
            print(
                "[anchor] last-visible drift "
                    + "shift=\(String(format: "%+.2f", drift.viewportShift))pt"
            )
            XCTAssertLessThanOrEqual(
                abs(drift.viewportShift), 2.0,
                "Phase B prepend must keep the tail's last block within 2pt "
                    + "of its Phase-A viewport y. Got shift="
                    + String(format: "%+.2f", drift.viewportShift) + "pt",
                file: file, line: line)
        } else {
            XCTFail(
                "Could not measure drift — last-visible block id not preserved",
                file: file, line: line)
        }
    }

    // MARK: - Helpers

    /// Compute the "real" content extent: the maxY of the last row's
    /// rect in tableView coords. Differs from `tableView.frame.height`
    /// when NSScrollView's contentInsets cause NSTableView's frame to
    /// be padded to fit the inset-adjusted clip area.
    private func actualContentHeight(of controller: Transcript2Controller) -> CGFloat {
        guard let table = controller.coordinator.tableView,
            table.numberOfRows > 0
        else { return 0 }
        return table.rect(ofRow: table.numberOfRows - 1).maxY
    }

    private static func makeBlocks(prefix: String, count: Int) -> [Block] {
        (0..<count).map { i in
            Block(
                id: UUID(),
                kind: .paragraph(inlines: [
                    .text("\(prefix) line \(i) — quick brown fox over the lazy dog")
                ]))
        }
    }

    private func settle(
        hosting: NSHostingController<AnyView>, duration: TimeInterval
    ) {
        hosting.view.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        hosting.view.layoutSubtreeIfNeeded()
    }

    /// Spin in 20ms ticks until `condition` returns true or
    /// `deadlineSeconds` elapses. Uses `Task.sleep` (yields the
    /// cooperative scheduler so any `Task.detached(...).await MainActor.run`
    /// hops from `applyInBackground` actually land) followed by a
    /// `RunLoop.main.run` drain to let AppKit's deferred layout pass
    /// complete on the same tick. Returns whether the condition was met.
    @discardableResult
    private func waitUntil(
        hosting: NSHostingController<AnyView>,
        deadlineSeconds: TimeInterval,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        while Date() < deadline {
            hosting.view.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
            RunLoop.main.run(
                mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        hosting.view.layoutSubtreeIfNeeded()
        return condition()
    }
}

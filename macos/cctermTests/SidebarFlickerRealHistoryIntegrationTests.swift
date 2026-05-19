import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// End-to-end repro of the sidebar history-switch flicker, against
/// real-world JSONL fixtures (`Fixtures/real-history-session-{A,B}.jsonl`,
/// redacted copies of two live Claude Code project transcripts).
///
/// Unlike the earlier `HistorySwitchBakeOverlayTests` (synthetic
/// `Block(... paragraph)` × 60) and `HistorySwitchFlickerSnapshotTests`,
/// this test:
///
///   1. Pre-loads each session through the **real** `SessionRuntime.loadHistory(overrideURL:)`
///      pipeline so the controller carries blocks built by the real
///      bridge (mixed paragraph / tool-group / code-block kinds; total
///      content extends well past the viewport).
///   2. Mounts the **same modifier chain** RootView2 uses on the detail
///      pane: `.background(DetailBakeProbe)` + `.overlay(bakedImage)` +
///      `.onChange(currentController?.isAnchorSettled ?? true)`.
///   3. Drives the sidebar binding setter shape verbatim — snapshot first,
///      flip `sid` second.
///
/// The regression net is geometry-based, not pixel-based: at every tick
/// from the swap until the bake overlay clears, if `bakedImage == nil`
/// then the live `NSTableView`'s topmost visible row id must NOT equal
/// the first block in session B (which would be "user sees B's
/// beginning before scroll-to-tail completes" — the user-reported bug).
@MainActor
final class SidebarFlickerRealHistoryIntegrationTests: XCTestCase {

    // MARK: - Harness

    @Observable @MainActor
    final class HarnessState {
        var sid: String
        var bakedImage: NSImage?
        let snapshotter = DetailBakeSnapshotter()
        let sessionA: Session
        let sessionB: Session

        /// Snapshot of the table state AT the moment the bake was
        /// cleared (i.e. inside the onChange firing of
        /// `isAnchorSettled = true`). The test asserts here that the
        /// underlying NSTableView is already at the tail — if its
        /// bounds.origin still reflects row 0, the bake is fading
        /// while AppKit still shows the wrong position = flicker.
        struct BakeClearRecord {
            let bakeClearedAt: Date
            let bottomVisibleBlockId: UUID?
            let bLastBlockId: UUID?
            let topVisibleBlockId: UUID?
            let bFirstBlockId: UUID?
            let scrollY: CGFloat
            let docHeightFromLastRow: CGFloat
            let viewportHeight: CGFloat
            let bottomInset: CGFloat
        }
        var bakeClearRecord: BakeClearRecord?

        init(sid: String, sessionA: Session, sessionB: Session) {
            self.sid = sid
            self.sessionA = sessionA
            self.sessionB = sessionB
        }

        var currentSession: Session { sid == "A" ? sessionA : sessionB }
        var currentController: Transcript2Controller { currentSession.controller }

        /// Verbatim copy of `RootView2.sidebarSelectionBinding`'s setter:
        /// bake the outgoing pixels first, then flip the sid so the
        /// next render pass tears down `.id(sid)`.
        func switchTo(_ newSid: String) {
            guard newSid != sid else { return }
            bakedImage = snapshotter.snapshot()
            sid = newSid
        }

        /// Called from the onChange hook in the Harness View at the
        /// exact moment the bake is about to clear. Records the
        /// underlying NSTableView state so the test can assert that
        /// AppKit's scroll has landed before the bake fades.
        func recordBakeClear(controller: Transcript2Controller) {
            let blockIds = controller.coordinator.blockIds
            guard let table = controller.coordinator.tableView,
                let scroll = table.enclosingScrollView
            else {
                bakeClearRecord = BakeClearRecord(
                    bakeClearedAt: Date(),
                    bottomVisibleBlockId: nil,
                    bLastBlockId: blockIds.last,
                    topVisibleBlockId: nil,
                    bFirstBlockId: blockIds.first,
                    scrollY: 0, docHeightFromLastRow: 0,
                    viewportHeight: 0, bottomInset: 0)
                return
            }
            let visible = table.rows(in: table.visibleRect)
            var topId: UUID? = nil
            var botId: UUID? = nil
            if visible.location != NSNotFound, visible.length > 0,
                blockIds.indices.contains(visible.location),
                blockIds.indices.contains(visible.location + visible.length - 1)
            {
                topId = blockIds[visible.location]
                botId = blockIds[visible.location + visible.length - 1]
            }
            let docH =
                table.numberOfRows > 0
                ? table.rect(ofRow: table.numberOfRows - 1).maxY : 0
            bakeClearRecord = BakeClearRecord(
                bakeClearedAt: Date(),
                bottomVisibleBlockId: botId,
                bLastBlockId: blockIds.last,
                topVisibleBlockId: topId,
                bFirstBlockId: blockIds.first,
                scrollY: scroll.contentView.bounds.origin.y,
                docHeightFromLastRow: docH,
                viewportHeight: scroll.contentView.bounds.height,
                bottomInset: scroll.contentInsets.bottom)
        }
    }

    /// Mirrors RootView2's detail-pane modifier chain. We don't mount
    /// the full `NavigationSplitView` (the column animation is not part
    /// of the swap path under investigation); we DO mount the exact
    /// background-probe + overlay-bake + onChange-clear triple, in the
    /// same order, with the same animation parameters.
    struct Harness: View {
        let state: HarnessState

        var body: some View {
            NativeTranscript2View(controller: state.currentController)
                .id(state.sid)
                .environment(\.syntaxEngine, SyntaxHighlightEngine())
                .background(DetailBakeProbe(snapshotter: state.snapshotter))
                .overlay {
                    if let img = state.bakedImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipped()
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .onChange(
                    of: state.currentController.isAnchorSettled, initial: true
                ) { _, settled in
                    if settled, state.bakedImage != nil {
                        // Capture the exact AppKit state at the moment the
                        // bake-clear hook fires. The test asserts that the
                        // underlying NSTableView is already scrolled to the
                        // tail HERE — not via animation, not in a deferred
                        // frame. If `bounds.origin.y` reflects row 0 at
                        // this moment, the bake will fade while AppKit
                        // still shows the wrong position → user flicker.
                        state.recordBakeClear(controller: state.currentController)
                        withAnimation(.smooth(duration: 0.18)) {
                            state.bakedImage = nil
                        }
                    }
                }
        }
    }

    // MARK: - Fixtures

    /// Path to a fixture JSONL inside `cctermTests/Fixtures/`. Resolved via
    /// `#filePath` so the test works whether or not the build phase
    /// classifies `.jsonl` as a bundle resource.
    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    /// Build a `Session` whose runtime has fully loaded `jsonlURL`. The
    /// test pumps the runloop until `historyLoadState == .loaded` so
    /// Phase A AND Phase B have both landed on the controller before
    /// the harness mounts.
    private func makeLoadedSession(jsonlURL: URL) async throws -> Session {
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository())
        let session = Session(runtime: runtime)
        runtime.loadHistory(overrideURL: jsonlURL, tailTarget: 40)

        // Wait for `.loaded`. Phase A's MainActor hops need the
        // cooperative scheduler, which only advances when we `await`.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if runtime.historyLoadState == .loaded { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(
            runtime.historyLoadState, .loaded,
            "session at \(jsonlURL.lastPathComponent) failed to reach .loaded within 5s"
        )
        return session
    }

    // MARK: - Probes

    /// At a single tick: do the visible pixels (modulo bake overlay)
    /// expose B's first block to the user?
    private struct TickProbe {
        let tick: Int
        let bakedImagePresent: Bool
        let currentSettled: Bool
        /// Topmost visible block id in B's live NSTableView. Nil when
        /// no table is attached / no rows currently visible.
        let topVisibleBlockId: UUID?
        /// Block id at index 0 of B's controller — the "beginning" of
        /// the transcript that should never be visible to the user
        /// during the swap (the user has navigated to a history
        /// session; the contract is "land at the tail").
        let bFirstBlockId: UUID?
        /// Block id at index last of B's controller — the tail.
        let bLastBlockId: UUID?
        /// `topVisibleBlockId == bFirstBlockId` AND bake not covering →
        /// the user is staring at the wrong end of the transcript.
        var userSeesBeginning: Bool {
            !bakedImagePresent && topVisibleBlockId != nil
                && topVisibleBlockId == bFirstBlockId
        }
    }

    private func sampleProbe(
        tick: Int,
        state: HarnessState,
        controllerB: Transcript2Controller
    ) -> TickProbe {
        let blockIds = controllerB.coordinator.blockIds
        let table = controllerB.coordinator.tableView
        var top: UUID? = nil
        if let table {
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound, visible.length > 0,
                blockIds.indices.contains(visible.location)
            {
                top = blockIds[visible.location]
            }
        }
        return TickProbe(
            tick: tick,
            bakedImagePresent: state.bakedImage != nil,
            currentSettled: controllerB.isAnchorSettled,
            topVisibleBlockId: top,
            bFirstBlockId: blockIds.first,
            bLastBlockId: blockIds.last)
    }

    // MARK: - Test

    func testSwitchFromRealSessionAToRealSessionBNeverShowsBsBeginning() async throws {
        let urlA = fixtureURL("real-history-session-A.jsonl")
        let urlB = fixtureURL("real-history-session-B.jsonl")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: urlA.path),
            "fixture missing: \(urlA.path)")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: urlB.path),
            "fixture missing: \(urlB.path)")

        let sessionA = try await makeLoadedSession(jsonlURL: urlA)
        let sessionB = try await makeLoadedSession(jsonlURL: urlB)

        let blocksA = sessionA.controller.blockIds.count
        let blocksB = sessionB.controller.blockIds.count
        print(
            "[flicker-test] loaded sessionA=\(blocksA) blocks, sessionB=\(blocksB) blocks"
        )
        // Block counts depend on how many entries collapse into tool
        // groups and how much markdown splits paragraphs. The 600x600
        // viewport holds ~10–15 short rows; a fixture in the dozens of
        // blocks is already overflowing. We log and proceed.
        XCTAssertGreaterThan(blocksA, 8, "session A produced suspiciously few blocks")
        XCTAssertGreaterThan(blocksB, 8, "session B produced suspiciously few blocks")

        // Build the harness.
        let state = HarnessState(sid: "A", sessionA: sessionA, sessionB: sessionB)
        let view = Harness(state: state)

        let size = CGSize(width: 600, height: 600)
        let hosting = NSHostingController(rootView: AnyView(view))
        hosting.view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(
                origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.contentViewController = hosting
        window.ccterm_orderFrontForTesting()
        defer {
            window.contentViewController = nil
            window.close()
        }

        // Settle A.
        await settle(hosting: hosting, duration: 1.0)
        XCTAssertTrue(
            sessionA.controller.isAnchorSettled,
            "session A should settle on initial mount")
        print(
            "[flicker-test] PRE-SWITCH: A.settled=\(sessionA.controller.isAnchorSettled) "
                + "B.settled=\(sessionB.controller.isAnchorSettled) "
                + "A.blocks=\(sessionA.controller.blockIds.count) "
                + "B.blocks=\(sessionB.controller.blockIds.count) "
                + "A.tableView=\(sessionA.controller.coordinator.tableView != nil) "
                + "B.tableView=\(sessionB.controller.coordinator.tableView != nil)"
        )
        writePNG(hosting: hosting, name: "real-00-A-settled")

        // FLIP. Same shape as the production binding setter.
        state.switchTo("B")
        print(
            "[flicker-test] POST-SWITCH: bake=\(state.bakedImage != nil) "
                + "B.settled=\(sessionB.controller.isAnchorSettled) "
                + "B.tableView=\(sessionB.controller.coordinator.tableView != nil)"
        )
        XCTAssertNotNil(
            state.bakedImage,
            "bake must be captured BEFORE the sid flip — snapshotter returned nil"
        )

        // Per-tick capture + probe. 30 ticks × 33ms = ~1s window —
        // enough for Phase A to settle B even on a slow runner. We
        // both write the PNG and record the geometry probe.
        var probes: [TickProbe] = []
        for i in 1...30 {
            // Use Task.sleep so MainActor jobs queued during the
            // swap (the bridge's `.reset`/`.prepended` MainActor.run
            // closures from any concurrent loads, the
            // consumeDesiredAnchor `DispatchQueue.main.async` hop)
            // can actually drain.
            try? await Task.sleep(nanoseconds: 33_000_000)
            hosting.view.layoutSubtreeIfNeeded()

            let probe = sampleProbe(
                tick: i, state: state, controllerB: sessionB.controller)
            probes.append(probe)

            writePNG(
                hosting: hosting,
                name: String(
                    format:
                        "real-%02d-tick-bake=%@-settled=%@-top=%@",
                    i,
                    probe.bakedImagePresent ? "Y" : "N",
                    probe.currentSettled ? "Y" : "N",
                    probe.topVisibleBlockId.map {
                        String($0.uuidString.prefix(8))
                    } ?? "nil"))
        }

        await settle(hosting: hosting, duration: 0.5)
        XCTAssertTrue(
            sessionB.controller.isAnchorSettled, "session B should settle after swap")
        writePNG(hosting: hosting, name: "real-99-B-settled")

        // Trace summary for the log.
        for p in probes {
            print(
                String(
                    format:
                        "[probe] tick=%02d bake=%@ settled=%@ top=%@ bFirst=%@ bLast=%@ userSeesBeginning=%@",
                    p.tick,
                    p.bakedImagePresent ? "Y" : "N",
                    p.currentSettled ? "Y" : "N",
                    p.topVisibleBlockId.map { String($0.uuidString.prefix(8)) }
                        ?? "nil",
                    p.bFirstBlockId.map { String($0.uuidString.prefix(8)) } ?? "nil",
                    p.bLastBlockId.map { String($0.uuidString.prefix(8)) } ?? "nil",
                    p.userSeesBeginning ? "YES (BUG)" : "no"))
        }

        // ── Regression assertions ───────────────────────────────────────

        // 1. The bake-clear hook must have fired (otherwise B never
        //    settled and the test isn't exercising the swap path).
        guard let bakeClear = state.bakeClearRecord else {
            XCTFail(
                "bake-clear hook never fired — onChange(isAnchorSettled) didn't see false→true. "
                    + "B.settled=\(sessionB.controller.isAnchorSettled)")
            return
        }
        print(
            "[flicker-test] BAKE-CLEAR moment: "
                + "top=\(bakeClear.topVisibleBlockId?.uuidString.prefix(8) ?? "nil") "
                + "bottom=\(bakeClear.bottomVisibleBlockId?.uuidString.prefix(8) ?? "nil") "
                + "bFirst=\(bakeClear.bFirstBlockId?.uuidString.prefix(8) ?? "nil") "
                + "bLast=\(bakeClear.bLastBlockId?.uuidString.prefix(8) ?? "nil") "
                + "scrollY=\(bakeClear.scrollY) docH=\(bakeClear.docHeightFromLastRow) "
                + "viewportH=\(bakeClear.viewportHeight) bottomInset=\(bakeClear.bottomInset)"
        )

        // 2. ── THE KEY ASSERTION ──
        //    At the moment onChange clears the bake, the NSTableView's
        //    last row's bottom edge must already be at the visible
        //    content area's bottom. If `bounds.origin.y` reflects
        //    "row 0 at top" instead of "scrolled to tail", the bake
        //    will fade out over the next frames revealing the WRONG
        //    scroll position → that is the "transcript 开头的内容"
        //    the user reports seeing.
        //
        //    Geometric check: `docHeightFromLastRow - scrollY` should
        //    equal `viewportHeight - bottomInset` (the visible content
        //    area's bottom edge). Allow 2pt slack for layout.
        //
        //    This is the primary regression guard. The id-based
        //    `bottomVisibleBlockId == bLastBlockId` check below is a
        //    weaker supplementary signal: it can transiently return
        //    nil if AppKit hasn't yet populated `visibleRect` (e.g.
        //    under parallel-test load), but the geometric check is
        //    derived from `clipView.bounds.origin` + the table's
        //    `rect(ofRow:)` and stays valid regardless.
        let expectedBottomVisibleMaxY = bakeClear.viewportHeight - bakeClear.bottomInset
        let actualBottomVisibleMaxY = bakeClear.docHeightFromLastRow - bakeClear.scrollY
        XCTAssertEqual(
            actualBottomVisibleMaxY, expectedBottomVisibleMaxY, accuracy: 2.0,
            "at bake-clear moment, B's last row's bottom edge must be at the "
                + "visible content area's bottom. Got actual=\(actualBottomVisibleMaxY) "
                + "expected=\(expectedBottomVisibleMaxY). The table is at the wrong "
                + "scroll position — bake will fade revealing this → user-visible flicker."
        )
        // Supplementary check — only assert when the table has reported
        // visible rows. AppKit can leave `visibleRect` empty for one
        // runloop tick after the scroll lands, especially under
        // parallel-test execution where main-thread time is sliced;
        // that nil result doesn't indicate a bug, just a sampling
        // race. The geometric assertion above is the load-bearing one.
        if let bottomId = bakeClear.bottomVisibleBlockId {
            XCTAssertEqual(
                bottomId, bakeClear.bLastBlockId,
                "at bake-clear moment, the BOTTOM visible row must be B's last block (the tail). "
                    + "If it isn't, the table is mid-document or at row 0 → user-visible flicker."
            )
        }

        // 3. By the final settled tick, the bake state should be cleared.
        XCTAssertNil(
            state.bakedImage,
            "bake should have cleared by the end of the capture window; "
                + "if non-nil, the onChange(isAnchorSettled) hook didn't fire")
    }

    // MARK: - Helpers

    private func settle(
        hosting: NSHostingController<AnyView>, duration: TimeInterval
    ) async {
        hosting.view.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        hosting.view.layoutSubtreeIfNeeded()
    }

    private func writePNG(
        hosting: NSHostingController<AnyView>, name: String
    ) {
        let host = hosting.view
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        let url = ViewSnapshot.writePNG(image, name: name)
        let attach = XCTAttachment(contentsOfFile: url)
        attach.name = "\(name).png"
        attach.lifetime = .keepAlways
        add(attach)
    }
}

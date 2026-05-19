import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Drives the synthetic English JSONL fixture
/// (`Message2Fixtures.bulkAssortedJSONL`) end-to-end:
///
/// 1. Write the JSONL to a unique tmp file.
/// 2. Spin up a real `SessionRuntime` against an in-memory repository
///    and `loadHistory(overrideURL: tailTarget: 30)` — fixture is > 30
///    so Phase A reads the tail and Phase B prepends the prefix.
/// 3. Mount `NativeTranscript2View(controller:)` for the same session's
///    controller in a hidden offscreen window (`ViewSnapshot.render`
///    scaffold).
/// 4. Settle, assert `blockCount > 0` and `isAnchorSettled == true`,
///    confirm the last row is visible at the bottom, and write a PNG
///    for human review.
///
/// This is the fixture self-test referenced by the image-bake work —
/// proves "if I feed this JSONL through a real runtime, the transcript
/// renders correctly" before the bake state machine starts gating on
/// `isAnchorSettled`.
@MainActor
final class BulkHistoryFixtureSnapshotTests: XCTestCase {

    private var tempFile: TempJSONLFile?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        tempFile?.remove()
        tempFile = nil
    }

    func testBulkFixtureRendersAfterPhaseAandB() async throws {
        // 50 lines, tailTarget=30 → Phase B prepends ~20 prefix entries.
        // > 1 viewport at 600pt height.
        let lines = Message2Fixtures.bulkAssortedJSONL(count: 50)
        XCTAssertEqual(
            lines.count, 50,
            "fixture builder must honor requested count")
        let file = try TempJSONLFile(lines)
        tempFile = file

        let runtime = SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository())
        let session = Session(runtime: runtime)

        // Mount first so the bridge / coordinator have a live table while
        // Phase A `.reset` + Phase B `.prepended` events arrive.
        let host = mount(controller: session.controller)
        defer { teardown(host) }

        runtime.loadHistory(overrideURL: file.url, tailTarget: 30)

        // Poll the runtime's load state via `Task.sleep` — sleeping yields
        // the cooperative scheduler so the detached load task's
        // `await MainActor.run` hops can execute. A bare
        // `RunLoop.main.run` drain doesn't pump main-actor jobs reliably.
        let loaded = await pollUntil(timeout: 5) {
            runtime.historyLoadState == .loaded
        }
        XCTAssertTrue(
            loaded, "history must reach .loaded; got \(runtime.historyLoadState)")

        // After state is .loaded, AppKit still owes us a layout pass for
        // the prepended rows + deferred-anchor scroll. Drain the runloop
        // for AppKit's deferred work.
        settle(host: host, duration: 0.6)

        XCTAssertGreaterThan(
            session.controller.blockCount, 0,
            "fixture must produce at least one block")
        XCTAssertTrue(
            session.controller.isAnchorSettled,
            "anchor must settle once the table tiles")

        let probe = visibilityProbe(in: host)
        XCTAssertTrue(
            probe.matched,
            "last row must be visible at the bottom; \(probe.summary)")

        // Attach the PNG to the xcresult so a human can confirm the
        // synthetic transcript renders the way production would.
        let image = bitmap(of: host)
        let url = ViewSnapshot.writePNG(image, name: "BulkHistoryFixture")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "BulkHistoryFixture.png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Helpers

    private struct Host {
        let window: NSWindow
        let hosting: NSHostingController<AnyView>
    }

    private func mount(
        controller: Transcript2Controller,
        size: CGSize = CGSize(width: 600, height: 600)
    ) -> Host {
        let view = NativeTranscript2View(controller: controller)
            .environment(\.syntaxEngine, SyntaxHighlightEngine())
        let hosting = NSHostingController(rootView: AnyView(view))
        hosting.view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(
                origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0.01
        window.contentViewController = hosting
        window.ccterm_orderFrontForTesting()
        return Host(window: window, hosting: hosting)
    }

    private func teardown(_ host: Host) {
        host.window.contentViewController = nil
        host.window.close()
    }

    private func pollUntil(
        timeout: TimeInterval,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
        return true
    }

    private func settle(host: Host, duration: TimeInterval) {
        host.hosting.view.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        host.hosting.view.layoutSubtreeIfNeeded()
    }

    private func bitmap(of host: Host) -> NSImage {
        let view = host.hosting.view
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            XCTFail("bitmapImageRepForCachingDisplay returned nil")
            return NSImage(size: view.bounds.size)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Walk the host view hierarchy, locate the embedded `NSTableView`,
    /// and ask the enclosing scroll view which rows are visible.
    /// Returns `matched == true` when the *last* row is inside
    /// `documentVisibleRect`.
    private func visibilityProbe(in host: Host) -> (matched: Bool, summary: String) {
        guard let table = findTableView(in: host.hosting.view) else {
            return (false, "no NSTableView")
        }
        guard let scrollView = table.enclosingScrollView else {
            return (false, "no scroll view")
        }
        if table.numberOfRows == 0 {
            return (false, "numberOfRows == 0")
        }
        let documentVisible = scrollView.documentVisibleRect
        let visible = table.rows(in: documentVisible)
        let lastVisibleRow =
            (visible.location == NSNotFound)
            ? -1 : visible.location + visible.length - 1
        let matched =
            visible.location != NSNotFound && visible.length > 0
            && lastVisibleRow == table.numberOfRows - 1
        let summary =
            "numberOfRows=\(table.numberOfRows) "
            + "visibleRows={loc:\(visible.location), len:\(visible.length)} "
            + "lastVisibleRow=\(lastVisibleRow) "
            + "documentVisible=\(documentVisible)"
        return (matched, summary)
    }

    private func findTableView(in view: NSView) -> NSTableView? {
        if let t = view as? NSTableView { return t }
        for sub in view.subviews {
            if let t = findTableView(in: sub) { return t }
        }
        return nil
    }
}

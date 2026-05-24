import AppKit
import Observation
import SwiftUI
import XCTest

@testable import ccterm

/// Offscreen reproduction harness for the two PR #224 regressions the
/// user reported:
///
///   1. Selecting Archive flattens the window (height collapses).
///   2. Opening a history session can paint a blank transcript.
///
/// Both are mounted through the REAL `DetailRouterViewController` swap
/// path — the production code that creates a fresh child VC and pins it
/// into the detail slot — so the harness exercises the actual call
/// ordering, not a hand-rolled approximation.
@MainActor
final class DetailRouterLayoutDiagnosticsTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Shared fixture

    private struct Fixture {
        let model: MainSelectionModel
        let manager: SessionManager
        let router: DetailRouterViewController
        let sessionIds: [String]
    }

    private func makeFixture(sessionCount: Int) -> Fixture {
        let repo = InMemorySessionRepository()
        var ids: [String] = []
        for i in 0..<sessionCount {
            let sid = UUID().uuidString
            ids.append(sid)
            repo.save(
                SessionRecord(
                    sessionId: sid, title: "S\(i)", cwd: "/tmp/s\(i)", status: .created))
        }
        let manager = SessionManager(
            repository: repo, cliClientFactory: { _ in FakeCLIClient() })

        let defaultsSuite = "ccterm-router-diag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: defaultsSuite) }
        let recentProjects = RecentProjectsStore(defaults: defaults)
        let activation = AppActivationTracker()
        let notifications = NotificationService(activation: activation)
        let syntaxEngine = SyntaxHighlightEngine()
        let searchBus = TranscriptSearchBus()
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-router-diag-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: draftDir) }
        let inputDraftStore = InputDraftStore(directory: draftDir, debounceInterval: 0.05)

        let model = MainSelectionModel()
        let router = DetailRouterViewController(
            model: model,
            sessionManager: manager,
            recentProjects: recentProjects,
            notifications: notifications,
            searchEngine: syntaxEngine,
            searchBus: searchBus,
            inputDraftStore: inputDraftStore)

        return Fixture(model: model, manager: manager, router: router, sessionIds: ids)
    }

    private func drainMainLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// Pumps BOTH schedulers — the AppKit runloop (autolayout / CA
    /// flush) and the Swift-concurrency MainActor executor (the
    /// router's `selectionObservationTask` re-arm + the ArchiveView
    /// `.task`). The router only swaps after its observation Task
    /// resumes, which `RunLoop.run` alone does not drive.
    private func settle(iterations: Int = 14) async {
        for _ in 0..<iterations {
            try? await Task.sleep(for: .milliseconds(40))
            drainMainLoop(seconds: 0.02)
        }
    }

    // MARK: - Bug #1 — Archive flattens the window

    /// Mounts the router as the detail item of an `NSSplitViewController`
    /// that is the window's `contentViewController` — the production
    /// shape (the split shape matters: a plain VC as `contentViewController`
    /// collapses to AppKit's minimum regardless, but the split fills the
    /// window unless a child leaks a fitting size). Records the window
    /// height in chat mode, flips to `.archive`, and re-reads it. A
    /// correctly-built detail pane fills whatever height the window gives
    /// it; if the height collapses, the detail content's fitting size is
    /// leaking up through the split into the window — exactly the
    /// dependency the user flagged.
    func testArchiveSelectionDoesNotFlattenWindow() async throws {
        let fx = makeFixture(sessionCount: 0)
        fx.model.selection = .newSession

        // Wrap the router in a bare two-item NSSplitViewController so the
        // window's contentViewController is a split (production shape),
        // not the router directly. Sidebar item is an empty placeholder
        // VC; the detail item is the router.
        let split = NSSplitViewController()
        let sidebarVC = NSViewController()
        sidebarVC.view = NSView()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 220
        split.addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: fx.router)
        detailItem.minimumThickness = 680
        split.addSplitViewItem(detailItem)

        let size = CGSize(width: 1200, height: 860)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 880, height: 540)
        window.alphaValue = 0.01
        window.contentViewController = split
        window.setContentSize(size)
        window.ccterm_orderFrontForTesting()
        defer {
            window.contentViewController = nil
            window.close()
        }

        await settle()
        let chatHeight = window.frame.height

        fx.model.select(.archive)
        await settle()
        let archiveHeight = window.frame.height

        // Diagnostic: the leak is via fittingSize, not preferredContentSize.
        // With the default `NSHostingController.sizingOptions`, the archive
        // child's `view.fittingSize` height tracks the ScrollView's ideal
        // (~276) and the split's fittingSize bubbles it to the window;
        // cleared, it reads 0 and the split fills.
        let childFitting = fx.router.currentChild?.view.fittingSize ?? .zero
        let report = """
            window height — chat mode = \(chatHeight), archive mode = \(archiveHeight)
            content size = \(window.contentLayoutRect.size)
            archive child fittingSize = \(childFitting)
            """
        let attachment = XCTAttachment(string: report)
        attachment.name = "window-height-archive-flatten"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(
            archiveHeight, chatHeight - 1,
            "Archive selection flattened the window: \(chatHeight) → \(archiveHeight). "
                + "The detail content's fitting size is driving the window height.")
    }

    // MARK: - Bug #2 — history session attach at an unsettled frame

    /// Drives the cross-kind transition the user hits when restoring a
    /// session from the Archive page: `.archive` → `.session(_)`. That
    /// makes the router tear down `ArchiveViewController`, build a fresh
    /// `ChatSessionViewController`, settle its frame, and drive its
    /// transcript attach via `present(sessionId:)` (`layoutSubtreeIfNeeded`
    /// + `scrollToTail`). The attach must typeset every block at the
    /// single settled width;
    /// if it runs before the child view has a real frame, blocks get
    /// typeset at the clamped `minLayoutWidth` (460) first and the
    /// first painted frame is wrong (the user-visible "white screen").
    func testArchiveToSessionAttachUsesSettledWidth() async throws {
        let fx = makeFixture(sessionCount: 2)
        let sid = fx.sessionIds[1]
        guard let session = fx.manager.session(sid) else {
            XCTFail("session materialization failed")
            return
        }
        session.controller.apply(.append(makeBlocks()))

        // Start on Archive so the first child VC is ArchiveViewController,
        // forcing a true cross-kind swap when we flip to the session.
        fx.model.selection = .archive

        let size = CGSize(width: 720, height: 800)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01

        // Pre-sized container with a real frame, mirroring the detail
        // split item's geometry. The router's view fills it.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        fx.router.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(fx.router.view)
        NSLayoutConstraint.activate([
            fx.router.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fx.router.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fx.router.view.topAnchor.constraint(equalTo: container.topAnchor),
            fx.router.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        defer {
            window.contentView = nil
            window.close()
        }

        await settle()

        // Probe the session's coordinator BEFORE the swap so we capture
        // exactly the writes the attach produces.
        let coordinator = session.controller.coordinator
        var writes: [(id: UUID, width: CGFloat)] = []
        coordinator.onLayoutCacheWriteForDebug = { id, width in
            writes.append((id, width))
        }
        defer { coordinator.onLayoutCacheWriteForDebug = nil }

        // Cross-kind switch (archive → transcript) through the router's
        // synchronous owner path. `select` swaps in a fresh
        // `ChatSessionViewController`, settles its frame, and runs the
        // transcript attach — all in this source phase.
        fx.model.select(.session(sid))

        for _ in 0..<24 {
            try? await Task.sleep(for: .milliseconds(50))
            drainMainLoop(seconds: 0.02)
            if coordinator.tableView != nil, !writes.isEmpty { break }
        }
        container.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        drainMainLoop(seconds: 0.05)

        let distinctWidths = Set(writes.map(\.width)).sorted()
        let widthsPerId = Dictionary(grouping: writes, by: \.id).mapValues { Set($0.map(\.width)) }
        let offenders = widthsPerId.filter { $0.value.count > 1 }
        let finalTableWidth = coordinator.tableView?.frame.width ?? -1

        let report = """
            total writes      = \(writes.count)
            distinct widths   = \(distinctWidths)
            offender ids      = \(offenders.count) (typeset at >1 width)
            final table width = \(finalTableWidth)
            """
        let attachment = XCTAttachment(string: report)
        attachment.name = "archive-to-session-attach-widths"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(
            writes.count, 1,
            "Fixture broke: attach produced no layout writes — did the swap run?")
        XCTAssertTrue(
            offenders.isEmpty,
            "Archive→session attach typeset \(offenders.count) block(s) at multiple widths "
                + "\(distinctWidths) — the fresh ChatSessionViewController attached before its "
                + "view reached the settled width.")
    }

    private static let blockCount = 40
    private func makeBlocks() -> [Block] {
        (0..<Self.blockCount).map { i in
            Block(
                id: UUID(),
                kind: .paragraph(inlines: [
                    .text(
                        "line \(i): the rain in spain falls mainly on the plain, "
                            + "and the quick brown fox jumps over the lazy dog.")
                ]))
        }
    }
}

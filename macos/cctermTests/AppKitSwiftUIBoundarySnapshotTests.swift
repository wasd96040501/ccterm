import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Opt-in PNG snapshots for the two headline AppKit↔SwiftUI boundary
/// regimes. **Visual confirmation only** — these render real views into
/// an offscreen window, write a PNG under `/tmp/ccterm-screenshots/`, and
/// assert on plausibility (image size), NOT on pixels. The filename's
/// `Snapshot` suffix means `scripts/test-unit.sh` auto-skips this class on
/// the default suite and on CI; run it opt-in:
///
/// ```bash
/// make test-unit FILTER=AppKitSwiftUIBoundarySnapshotTests
/// open /tmp/ccterm-screenshots/ArchiveBoundary-LargeWindow.png
/// open /tmp/ccterm-screenshots/InputBar-Centered.png
/// ```
///
/// The assertion-driven *gates* for these two regimes live in
/// `AppKitSwiftUIBoundaryTests` (regime A — fill-pane window-collapse) and
/// `HostedComponentCenteringTests` (regime B — centered, width-capped,
/// bottom-anchored component). This file only produces the human-eyeball
/// confirmation that those gates describe a real layout.
///
/// ── Regime A (archive): the window MUST be large ──────────────────────
/// The fill-pane collapse target is ≈ 545×276. To make a collapse visible
/// in the PNG, the archive snapshot mounts the real
/// `DetailRouterViewController` as the detail item of a real two-item
/// `NSSplitViewController` in a **1200×860** window — the same large-window
/// shape the regime-A gate uses (`DetailRouterLayoutDiagnosticsTests`). A
/// small/flat window would render at ≈ the collapse size whether the code
/// is broken or fixed, so a healthy render in a *large* window is itself
/// the evidence: a correctly-built `[]` + 4-edge-pinned fill-pane child
/// fills the 860pt height instead of flattening to ≈276.
///
/// ── Regime B (input bar): width is load-bearing ──────────────────────
/// The chat resting bar is a hosted SwiftUI component centered + width-
/// capped at `maxHostWidth = BlockStyle.maxLayoutWidth + 2 *
/// detailHorizontalInset = 820`. The snapshot renders at a width (1100)
/// wider than the cap so a human can confirm the bar is horizontally
/// centered and does NOT stretch edge-to-edge.
@MainActor
final class AppKitSwiftUIBoundarySnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Shared fixture (parallel-safe: all in-memory deps, fresh per test)

    private struct Fixture {
        let model: MainSelectionModel
        let manager: SessionManager
        let router: DetailRouterViewController
        let sessionIds: [String]
        /// The six deps the router was built from, retained so the same
        /// set can build a standalone `ChatSessionViewController` for the
        /// input-bar snapshot.
        let deps: Deps
    }

    private struct Deps {
        let recentProjects: RecentProjectsStore
        let notifications: NotificationService
        let syntaxEngine: SyntaxHighlightEngine
        let searchBus: TranscriptSearchBus
        let inputDraftStore: InputDraftStore
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

        // Unique UserDefaults suite + teardown — never UserDefaults.standard.
        let defaultsSuite = "ccterm-boundary-snap-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: defaultsSuite) }
        let recentProjects = RecentProjectsStore(defaults: defaults)
        let activation = AppActivationTracker()
        let notifications = NotificationService(activation: activation)
        let syntaxEngine = SyntaxHighlightEngine()
        let searchBus = TranscriptSearchBus()
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ccterm-boundary-snap-\(UUID().uuidString)", isDirectory: true)
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

        return Fixture(
            model: model,
            manager: manager,
            router: router,
            sessionIds: ids,
            deps: Deps(
                recentProjects: recentProjects,
                notifications: notifications,
                syntaxEngine: syntaxEngine,
                searchBus: searchBus,
                inputDraftStore: inputDraftStore))
    }

    private func drainMainLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// Pumps BOTH schedulers — the AppKit runloop (autolayout / CA flush)
    /// and the Swift-concurrency MainActor executor (the router's
    /// observation-task re-arm + the SwiftUI child `.task`). Mirrors
    /// `DetailRouterLayoutDiagnosticsTests.settle()`; not a sleep-for-sync,
    /// a fixed-iteration runloop pump to let layout/CA settle.
    private func settle(iterations: Int = 14) async {
        for _ in 0..<iterations {
            try? await Task.sleep(for: .milliseconds(40))
            drainMainLoop(seconds: 0.02)
        }
    }

    /// Snapshot an already-mounted `NSView` directly (NOT via
    /// `ViewSnapshot.renderViewController`, which creates its OWN window and
    /// re-mounts the VC — that would render before any `.archive` selection
    /// + router swap has been driven). The view must already have a real
    /// frame and settled layout when this is called.
    private func snapshot(_ view: NSView) -> NSImage {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("snapshot: bitmapImageRepForCachingDisplay returned nil")
            return NSImage(size: view.bounds.size)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func attach(_ url: URL, name: String) {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Regime A — archive fill-pane, large window (visual)

    /// Render the archive page inside a large (1200×860) split-rooted
    /// window. A correctly-built fill-pane child fills the 860pt height; a
    /// regressed (default-`sizingOptions`) child would flatten to ≈276 and
    /// the PNG would show a squashed window. The window size is the
    /// evidence — see the class doc.
    func testArchiveInLargeWindow() async throws {
        let fx = makeFixture(sessionCount: 0)
        fx.model.selection = .newSession

        // Real two-item split as the window's contentViewController — the
        // production shape that makes a fill-pane fitting-size leak
        // observable (a bare VC as content collapses regardless).
        let split = NSSplitViewController()
        let sidebarVC = NSViewController()
        sidebarVC.view = NSView()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 220
        split.addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: fx.router)
        detailItem.minimumThickness = 680
        split.addSplitViewItem(detailItem)

        // Load-bearing: a LARGE window. A small/flat window renders at ≈ the
        // collapse size on both broken and fixed code, so it proves nothing.
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
        // Drive the real router swap to the archive page, then settle so the
        // ArchiveView `.task` + autolayout land BEFORE we snapshot.
        fx.model.select(.archive)
        await settle()

        XCTAssertTrue(
            fx.router.currentChild is ArchiveViewController,
            "router did not swap to ArchiveViewController — snapshot would capture the "
                + "wrong child")

        // Snapshot the already-mounted split content directly (MF-4: do NOT
        // route the pre-selected flow through renderViewController).
        let image = snapshot(split.view)
        let url = ViewSnapshot.writePNG(image, name: "ArchiveBoundary-LargeWindow")
        attach(url, name: "ArchiveBoundary-LargeWindow.png")

        // Plausibility only — the human opens the PNG to confirm the archive
        // list fills the pane (not collapsed). A flattened window would also
        // shrink the rendered height; assert it stayed tall as a cheap
        // secondary signal.
        XCTAssertGreaterThanOrEqual(image.size.width, 1100)
        XCTAssertGreaterThanOrEqual(
            image.size.height, 760,
            "rendered window collapsed to \(image.size.height)pt — fill-pane child is "
                + "leaking its fitting size up the split")
    }

    // MARK: - Regime B — input bar centered + width-capped (visual)

    /// Render the chat resting bar inside a wide (1100pt) detail pane. The
    /// human opens the PNG to confirm the bar is horizontally centered and
    /// width-capped at 820pt — NOT stretched edge-to-edge. Width is the
    /// load-bearing dimension (1100 > the 820 cap), so the centering +
    /// inset gap is visible.
    func testInputBarCentered() async throws {
        let fx = makeFixture(sessionCount: 1)
        let sid = fx.sessionIds[0]
        // Materialize the session so the resting-bar branch of
        // ChatComposeStack.content(for:) renders (it returns EmptyView for
        // every selection except `.session(_)`).
        guard fx.manager.session(sid) != nil else {
            XCTFail("session materialization failed")
            return
        }
        fx.model.selection = .session(sid)

        let chat = ChatSessionViewController(
            model: fx.model,
            sessionManager: fx.manager,
            recentProjects: fx.deps.recentProjects,
            notifications: fx.deps.notifications,
            searchEngine: fx.deps.syntaxEngine,
            searchBus: fx.deps.searchBus,
            inputDraftStore: fx.deps.inputDraftStore)

        // Mount into a sized container so the VC gets a real frame; width
        // (1100) > maxHostWidth cap (820) is what makes centering visible.
        let size = CGSize(width: 1100, height: 800)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        chat.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chat.view)
        NSLayoutConstraint.activate([
            chat.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chat.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chat.view.topAnchor.constraint(equalTo: container.topAnchor),
            chat.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        defer {
            window.contentView = nil
            window.close()
        }

        await settle()
        // Drive the production attach path so the resting bar renders.
        chat.present(sessionId: sid)
        await settle()

        let image = snapshot(container)
        let url = ViewSnapshot.writePNG(image, name: "InputBar-Centered")
        attach(url, name: "InputBar-Centered.png")

        // Plausibility only — the human confirms the bar is centered.
        XCTAssertGreaterThanOrEqual(image.size.width, 1000)
    }
}

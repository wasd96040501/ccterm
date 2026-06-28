import AgentSDK
import AppKit
import Observation
import SwiftUI
import XCTest

@testable import ccterm

/// CI-gate measurement probe (NOT a `*SnapshotTests` file → runs on the
/// default suite as a merge gate) for the **regime-B** AppKit↔SwiftUI
/// boundary: the merged bottom cluster
/// (`ChatSessionViewController.bottomClusterHost`) must be **full-width,
/// bottom-anchored, and content-height** — its **height** driven by the
/// content (`sizingOptions = [.intrinsicContentSize]`), never pane-filling.
///
/// Subject under test: `ChatSessionViewController.bottomClusterHost` — the
/// always-mounted `NSHostingView<ChatBottomClusterRoot>` that renders the fade
/// + input bar + permission card in one SwiftUI tree. Its constraint recipe
/// (`ChatSessionViewController.swift` `loadView()`):
///
/// - `leading == view.leading`   (full-width: the fade is full-width)
/// - `trailing == view.trailing` (full-width)
/// - `bottom == view.bottom`     (bottom-anchored)
/// - height: NONE — `[.intrinsicContentSize]` lets the content drive it.
///
/// The bar's horizontal centering + width cap (`composeMaxWidth` = 512) and the
/// card's cap (`BlockStyle.maxLayoutWidth` = 780) now happen *inside* the
/// SwiftUI tree (`ChatRestingBar` / the card layer), not on the host's frame —
/// so the host frame fills the pane width, and the regime-B property the host
/// itself must satisfy is purely **bottom-anchored + content-height**.
///
/// **Canonical conclusion (baked in so the gate documents the rule):** a
/// full-width, bottom-anchored host with `[.intrinsicContentSize]` height is
/// the canonical "bottom band over a transcript" pattern. It is strictly
/// better than the discarded `GeometryReader` + `PreferenceKey` +
/// manual-height-constraint hack (root `CLAUDE.md`, "Embedding SwiftUI in
/// AppKit: host sizing"): the host's own intrinsic content size supplies the
/// height for free, with no window-collapse risk because the component never
/// pins 4 edges into a split and never governs its container's size. The
/// DEBUG `PermissionSessionDemoViewController` host used to be the legacy
/// hand-rolled shape; it now follows this exemplar too.
///
/// We run the VC at two widths (the regime is width-agnostic now, but the two
/// legs document that the full-width host tracks the pane), plus a third
/// **card-present** leg that asserts the card grows the host upward without
/// moving the bar's bottom anchor — the PR#235→#281 "card pumps / lifts the
/// bar" regression guard.
@MainActor
final class HostedComponentCenteringTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Fixture

    private struct Fixture {
        let model: MainSelectionModel
        let manager: SessionManager
        let vc: ChatSessionViewController
        let sessionId: String
    }

    /// Builds a real `ChatSessionViewController` with the same six injected
    /// in-memory deps the router fixture uses (no `*.shared`, no
    /// `UserDefaults.standard`, no `NotificationCenter.default`; unique
    /// `UserDefaults(suiteName:)` + temp dir, both torn down). A single
    /// `.created`-status record is saved so `present(sessionId:)` attaches an
    /// active-phase session and `ChatBottomCluster.content(for:)` renders the
    /// `.chat` branch (the resting bar + card) — NOT `EmptyView`.
    private func makeFixture() -> Fixture {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        repo.save(
            SessionRecord(
                sessionId: sid, title: "Centering", cwd: "/tmp/centering", status: .created))
        let manager = SessionManager(
            repository: repo, cliClientFactory: { _ in FakeCLIClient() })

        let defaultsSuite = "ccterm-centering-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: defaultsSuite) }
        let recentProjects = RecentProjectsStore(defaults: defaults)
        let syntaxEngine = SyntaxHighlightEngine()
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-centering-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: draftDir) }
        let inputDraftStore = InputDraftStore(directory: draftDir, debounceInterval: 0.05)

        let model = MainSelectionModel()
        let vc = ChatSessionViewController(
            context: DetailContext(
                model: model,
                sessionManager: manager,
                recentProjects: recentProjects,
                inputDraftStore: inputDraftStore,
                syntaxEngine: syntaxEngine))

        return Fixture(model: model, manager: manager, vc: vc, sessionId: sid)
    }

    // MARK: - Runloop pump (no sleep-for-sync; fixed pump to settle layout)

    private func drainMainLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// Pumps both the AppKit runloop (autolayout / CA flush) and the
    /// Swift-concurrency MainActor executor (the bar's SwiftUI `.task`
    /// restore + body re-eval). Matches `DetailRouterLayoutDiagnosticsTests`.
    private func settle(iterations: Int = 14) async {
        for _ in 0..<iterations {
            try? await Task.sleep(for: .milliseconds(40))
            drainMainLoop(seconds: 0.02)
        }
    }

    /// Mounts `vc` pinned edge-to-edge into a `size`-sized container that is
    /// the content of an offscreen, alpha-0.01 window (so the VC's view gets
    /// a real production-style frame and its SwiftUI host computes `body`).
    /// Selects the session BEFORE mounting so the resting-bar branch is the
    /// one that renders, then drives the real `present(sessionId:)` attach.
    /// Returns the window so the caller can tear it down.
    private func mount(_ fx: Fixture, size: CGSize) async -> NSWindow {
        // The cluster renders `EmptyView` for every selection except
        // `.session(_)`. Set the selection that matches the id we present so
        // `ChatBottomCluster` renders the bar + card — a degenerate EmptyView
        // host would make the asserts meaningless.
        fx.model.selection = .session(fx.sessionId)

        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        // LOCK the window frame so the pane stays exactly `size.width` —
        // a borderless window otherwise adopts its content's fitting width.
        window.minSize = size
        window.maxSize = size

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        // Pin the container to an explicit size with REQUIRED constraints so
        // neither the window's content-fitting adoption nor the content can
        // widen the pane past `size.width`. A self-sized container is the
        // production-faithful stand-in for the split detail item, whose width
        // the split — not the content — governs.
        container.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = container
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: size.width),
            container.heightAnchor.constraint(equalToConstant: size.height),
        ])
        window.ccterm_orderFrontForTesting()

        fx.vc.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(fx.vc.view)
        NSLayoutConstraint.activate([
            fx.vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fx.vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fx.vc.view.topAnchor.constraint(equalTo: container.topAnchor),
            fx.vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()

        await settle()

        // The router calls `present` only on a mounted+framed VC; mirror that
        // here so the transcript attach (and the cluster host's body) run
        // against the settled frame.
        fx.vc.present(sessionId: fx.sessionId)
        await settle()
        fx.vc.view.layoutSubtreeIfNeeded()

        return window
    }

    /// Seed a pending permission onto the shown session's runtime, the same
    /// way the production CLI sink does, so `ChatBottomCluster` mounts the
    /// card layer above the bar after a runloop drain.
    @discardableResult
    private func seedPermission(_ fx: Fixture, requestId: String) -> Bool {
        guard let session = fx.manager.session(fx.sessionId),
            case .active(let runtime) = session.phase
        else { return false }
        let request = PermissionRequest.makePreview(
            requestId: requestId, toolName: "Bash", input: ["command": "rm -rf build"])
        runtime.pendingPermissions.append(
            PendingPermission(id: requestId, request: request, respond: { _ in }))
        return true
    }

    // MARK: - WIDE leg — full-width host tracks a wide pane

    func testBottomClusterIsFullWidthAndBottomAnchoredInWidePane() async throws {
        let fx = makeFixture()
        let size = CGSize(width: 1100, height: 800)
        let window = await mount(fx, size: size)
        defer {
            window.contentView = nil
            window.close()
        }

        let host = fx.vc.bottomClusterHost!
        let bounds = fx.vc.view.bounds
        let frame = host.frame

        attachReport(name: "bottom-cluster-wide-pane", host: host, bounds: bounds)

        // The chat branch actually rendered (not a degenerate EmptyView).
        XCTAssertGreaterThan(
            host.fittingSize.height, 0,
            "Cluster host rendered an empty/degenerate body — the `.chat` branch did not render. "
                + "Did model.selection match the presented session id?")

        // Full-width: the host spans the whole pane (the fade is full-width).
        XCTAssertEqual(
            frame.width, bounds.width, accuracy: 1,
            "Wide pane: cluster host should be full-width (got \(frame.width) vs pane \(bounds.width)).")
        XCTAssertEqual(
            frame.minX, bounds.minX, accuracy: 1,
            "Wide pane: cluster host leading should meet the pane leading.")

        assertBottomAnchoredAndComponentHeight(host: host, bounds: bounds, leg: "wide")
    }

    // MARK: - NARROW leg — full-width host tracks a narrow pane

    func testBottomClusterIsFullWidthAndBottomAnchoredInNarrowPane() async throws {
        let fx = makeFixture()
        // 680 is the split detail minimum (MainSplitViewController).
        let size = CGSize(width: 680, height: 800)
        let window = await mount(fx, size: size)
        defer {
            window.contentView = nil
            window.close()
        }

        let host = fx.vc.bottomClusterHost!
        let bounds = fx.vc.view.bounds
        let frame = host.frame

        attachReport(name: "bottom-cluster-narrow-pane", host: host, bounds: bounds)

        XCTAssertGreaterThan(
            host.fittingSize.height, 0,
            "Cluster host rendered an empty/degenerate body — the `.chat` branch did not render.")

        // No overflow + full-width on the narrow pane too.
        XCTAssertEqual(
            frame.width, bounds.width, accuracy: 1,
            "Narrow pane: cluster host should be full-width (got \(frame.width) vs pane \(bounds.width)).")
        XCTAssertGreaterThanOrEqual(
            frame.minX, -0.5,
            "Narrow pane: cluster host leading escaped the pane (minX \(frame.minX) < 0).")

        assertBottomAnchoredAndComponentHeight(host: host, bounds: bounds, leg: "narrow")
    }

    // MARK: - CARD-PRESENT leg — card grows the host upward, bar anchor unmoved

    /// Seeds a pending permission and asserts the merged-tree invariant that
    /// motivated this refactor: the card composites ABOVE the bar in the same
    /// host, so the host grows TALLER (its top floats up) while its BOTTOM
    /// edge — where the bar sits — stays anchored. A regression that lets the
    /// card pump / lift the bar would move the host's bottom edge (or balloon
    /// the height past a sane bound). Height must stay bounded (NOT full-pane).
    func testPermissionCardGrowsHostUpwardWithoutMovingBarAnchor() async throws {
        let fx = makeFixture()
        let size = CGSize(width: 1100, height: 800)
        let window = await mount(fx, size: size)
        defer {
            window.contentView = nil
            window.close()
        }

        let host = fx.vc.bottomClusterHost!
        let bounds = fx.vc.view.bounds

        // Baseline (no card): record the host frame.
        let baseFrame = host.frame
        XCTAssertGreaterThan(host.fittingSize.height, 0, "baseline bar did not render")

        // Seed the card and let the cluster mount the card layer.
        XCTAssertTrue(seedPermission(fx, requestId: "perm-grow"), "could not seed permission")
        await settle(iterations: 10)
        fx.vc.view.layoutSubtreeIfNeeded()
        let cardFrame = host.frame

        let report = """
            pane bounds   = \(bounds)
            base host     = \(baseFrame)
            card host     = \(cardFrame)
            base height   = \(baseFrame.height)  card height = \(cardFrame.height)
            base bottomY  = \(baseFrame.minY)    card bottomY = \(cardFrame.minY)
            """
        let attachment = XCTAttachment(string: report)
        attachment.name = "bottom-cluster-card-present"
        attachment.lifetime = .keepAlways
        add(attachment)

        // The card grew the host taller.
        XCTAssertGreaterThan(
            cardFrame.height, baseFrame.height + 20,
            "card should grow the cluster host taller (base \(baseFrame.height) → card "
                + "\(cardFrame.height)) — the card layer did not mount or did not add height.")

        // …but stays bounded — never full-pane (regime-B intrinsic height).
        XCTAssertLessThan(
            cardFrame.height, bounds.height * 0.9,
            "card-present cluster host (\(cardFrame.height)) is near pane height "
                + "(\(bounds.height)) — the host wrongly filled the pane instead of sizing to content.")

        // The bottom anchor is invariant: the bar sits at the host's bottom
        // edge, which must NOT move when the card grows the host upward. The
        // window/container is non-flipped, so the host's bottom edge is its
        // `minY`. Equal base vs card ⇒ the bar's `frame.minY` is unchanged.
        XCTAssertEqual(
            cardFrame.minY, baseFrame.minY, accuracy: 1,
            "the card moved the cluster host's bottom edge (base minY \(baseFrame.minY) → "
                + "card \(cardFrame.minY)) — the bar's bottom anchor must not move (the card grows "
                + "UPWARD, never lifts the bar).")
    }

    // MARK: - Shared assertions

    /// Asserts the regime-B invariants the host itself must satisfy: it is
    /// bottom-anchored, and its height is a small component height (NOT the
    /// full pane) — i.e. the content drives the cross-axis via
    /// `[.intrinsicContentSize]`, the host does not fill the pane.
    private func assertBottomAnchoredAndComponentHeight(
        host: NSView, bounds: CGRect, leg: String
    ) {
        // Bottom-anchored: in the non-flipped container the bar sits at the
        // bottom edge (frame.minY ≈ 0). Compare the closer of the two edges to
        // the pane's nearer edge to be flippedness-agnostic.
        let distanceToBottom = min(
            abs(host.frame.minY - bounds.minY), abs(host.frame.maxY - bounds.maxY))
        XCTAssertLessThanOrEqual(
            distanceToBottom, 1,
            "\(leg): cluster host is not bottom-anchored — nearest edge is "
                + "\(distanceToBottom)pt from the pane's bottom (frame \(host.frame)).")

        // Component height tied to the bar's real intrinsic height — NOT a
        // fraction of the pane. The resting bar + fade band is ~tens-to-100pt;
        // a pane-filling host would be ~800pt and fail this loudly. (The
        // separate card-present leg covers the larger-but-still-bounded case.)
        XCTAssertLessThan(
            host.frame.height, 250,
            "\(leg): cluster host height (\(host.frame.height)) is far larger than the bar's "
                + "intrinsic height — the component is filling the pane instead of "
                + "shrinking to its content (the `[.intrinsicContentSize]` height regime failed).")
        XCTAssertLessThan(
            host.frame.height, bounds.height * 0.5,
            "\(leg): cluster host height (\(host.frame.height)) is at least half the pane "
                + "(\(bounds.height)) — not a subordinate component.")
    }

    private func attachReport(name: String, host: NSView, bounds: CGRect) {
        let report = """
            pane bounds      = \(bounds)
            vc view frame    = \(host.superview?.frame ?? .zero)
            window frame     = \(host.window?.frame ?? .zero)
            host frame       = \(host.frame)
            host fittingSize = \(host.fittingSize)
            host midX        = \(host.frame.midX)  pane midX = \(bounds.midX)
            """
        let attachment = XCTAttachment(string: report)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

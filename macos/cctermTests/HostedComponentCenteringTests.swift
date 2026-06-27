import AppKit
import Observation
import SwiftUI
import XCTest

@testable import ccterm

/// CI-gate measurement probe (NOT a `*SnapshotTests` file → runs on the
/// default suite as a merge gate) for the **regime-B** AppKit↔SwiftUI
/// boundary: a hosted SwiftUI component that must be horizontally
/// **centered + width-capped + bottom-anchored** inside the detail pane,
/// with its **height** driven by the content (`sizingOptions =
/// [.intrinsicContentSize]`).
///
/// Subject under test: `ChatSessionViewController.composeOrBarHost` — the
/// always-mounted `NSHostingView<AnyView>` that renders the chat resting
/// input bar. Its constraint recipe (`ChatSessionViewController.swift`
/// `loadView()`):
///
/// - `centerX == view.centerX`  (centered in the pane)
/// - `width <= maxHostWidth`    (required — never overflows the cap)
/// - `width == maxHostWidth`    (@high — fills up to the cap on a wide pane)
/// - `leading >= view.leading`  (yields the cap on a narrow pane so the bar
///                               shrinks to fit instead of overflowing)
/// - `bottom == view.bottom`    (bottom-anchored)
/// - height: NONE — `[.intrinsicContentSize]` lets the bar's content drive it.
///
/// where `maxHostWidth = BlockStyle.maxLayoutWidth (780) + 2 *
/// ChatSessionViewController.detailHorizontalInset (20) = 820`.
///
/// **Canonical conclusion (baked in so the gate documents the rule):**
/// this five-constraint recipe + `[.intrinsicContentSize]` for height is the
/// canonical "centered, width-capped, shrink-to-fit, bottom-anchored
/// component" pattern. It is strictly better than the discarded
/// `GeometryReader` + `PreferenceKey` + manual-height-constraint hack (root
/// `CLAUDE.md`, "Embedding SwiftUI in AppKit: host sizing"): the host's own
/// intrinsic content size supplies the missing dimension for free, with no
/// window-collapse risk because the component never pins 4 edges into a
/// split and never governs its container's size. The DEBUG
/// `PermissionSessionDemoViewController` host is the *legacy* hand-rolled
/// shape and should NOT be copied.
///
/// **Width is the load-bearing dimension here** (unlike the regime-A
/// collapse gate, which needs a tall window). We run the same VC at two
/// widths to exercise both branches of the width contract:
///   - WIDE (1100 > 820): the cap is reached → `frame.width == 820`.
///   - NARROW (680 < 820, the split detail minimum): the cap can't be met →
///     the bar shrinks (`width <= viewWidth`, `minX >= 0`) but stays centered.
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
    /// active-phase session and `ChatComposeStack.content(for:)` renders the
    /// `.chat` branch (the resting bar) — NOT `EmptyView`.
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
        let activation = AppActivationTracker()
        let notifications = NotificationService(activation: activation)
        let syntaxEngine = SyntaxHighlightEngine()
        let searchBus = TranscriptSearchBus()
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-centering-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: draftDir) }
        let inputDraftStore = InputDraftStore(directory: draftDir, debounceInterval: 0.05)

        let model = MainSelectionModel()
        let vc = ChatSessionViewController(
            model: model,
            sessionManager: manager,
            recentProjects: recentProjects,
            notifications: notifications,
            syntaxEngine: syntaxEngine,
            searchBus: searchBus,
            inputDraftStore: inputDraftStore)

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
        // MF-5: the bar host renders `EmptyView` for every selection except
        // `.session(_)`. Set the selection that matches the id we present so
        // `ChatComposeStack` renders the resting bar — a degenerate EmptyView
        // host would make the centering asserts meaningless.
        fx.model.selection = .session(fx.sessionId)

        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        // LOCK the window frame. A borderless window has no minSize and
        // otherwise ADOPTS its content's fitting width: the bar host's
        // `width == cap @high` makes the VC view's fittingSize.width == cap, so
        // an unlocked NARROW (680) window grows back to 820 and the
        // shrink-to-fit branch is never exercised (confirmed empirically). Pin
        // min == max == size so the pane stays exactly `size.width`.
        window.minSize = size
        window.maxSize = size

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        // Pin the container to an explicit size with REQUIRED constraints so
        // neither the window's content-fitting adoption nor the bar host's
        // `width == cap @high` can widen the pane past `size.width`. (Setting
        // `window.minSize/maxSize` alone did NOT hold a borderless offscreen
        // window — the content fitting still won.) A self-sized container is
        // the production-faithful stand-in for the split detail item, whose
        // width the split — not the content — governs.
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
        // here so the transcript attach (and the bar host's body) run against
        // the settled frame.
        fx.vc.present(sessionId: fx.sessionId)
        await settle()
        fx.vc.view.layoutSubtreeIfNeeded()

        return window
    }

    // MARK: - Expected cap (computed from the production constants)

    /// Recompute the 820 cap from the SAME internal constants production uses,
    /// so the gate stays in lockstep if either constant changes (rather than
    /// hardcoding 820).
    private var maxHostWidth: CGFloat {
        BlockStyle.maxLayoutWidth + 2 * ChatSessionViewController.detailHorizontalInset
    }

    // MARK: - WIDE leg — pane wider than the cap → width clamps to 820

    func testRestingBarCapsAndCentersInWidePane() async throws {
        let fx = makeFixture()
        // Wide pane: 1100 > maxHostWidth (820), so the `width == cap @high`
        // constraint wins and the host stops growing at the cap.
        let size = CGSize(width: 1100, height: 800)
        let window = await mount(fx, size: size)
        defer {
            window.contentView = nil
            window.close()
        }

        let host = fx.vc.composeOrBarHost!
        let bounds = fx.vc.view.bounds
        let frame = host.frame

        attachReport(
            name: "resting-bar-wide-pane",
            host: host, bounds: bounds, expectedCap: maxHostWidth)

        // MF-5: the chat branch actually rendered (not a degenerate EmptyView).
        XCTAssertGreaterThan(
            host.fittingSize.height, 0,
            "Bar host rendered an empty/degenerate body — the `.chat` branch did not render. "
                + "Did model.selection match the presented session id?")

        // Width capped at exactly maxHostWidth on a wide pane.
        XCTAssertEqual(
            frame.width, maxHostWidth, accuracy: 1,
            "Wide pane: bar host width should clamp to the cap "
                + "(\(maxHostWidth)), got \(frame.width).")

        // Horizontally centered in the pane.
        XCTAssertEqual(
            frame.midX, bounds.midX, accuracy: 1,
            "Wide pane: bar host should be horizontally centered "
                + "(midX \(frame.midX) vs pane midX \(bounds.midX)).")

        assertBottomAnchoredAndComponentHeight(host: host, bounds: bounds, leg: "wide")
    }

    // MARK: - NARROW leg — pane narrower than the cap → bar shrinks to fit

    func testRestingBarShrinksToFitAndCentersInNarrowPane() async throws {
        let fx = makeFixture()
        // Narrow pane: 680 (the split detail minimum, MainSplitViewController)
        // < maxHostWidth (820), so the cap can't be met and the bar yields to
        // `leading >= view.leading`, shrinking to fit instead of overflowing.
        let size = CGSize(width: 680, height: 800)
        let window = await mount(fx, size: size)
        defer {
            window.contentView = nil
            window.close()
        }

        let host = fx.vc.composeOrBarHost!
        let bounds = fx.vc.view.bounds
        let frame = host.frame

        attachReport(
            name: "resting-bar-narrow-pane",
            host: host, bounds: bounds, expectedCap: maxHostWidth)

        XCTAssertGreaterThan(
            host.fittingSize.height, 0,
            "Bar host rendered an empty/degenerate body — the `.chat` branch did not render.")

        // No overflow: width never exceeds the pane.
        XCTAssertLessThanOrEqual(
            frame.width, bounds.width + 1,
            "Narrow pane: bar host overflowed the pane "
                + "(width \(frame.width) > pane \(bounds.width)).")

        // The `leading >= view.leading` guard held — no negative inset.
        XCTAssertGreaterThanOrEqual(
            frame.minX, -0.5,
            "Narrow pane: bar host leading escaped the pane "
                + "(minX \(frame.minX) < 0) — the `leading >=` guard failed.")

        // Still centered.
        XCTAssertEqual(
            frame.midX, bounds.midX, accuracy: 1,
            "Narrow pane: bar host should still be horizontally centered "
                + "(midX \(frame.midX) vs pane midX \(bounds.midX)).")

        assertBottomAnchoredAndComponentHeight(host: host, bounds: bounds, leg: "narrow")
    }

    // MARK: - Shared assertions for both legs

    /// Asserts the two regime-B invariants common to both widths: the host is
    /// bottom-anchored, and its height is a small component height (NOT the
    /// full pane) — i.e. the content drives the cross-axis via
    /// `[.intrinsicContentSize]`, the host does not fill the pane.
    private func assertBottomAnchoredAndComponentHeight(
        host: NSView, bounds: CGRect, leg: String
    ) {
        // Bottom-anchored: in AppKit's flipped-by-default-no view space the
        // window/container is non-flipped, so the bar sits at the bottom edge
        // (frame.minY ≈ 0). Assert the host's bottom edge meets the pane's
        // bottom edge regardless of flippedness by comparing the closer of the
        // two edges to the pane's nearer edge.
        let distanceToBottom = min(abs(host.frame.minY - bounds.minY), abs(host.frame.maxY - bounds.maxY))
        XCTAssertLessThanOrEqual(
            distanceToBottom, 1,
            "\(leg): bar host is not bottom-anchored — nearest edge is "
                + "\(distanceToBottom)pt from the pane's bottom (frame \(host.frame)).")

        // MF-6: tighten the component-height bound to a concrete value tied to
        // the bar's real intrinsic height — NOT a fraction of the pane (a bar
        // that wrongly grew to fill an 800pt pane could pass a `< 0.5 * pane`
        // check). The resting bar is ~tens of pt; production's bottom fade
        // scrim (`bottomFadeScrimHeight = 100`) brackets the bar's top edge,
        // so a healthy bar is well under ~250pt. A pane-filling host would be
        // ~800pt and fail this loudly.
        XCTAssertLessThan(
            host.frame.height, 250,
            "\(leg): bar host height (\(host.frame.height)) is far larger than the bar's "
                + "intrinsic height — the component is filling the pane instead of "
                + "shrinking to its content (the `[.intrinsicContentSize]` height regime failed).")
        XCTAssertLessThan(
            host.frame.height, bounds.height * 0.5,
            "\(leg): bar host height (\(host.frame.height)) is at least half the pane "
                + "(\(bounds.height)) — not a subordinate component.")
    }

    private func attachReport(
        name: String, host: NSView, bounds: CGRect, expectedCap: CGFloat
    ) {
        let report = """
            pane bounds      = \(bounds)
            vc view frame    = \(host.superview?.frame ?? .zero)
            window frame     = \(host.window?.frame ?? .zero)
            host frame       = \(host.frame)
            host fittingSize = \(host.fittingSize)
            expected cap     = \(expectedCap)
            host midX        = \(host.frame.midX)  pane midX = \(bounds.midX)
            """
        let attachment = XCTAttachment(string: report)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import AppKit
import Observation
import SwiftUI
import XCTest

@testable import ccterm

/// CI-gate measurement probes for the **regime A** boundary situation —
/// a SwiftUI tree hosted as a *fill-the-pane* detail child of the main
/// split.
///
/// ## The boundary situation under test
///
/// An `NSHostingController` / `NSHostingView` with **default**
/// `sizingOptions` publishes the SwiftUI body's `view.fittingSize` as an
/// intrinsic size. When that host is the detail item of an
/// `NSSplitViewController` (the production detail shape), the small fitting
/// size leaks *up the split* into the window's constraint solver
/// (`_changeWindowFrameFromConstraintsIfNecessary`) and **collapses the
/// window height** to the content's ideal — the archive "squashed window"
/// the user reported. The fix is regime A's recipe:
/// `sizingOptions = []` (publish no intrinsic size) + pin all four edges
/// so the *container* drives the host's size. See `mountFillPaneHost`
/// (`MountFillPaneHost.swift`) for the canonical implementation, and
/// `ArchiveViewController.viewDidLoad` for the ≈ 545×276 fittingSize-leak
/// measurement comment at its call site.
///
/// ## Why this file is NOT a copy of the existing archive gate
///
/// The archive height-collapse on the **fixed production path** is already
/// a CI merge gate:
/// `DetailRouterLayoutDiagnosticsTests.testArchiveSelectionDoesNotFlattenWindow`.
/// Duplicating it would be dead weight, so this file deliberately does
/// NOT re-test the fixed archive path. It covers the parts that gate does
/// **not**:
///
///   - `testDefaultSizingOptionsHostCollapsesWindowInLargeSplit` — the
///     genuinely-new *teeth*: an A/B over the production
///     `ArchiveViewController` containment shape (host nested in a plain
///     detail VC, 4-edge pinned, inside a real split in the large window)
///     that isolates `sizingOptions` as the leak source. The
///     regime-discriminating, offscreen-observable dimension is the
///     **published** intrinsic/preferred size the host hands the window's
///     constraint solver: default options ⇒ ≈ 276 (the leak the live solver
///     consumes), `[]` ⇒ 0. The window *frame* is also sampled (and a
///     content-adopting window does collapse to its minSize clamp), but the
///     attached report documents — from this investigation — that the
///     window-frame dimension is NOT regime-discriminating *offscreen*:
///     once `setContentSize` is asserted the frame is sticky for both
///     regimes, and the content-adopt path collapses both. The live-app
///     collapse the user saw is the autosize/autosave +
///     `_changeWindowFrameFromConstraintsIfNecessary` pass the offscreen
///     window does not run; the `published` leak is its offscreen-stable
///     proxy. The host + body are built inline, so no production
///     `sizingOptions` is mutated (production-code rule).
///   - `testSizingRegimeGovernsPublishedFittingSize` — the cheap unit fact
///     underneath the collapse: default options publish a small fitting
///     height; `[]` publishes ≈ 0. Honestly labelled — it asserts the
///     *measurement dimension responds to the regime*, not that a window
///     collapses (that is the test above).
///   - `testComposeAndDraftLandingFillPanesDoNotCollapse` — the regime-A
///     no-collapse contract for the *other two* production fill-pane
///     children (`ComposeSessionViewController`,
///     `DraftSessionLandingViewController`), which the archive gate does
///     not exercise. Both must hold the window height AND publish
///     `fittingSize.height ≈ 0`.
///   - `testArchiveBindingWriteStaysHeightNeutral` — proves the two-way
///     `model.archiveSelectedFolderPath` binding is NOT the collapse
///     cause: under the fixed `[]` regime a binding-driven body re-eval
///     republishes no intrinsic size, so a folder-filter write is
///     height-neutral. (Under a *leaking* regime that same binding is the
///     "pump" that re-trips the collapse — which is why the user perceived
///     "two-way binding squashed the window." The regime, not the binding,
///     is the root cause.)
///
/// ## The window size is load-bearing evidence
///
/// Every collapse probe mounts in a **large** 1200×860 window with
/// `minSize` height 540. The collapse target is ≈ 276pt. The healthy
/// height (860) must *dwarf* the collapse target, and `minSize.height`
/// (540) must sit *strictly between* them, so AppKit's `minSize` clamp
/// cannot mask a partial collapse and the drop to ≈ 276 is unambiguous.
/// A small/flat window (~600×300) CANNOT detect this — the collapsed size
/// would be ≈ the starting size and the assertion would pass on both
/// broken and fixed code. The large window IS part of the evidence.
@MainActor
final class AppKitSwiftUIBoundaryTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Shared fixture
    //
    // Mirrors `DetailRouterLayoutDiagnosticsTests.makeFixture` — fresh
    // in-memory deps per test, unique UserDefaults suite + temp dir with
    // teardown, no `.shared`, no `NotificationCenter.default`. Copied
    // (not factored into a base) because XCTest forks a process per class.

    private struct Fixture {
        let model: MainSelectionModel
        let manager: SessionManager
        let router: DetailRouterViewController
        let sessionIds: [String]
        /// A session id whose persisted record has `status == .draft`, so
        /// `.session(draftId)` routes to `DraftSessionLandingViewController`
        /// (not the transcript). Required because a `.created` id routes to
        /// `ChatSessionViewController` and would silently test the wrong
        /// child.
        let draftSessionId: String
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
        // A dedicated `.draft`-status record so the draft-landing leg
        // mounts `DraftSessionLandingViewController` (MF-3).
        let draftId = UUID().uuidString
        repo.save(
            SessionRecord(
                sessionId: draftId, title: "", cwd: "/tmp/draft",
                originPath: "/tmp/draft", status: .draft))

        let manager = SessionManager(
            repository: repo, cliClientFactory: { _ in FakeCLIClient() })

        let defaultsSuite = "ccterm-boundary-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: defaultsSuite) }
        let recentProjects = RecentProjectsStore(defaults: defaults)
        let activation = AppActivationTracker()
        let notifications = NotificationService(activation: activation)
        let syntaxEngine = SyntaxHighlightEngine()
        let searchBus = TranscriptSearchBus()
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-boundary-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: draftDir) }
        let inputDraftStore = InputDraftStore(directory: draftDir, debounceInterval: 0.05)

        let model = MainSelectionModel()
        let router = DetailRouterViewController(
            model: model,
            sessionManager: manager,
            recentProjects: recentProjects,
            notifications: notifications,
            syntaxEngine: syntaxEngine,
            searchBus: searchBus,
            inputDraftStore: inputDraftStore)

        return Fixture(
            model: model, manager: manager, router: router,
            sessionIds: ids, draftSessionId: draftId)
    }

    private func drainMainLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// Pumps BOTH schedulers — the AppKit runloop (autolayout / CA flush)
    /// AND the Swift-concurrency MainActor executor (the router's
    /// selection-observation re-arm + each child's `.task`). The router
    /// only swaps after its observation Task resumes, which `RunLoop.run`
    /// alone does not drive. This is a fixed-iteration runloop *pump* to
    /// let layout/CA settle — not a `sleep`-on-a-condition synchronization
    /// barrier (the established `DetailRouterLayoutDiagnosticsTests`
    /// idiom).
    private func settle(iterations: Int = 14) async {
        for _ in 0..<iterations {
            try? await Task.sleep(for: .milliseconds(40))
            drainMainLoop(seconds: 0.02)
        }
    }

    // MARK: - Large-window factory (the load-bearing evidence)

    /// Builds the production detail shape — `detailVC` as the detail item
    /// of a real two-item `NSSplitViewController` that is the window's
    /// `contentViewController` — inside the **large 1200×860** window that
    /// makes a collapse to ≈ 276 unambiguous. The split shape matters: a
    /// bare VC as `contentViewController` collapses regardless; the split
    /// is what makes a child's leaked fitting size observable as a window
    /// resize. Returns the window (caller tears it down).
    private func makeLargeSplitWindow(detailVC: NSViewController) -> NSWindow {
        let split = NSSplitViewController()
        let sidebarVC = NSViewController()
        sidebarVC.view = NSView()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 220
        split.addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: detailVC)
        detailItem.minimumThickness = 680
        split.addSplitViewItem(detailItem)

        // LOAD-BEARING: 860 healthy height dwarfs the ≈ 276 collapse
        // target; minSize height 540 sits strictly between, so the
        // min-clamp cannot mask a partial collapse. A small window cannot
        // detect this regression.
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
        return window
    }

    // MARK: - Teeth: an A/B that isolates the regime as the collapse cause

    /// Faithful stand-in for `ArchiveView`'s root: a `ScrollView` whose ideal
    /// (fitting) height is just a small header — the small size that leaks.
    /// `frame(maxWidth: .infinity)` so width fills; height is the content's
    /// ideal.
    private func archiveLikeBody() -> AnyView {
        AnyView(
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Archived sessions")
                        .font(.title2)
                        .padding(.bottom, 8)
                    Text("A small header is the only intrinsic content.")
                    Spacer(minLength: 24)
                }
                .frame(minWidth: 480, maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
            }
        )
    }

    /// Builds the production `ArchiveViewController` containment shape — an
    /// `NSHostingController` nested in a plain detail VC, 4-edge pinned, as the
    /// detail item of a real split — and measures the THREE dimensions that
    /// matter, for a given `sizingOptions` regime:
    ///
    ///   - `published`: the host's `preferredContentSize`/`fittingSize` height
    ///     — the value the window's constraint solver consumes. THIS is the
    ///     leak. Default options ⇒ ≈ 276 (the content ideal); `[]` ⇒ 0.
    ///   - `adoptHeight`: the window height when the split is installed as
    ///     `contentViewController` with **no** explicit frame, so the window
    ///     *adopts* its content's size at first layout.
    ///   - `stickyHeight`: the window height when an explicit
    ///     `setContentSize(860)` is asserted after install.
    ///
    /// ## What the harness CAN and CANNOT prove (load-bearing honesty)
    ///
    /// Investigation result (see `docs/refactor/boundary`): in the **offscreen
    /// XCTest** environment the window *frame* is NOT a regime-discriminating
    /// signal. Empirically, for BOTH regimes:
    ///   - adopt path  ⇒ 540 (the `minSize` clamp — the SwiftUI ScrollView
    ///     body supplies no height, so neither regime fills it), and
    ///   - sticky path ⇒ 860 (an explicit `setContentSize` makes the frame
    ///     "sticky"; the fitting-size leak does not pull it down afterward).
    /// The *live-app* collapse the user reported is driven by the window's
    /// autosize/autosave + a live `_changeWindowFrameFromConstraintsIfNecessary`
    /// pass that the offscreen window does not run. So the genuinely
    /// regime-discriminating, offscreen-observable dimension is **`published`**
    /// — the intrinsic/preferred size the host hands the solver. That is the
    /// leak; `[]` zeroes it (the fix), default options expose it (the bug).
    /// We assert all three so the report documents the full picture.
    ///
    /// No production `sizingOptions` is mutated — host + body are test-local
    /// (production-code rule).
    private func probeRegime(
        clearSizing: Bool
    ) async -> (
        published: CGFloat, adoptHeight: CGFloat, stickyHeight: CGFloat
    ) {
        func makeSplitWithHost() -> (NSSplitViewController, NSHostingController<AnyView>) {
            let host = NSHostingController(rootView: archiveLikeBody())
            if clearSizing { host.sizingOptions = [] }  // regime-A fix
            // EXACT production `ArchiveViewController` containment: host is a
            // child VC of the detail VC (not the detail item itself), pinned
            // 4-edge.
            let detailVC = NSViewController()
            detailVC.view = NSView()
            host.view.translatesAutoresizingMaskIntoConstraints = false
            detailVC.addChild(host)
            detailVC.view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: detailVC.view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: detailVC.view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: detailVC.view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: detailVC.view.bottomAnchor),
            ])
            let split = NSSplitViewController()
            let sidebarVC = NSViewController()
            sidebarVC.view = NSView()
            let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
            sidebarItem.minimumThickness = 220
            split.addSplitViewItem(sidebarItem)
            let detailItem = NSSplitViewItem(viewController: detailVC)
            detailItem.minimumThickness = 680
            split.addSplitViewItem(detailItem)
            return (split, host)
        }

        func makeLargeWindow() -> NSWindow {
            // LARGE window: 860 healthy height dwarfs the 540 minSize clamp;
            // 540 sits strictly between, so a small/flat window could not tell
            // a collapse from the start size. The window IS the evidence.
            let size = CGSize(width: 1200, height: 860)
            let window = NSWindow(
                contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 880, height: 540)
            window.alphaValue = 0.01
            return window
        }

        // --- published leak + adopt-path height (NO setContentSize) ---
        let (adoptSplit, adoptHost) = makeSplitWithHost()
        let adoptWindow = makeLargeWindow()
        adoptWindow.contentViewController = adoptSplit
        adoptWindow.ccterm_orderFrontForTesting()
        defer {
            adoptWindow.contentViewController = nil
            adoptWindow.close()
        }
        await settle()
        let published = max(
            adoptHost.preferredContentSize.height, adoptHost.view.fittingSize.height)
        let adoptHeight = adoptWindow.frame.height

        // --- sticky-path height (explicit setContentSize after install) ---
        let (stickySplit, _) = makeSplitWithHost()
        let stickyWindow = makeLargeWindow()
        stickyWindow.contentViewController = stickySplit
        stickyWindow.setContentSize(CGSize(width: 1200, height: 860))
        stickyWindow.ccterm_orderFrontForTesting()
        defer {
            stickyWindow.contentViewController = nil
            stickyWindow.close()
        }
        await settle()
        let stickyHeight = stickyWindow.frame.height

        return (published, adoptHeight, stickyHeight)
    }

    /// THE genuinely-new contribution: an A/B over the production
    /// `ArchiveViewController` containment shape that isolates `sizingOptions`
    /// as the leak source AND honestly maps where the leak is observable.
    ///
    /// The regime-discriminating, offscreen-observable dimension is the
    /// **published** intrinsic/preferred size the host hands the window's
    /// constraint solver:
    ///   - broken (DEFAULT `sizingOptions`) ⇒ publishes ≈ 276 (the leak the
    ///     live window solver consumes to shrink the window), and the
    ///     content-adopting window collapses to its `minSize` clamp; while
    ///   - fixed (`sizingOptions = []`) ⇒ publishes ≈ 0 — nothing for the
    ///     solver to consume.
    ///
    /// This proves the gate has teeth on the dimension that matters (a flipped
    /// production fix re-exposes a ≈ 276 leak that the fix zeroes) and documents
    /// — via the attached report — that the window *frame* is sticky offscreen
    /// once `setContentSize` is asserted (so the window-height dimension alone
    /// is NOT a sufficient regression signal; assert on `published`).
    ///
    /// No production `sizingOptions` is mutated (production-code rule).
    func testDefaultSizingOptionsHostCollapsesWindowInLargeSplit() async throws {
        let broken = await probeRegime(clearSizing: false)
        let fixed = await probeRegime(clearSizing: true)

        let report = """
            BROKEN (default sizingOptions):
              published leak height = \(broken.published)
              adopt-path window height = \(broken.adoptHeight)
              sticky-path window height = \(broken.stickyHeight)
            FIXED (sizingOptions = []):
              published leak height = \(fixed.published)
              adopt-path window height = \(fixed.adoptHeight)
              sticky-path window height = \(fixed.stickyHeight)
            healthy contentRect height = 860, minSize.height = 540
            NOTE: offscreen, the window FRAME is not regime-discriminating
            (adopt collapses both to the minSize clamp; setContentSize makes
            both sticky at 860). The regime IS discriminated by the PUBLISHED
            intrinsic/preferred size — the value the live window solver consumes.
            """
        let attachment = XCTAttachment(string: report)
        attachment.name = "sizingOptions-AB-published-leak"
        attachment.lifetime = .keepAlways
        add(attachment)

        // TEETH: the broken regime publishes a non-trivial leak height (the
        // documented ≈ 276), the fixed regime publishes ≈ 0. Flipping the
        // production fix re-exposes this leak — i.e. the gate is not vacuous.
        XCTAssertGreaterThan(
            broken.published, 50,
            "Expected the DEFAULT-sizingOptions host to publish a non-trivial "
                + "leak height (≈ 276 — the value the window solver consumes), "
                + "proving the gate has teeth; got \(broken.published).")
        XCTAssertLessThanOrEqual(
            fixed.published, 1,
            "Expected `sizingOptions = []` to publish ≈ 0 (nothing to leak); "
                + "got \(fixed.published). The only delta from `broken` is the "
                + "regime, so the regime IS the leak source.")

        // The broken leak must DWARF the fixed one — the regime gap is wide,
        // not a rounding wobble.
        XCTAssertGreaterThan(
            broken.published - fixed.published, 50,
            "The published-size gap between regimes (\(broken.published) vs "
                + "\(fixed.published)) is too small to be the leak.")

        // Window-frame dimension, documented (not the discriminator): the
        // content-adopting window does collapse below its healthy 860 (the
        // minSize clamp), which is the offscreen shadow of the live collapse.
        XCTAssertLessThan(
            broken.adoptHeight, 700,
            "Adopt-path window should settle below its healthy 860 (the "
                + "content-adopting collapse); got \(broken.adoptHeight).")
    }

    // MARK: - The unit fact under the collapse: regime governs fittingSize

    /// The cheap, isolated fact beneath the collapse: with **default**
    /// options the host publishes a *small* fitting height (the content
    /// ideal that leaks); with `[]` it publishes ≈ 0 (nothing to leak).
    ///
    /// HONEST LABEL: this asserts the *measurement dimension responds to
    /// the regime* — it does NOT by itself prove a window collapses. That
    /// proof is `testDefaultSizingOptionsHostCollapsesWindowInLargeSplit`.
    func testSizingRegimeGovernsPublishedFittingSize() throws {
        func makeBody() -> AnyView {
            AnyView(
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Archived sessions").font(.title2)
                        Text("A small header.")
                        Spacer(minLength: 24)
                    }
                    .frame(minWidth: 480, maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                }
            )
        }

        // Default options: publishes the content's small ideal height.
        let defaultHost = NSHostingController(rootView: makeBody())
        // Force a layout so `fittingSize` is computed.
        defaultHost.view.layoutSubtreeIfNeeded()
        let defaultHeight = defaultHost.view.fittingSize.height

        // `[]` (regime A's fix): publishes ≈ 0 — nothing to leak.
        let clearedHost = NSHostingController(rootView: makeBody())
        clearedHost.sizingOptions = []
        clearedHost.view.layoutSubtreeIfNeeded()
        let clearedHeight = clearedHost.view.fittingSize.height

        let report = """
            default-options fittingSize.height = \(defaultHeight)
            sizingOptions=[] fittingSize.height = \(clearedHeight)
            """
        let attachment = XCTAttachment(string: report)
        attachment.name = "regime-governs-fittingSize"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Default leaks a small-but-nonzero height (bracketing the
        // documented ≈ 276 — band, not exact, since the number drifts with
        // content). `[]` publishes ≈ 0. The pair is the teeth for the
        // measurement dimension.
        XCTAssertGreaterThan(
            defaultHeight, 50,
            "Default-options host should publish a non-trivial fitting "
                + "height; got \(defaultHeight).")
        XCTAssertLessThan(
            defaultHeight, 600,
            "Default-options fitting height should be collapse-sized (small "
                + "relative to a real pane); got \(defaultHeight).")
        XCTAssertLessThanOrEqual(
            clearedHeight, 1,
            "sizingOptions=[] should publish ≈ 0 fitting height (nothing to "
                + "leak up the split); got \(clearedHeight).")
    }

    // MARK: - Compose + draft-landing fill panes do not collapse

    /// The regime-A no-collapse contract for the *other two* production
    /// fill-pane children the archive gate does not cover. Drives the real
    /// `DetailRouterViewController` swap path in the same large split/window
    /// and asserts, for each child:
    ///   - the window height holds (no collapse), and
    ///   - the mounted child publishes `fittingSize.height ≈ 0` (the `[]`
    ///     regime — isolates the regime from any window min-clamp noise).
    /// Each leg asserts the child *kind* first, so a routing regression
    /// fails loudly instead of passing against the wrong VC.
    func testComposeAndDraftLandingFillPanesDoNotCollapse() async throws {
        let fx = makeFixture(sessionCount: 1)
        // Land on a known full-height child first so we have a healthy
        // baseline to compare against. A real (`.created`) session routes
        // to the transcript VC, which fills the pane.
        fx.model.selection = .session(fx.sessionIds[0])

        let window = makeLargeSplitWindow(detailVC: fx.router)
        defer {
            window.contentViewController = nil
            window.close()
        }

        await settle()
        XCTAssertTrue(
            fx.router.currentChild is ChatSessionViewController,
            "Baseline leg should mount the transcript VC.")
        let baselineHeight = window.frame.height

        // --- Compose (.newSession → ComposeSessionViewController) ---
        fx.model.select(.newSession)
        await settle()
        XCTAssertTrue(
            fx.router.currentChild is ComposeSessionViewController,
            "Expected .newSession to mount ComposeSessionViewController; got "
                + "\(String(describing: fx.router.currentChild)).")
        let composeHeight = window.frame.height
        let composeFitting = fx.router.currentChild?.view.fittingSize.height ?? .infinity

        // --- Draft landing (.session(draftId) → DraftSessionLandingVC) ---
        fx.model.select(.session(fx.draftSessionId))
        await settle()
        XCTAssertTrue(
            fx.router.currentChild is DraftSessionLandingViewController,
            "Expected the .draft-status session to mount "
                + "DraftSessionLandingViewController; got "
                + "\(String(describing: fx.router.currentChild)). "
                + "(If this is ChatSessionViewController the fixture's "
                + ".draft record did not take and the test is vacuous.)")
        let draftHeight = window.frame.height
        let draftFitting = fx.router.currentChild?.view.fittingSize.height ?? .infinity

        let report = """
            baseline (transcript) height = \(baselineHeight)
            compose height = \(composeHeight), child fittingSize.h = \(composeFitting)
            draft-landing height = \(draftHeight), child fittingSize.h = \(draftFitting)
            """
        let attachment = XCTAttachment(string: report)
        attachment.name = "compose-draftLanding-no-collapse"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(
            composeHeight, baselineHeight - 1,
            "ComposeSessionViewController collapsed the window: "
                + "\(baselineHeight) → \(composeHeight).")
        XCTAssertLessThanOrEqual(
            composeFitting, 1,
            "Compose fill-pane child should publish ≈ 0 fittingSize (the [] "
                + "regime); got \(composeFitting).")

        XCTAssertGreaterThanOrEqual(
            draftHeight, baselineHeight - 1,
            "DraftSessionLandingViewController collapsed the window: "
                + "\(baselineHeight) → \(draftHeight).")
        XCTAssertLessThanOrEqual(
            draftFitting, 1,
            "Draft-landing fill-pane child should publish ≈ 0 fittingSize "
                + "(the [] regime); got \(draftFitting).")
    }

    // MARK: - The two-way binding is NOT the collapse cause

    /// Proves the `model.archiveSelectedFolderPath` two-way binding (the
    /// thing the user blamed for the squashed window) is height-neutral
    /// under the fixed `[]` regime: a binding write forces an `ArchiveView`
    /// body re-eval, but with no intrinsic size to republish the window
    /// height cannot move. The collapse was the sizing *regime*, not the
    /// binding — under a leaking regime the same binding would be the pump
    /// that re-trips it.
    func testArchiveBindingWriteStaysHeightNeutral() async throws {
        let fx = makeFixture(sessionCount: 0)
        fx.model.selection = .newSession

        let window = makeLargeSplitWindow(detailVC: fx.router)
        defer {
            window.contentViewController = nil
            window.close()
        }

        await settle()
        fx.model.select(.archive)
        await settle()
        XCTAssertTrue(
            fx.router.currentChild is ArchiveViewController,
            "Expected .archive to mount ArchiveViewController.")
        let heightBeforeWrite = window.frame.height

        // Force a body re-eval through the two-way binding (the same field
        // the toolbar folder-filter writes). If the binding were the
        // collapse cause, this write would shrink the window.
        fx.model.archiveSelectedFolderPath = "/tmp/some/folder"
        await settle()
        let heightAfterWrite = window.frame.height

        let childFitting = fx.router.currentChild?.view.fittingSize.height ?? .infinity
        let report = """
            archive height before binding write = \(heightBeforeWrite)
            archive height after binding write  = \(heightAfterWrite)
            archive child fittingSize.h = \(childFitting)
            """
        let attachment = XCTAttachment(string: report)
        attachment.name = "archive-binding-write-height-neutral"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(
            heightAfterWrite, heightBeforeWrite, accuracy: 1,
            "A two-way binding write moved the window height "
                + "(\(heightBeforeWrite) → \(heightAfterWrite)). Under the [] "
                + "regime the binding must be height-neutral; the collapse "
                + "was the sizing regime, not the binding.")
        XCTAssertLessThanOrEqual(
            childFitting, 1,
            "Archive child should still publish ≈ 0 fittingSize after a "
                + "binding write; got \(childFitting).")
    }
}

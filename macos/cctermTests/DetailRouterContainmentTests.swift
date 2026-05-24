import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Pins the AppKit VC containment invariants of
/// `DetailRouterViewController` — the merge gate that protects the
/// refactor pulling per-selection VCs out of the formerly-monolithic
/// `TranscriptDetailViewController`. Three properties guarded:
///
/// 1. The router always has **exactly one** child VC.
/// 2. That child's `view` is mounted as a direct subview of
///    `router.view` (so `removeFromParent` actually tears it out of the
///    tree — no leaked AppKit subviews lingering after a swap).
/// 3. When `model.selection` flips to a new selection that maps to the
///    SAME `ChildKind`, the existing child instance is **reused** (no
///    needless rebuild). Per-`ChildKind` swap behavior gets pinned as
///    each kind is split out of `TranscriptDetailViewController` in
///    subsequent commits — see `testFlipToArchiveSwapsChild` etc.
///    (added in later commits).
///
/// All tests run fully offscreen — no `NSWindow`, no rendering. AppKit
/// VC containment is synchronous and observable via `parent.children` /
/// `view.superview`, which is the right granularity for asserting tree
/// shape. The selection-flip tests drive the sync `installChildForCurrent`
/// `Selection` seam directly rather than waiting for the async
/// observation hop; the hop is exercised in a separate end-to-end test
/// further down.
@MainActor
final class DetailRouterContainmentTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tree shape

    func testInitialChildIsTranscriptDetailViewController() throws {
        let fixture = try makeFixture(initialSelection: .none)
        let router = fixture.router

        // Force loadView + viewDidLoad. Containment is established in
        // viewDidLoad; we don't need a window for that.
        _ = router.view

        XCTAssertEqual(router.children.count, 1, "router must own exactly one child")
        let child = try XCTUnwrap(router.currentChild)
        XCTAssertTrue(
            child is TranscriptDetailViewController,
            "scaffolding maps every selection to the transcript child")
        XCTAssertTrue(
            router.children.first === child,
            "currentChild must match the registered child VC")
        XCTAssertTrue(
            child.view.superview === router.view,
            "child's view must be mounted as a direct subview of router.view")
        XCTAssertEqual(router.currentKind, .transcript)
    }

    func testRoutingTable() {
        // The single source of truth for "which selection routes to
        // which child VC kind." Each entry has a code reason — when
        // you add a new `MainSelection` case or a new `ChildKind`,
        // update this table in the same commit.
        XCTAssertEqual(DetailRouterViewController.childKind(for: .none), .transcript)
        XCTAssertEqual(DetailRouterViewController.childKind(for: .newSession), .transcript)
        XCTAssertEqual(
            DetailRouterViewController.childKind(for: .session("sid")), .transcript)
        XCTAssertEqual(DetailRouterViewController.childKind(for: .archive), .archive)
        #if DEBUG
        for kind in DemoKind.allCases {
            XCTAssertEqual(
                DetailRouterViewController.childKind(for: .demo(kind)),
                .demo(kind))
        }
        #endif
    }

    // MARK: - Swap behavior

    func testSameKindSelectionFlipReusesChildInstance() throws {
        // `.none` → `.session(_)` is a same-kind transition
        // (`.transcript` both ways). The router must NOT tear down
        // and rebuild the child — it stays the same instance and
        // remains attached to `router.view`.
        let fixture = try makeFixture(initialSelection: .none)
        let router = fixture.router
        _ = router.view
        let initialChild = try XCTUnwrap(router.currentChild)

        router.model.selection = .session("sid-abc")
        router.installChildForCurrentSelection()
        XCTAssertTrue(
            router.currentChild === initialChild,
            ".none → .session(_) is a same-kind transition; child must be reused")
        XCTAssertTrue(initialChild.view.superview === router.view)

        XCTAssertEqual(
            router.children.count, 1,
            "same-kind flips must never multiply the child count")
    }

    func testFlipToArchiveTearsDownTranscriptAndMountsArchive() throws {
        // `.session(_)` → `.archive` is a cross-kind transition
        // (`.transcript` → `.archive`). The router must fully detach
        // the old child (`removeFromParent` + `view.removeFromSuperview`)
        // and install an `ArchiveViewController` in its place.
        let fixture = try makeFixture(initialSelection: .session("sid-abc"))
        let router = fixture.router
        _ = router.view
        let initialChild = try XCTUnwrap(router.currentChild)
        XCTAssertTrue(initialChild is TranscriptDetailViewController)

        router.model.selection = .archive
        router.installChildForCurrentSelection()

        let newChild = try XCTUnwrap(router.currentChild)
        XCTAssertTrue(
            newChild is ArchiveViewController,
            "router must install ArchiveViewController on `.archive` selection")
        XCTAssertFalse(
            newChild === initialChild,
            "cross-kind transition must replace the child instance, not reuse it")
        XCTAssertEqual(router.children.count, 1)
        XCTAssertTrue(newChild.view.superview === router.view)

        // Old child must be fully detached — no lingering subview, no
        // lingering parent-child registration. This is the property
        // that let us delete `PassthroughHostingView`: the old VC's
        // overlays vanish with it, so there's nothing left to swallow
        // clicks on top of the new child.
        XCTAssertNil(initialChild.view.superview, "old child's view must be unmounted")
        XCTAssertNil(initialChild.parent, "old child must be removed from parent chain")
    }

    #if DEBUG
    func testEveryDemoSelectionMountsItsOwnViewController() throws {
        // Each `.demo(_)` case must map to its dedicated VC class.
        // Tear down explicitly after every demo so the next iteration
        // starts from a clean child slot (mirrors the user flipping
        // demos in the sidebar one after another).
        for kind in DemoKind.allCases {
            let fixture = try makeFixture(initialSelection: .demo(kind))
            let router = fixture.router
            _ = router.view

            let child = try XCTUnwrap(router.currentChild)
            switch kind {
            case .transcript:
                XCTAssertTrue(child is TranscriptDemoViewController, "\(kind)")
            case .transcriptStress:
                XCTAssertTrue(child is TranscriptStressViewController, "\(kind)")
            case .transcriptPerf:
                XCTAssertTrue(child is TranscriptPerfDemoViewController, "\(kind)")
            case .permissionSession:
                XCTAssertTrue(child is PermissionSessionDemoViewController, "\(kind)")
            case .permissionCards:
                // SwiftUI-only demo — hosted via NSHostingController.
                XCTAssertTrue(child is NSHostingController<AnyView>, "\(kind)")
            }
            XCTAssertTrue(child.view.superview === router.view)
            XCTAssertEqual(router.children.count, 1)
        }
    }

    func testFlipBetweenDemoAndSessionFullyDetachesPreviousChild() throws {
        let fixture = try makeFixture(initialSelection: .demo(.transcript))
        let router = fixture.router
        _ = router.view
        let demoChild = try XCTUnwrap(router.currentChild)
        XCTAssertTrue(demoChild is TranscriptDemoViewController)

        router.model.selection = .session("sid")
        router.installChildForCurrentSelection()

        let chatChild = try XCTUnwrap(router.currentChild)
        XCTAssertTrue(chatChild is TranscriptDetailViewController)
        XCTAssertNil(demoChild.view.superview)
        XCTAssertNil(demoChild.parent)
        XCTAssertEqual(router.children.count, 1)
    }
    #endif

    func testFlipFromArchiveBackToSessionMountsFreshTranscriptVC() throws {
        // `.archive` → `.session(_)` flips the other way. The previous
        // TranscriptDetailViewController instance is gone (torn down
        // on the way INTO archive), so going BACK to a chat selection
        // must instantiate a brand-new transcript VC — not reach for
        // a stale reference. Mirrors the user round-trip of
        // "open archive, then click a recent session in the sidebar."
        let fixture = try makeFixture(initialSelection: .archive)
        let router = fixture.router
        _ = router.view
        let archiveChild = try XCTUnwrap(router.currentChild)
        XCTAssertTrue(archiveChild is ArchiveViewController)

        router.model.selection = .session("sid-xyz")
        router.installChildForCurrentSelection()

        let newChild = try XCTUnwrap(router.currentChild)
        XCTAssertTrue(newChild is TranscriptDetailViewController)
        XCTAssertNil(archiveChild.view.superview)
        XCTAssertNil(archiveChild.parent)
        XCTAssertEqual(router.children.count, 1)
    }

    // MARK: - Fixture

    /// Holds onto the dependency graph for the lifetime of one test so
    /// nothing the router relies on gets deallocated mid-assertion.
    private struct Fixture {
        let router: DetailRouterViewController
        let model: MainSelectionModel
    }

    private func makeFixture(initialSelection: MainSelection) throws -> Fixture {
        let repo = InMemorySessionRepository()
        let manager = SessionManager(
            repository: repo,
            cliClientFactory: { _ in FakeCLIClient() })

        // Per-test UserDefaults suite so the recent-projects store
        // doesn't leak across parallel test classes.
        let suiteName = "ccterm-detail-router-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let recentProjects = RecentProjectsStore(defaults: defaults)

        let activation = AppActivationTracker()
        let notifications = NotificationService(activation: activation)
        let syntaxEngine = SyntaxHighlightEngine()
        let searchBus = TranscriptSearchBus()

        // Per-test draft directory so the bar's InputDraftStore writes
        // nowhere shared.
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-detail-router-\(UUID().uuidString)", isDirectory: true)
        let inputDraftStore = InputDraftStore(directory: draftDir, debounceInterval: 0.05)

        let model = MainSelectionModel()
        model.selection = initialSelection

        let router = DetailRouterViewController(
            model: model,
            sessionManager: manager,
            recentProjects: recentProjects,
            notifications: notifications,
            searchEngine: syntaxEngine,
            searchBus: searchBus,
            inputDraftStore: inputDraftStore
        )

        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: draftDir)
        }

        return Fixture(router: router, model: model)
    }
}

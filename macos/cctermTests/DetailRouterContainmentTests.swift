import AppKit
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

    func testRouterChildKindIsStableAcrossEverySelection() {
        // Scaffolding invariant: in this commit, every `MainSelection`
        // collapses to `.transcript`. Later commits split `.archive`
        // and `.demo(_)` out; THIS test will fail when that lands and
        // gets updated alongside the new routing.
        XCTAssertEqual(DetailRouterViewController.childKind(for: .none), .transcript)
        XCTAssertEqual(DetailRouterViewController.childKind(for: .newSession), .transcript)
        XCTAssertEqual(
            DetailRouterViewController.childKind(for: .session("sid")), .transcript)
        XCTAssertEqual(DetailRouterViewController.childKind(for: .archive), .transcript)
        #if DEBUG
        for kind in DemoKind.allCases {
            XCTAssertEqual(
                DetailRouterViewController.childKind(for: .demo(kind)),
                .transcript)
        }
        #endif
    }

    // MARK: - Swap behavior

    func testSameKindSelectionFlipReusesChildInstance() throws {
        // All selections currently map to `.transcript`, so any flip
        // is a same-kind transition. The router must NOT tear down
        // and rebuild the child — it stays the same instance and
        // remains attached to `router.view`.
        let fixture = try makeFixture(initialSelection: .none)
        let router = fixture.router
        _ = router.view
        let initialChild = try XCTUnwrap(router.currentChild)

        router.model.selection = .archive
        router.installChildForCurrentSelection()
        XCTAssertTrue(
            router.currentChild === initialChild,
            ".none → .archive is a same-kind transition; child must be reused")
        XCTAssertTrue(initialChild.view.superview === router.view)

        router.model.selection = .session("sid-abc")
        router.installChildForCurrentSelection()
        XCTAssertTrue(
            router.currentChild === initialChild,
            ".archive → .session(_) is a same-kind transition; child must be reused")

        XCTAssertEqual(
            router.children.count, 1,
            "same-kind flips must never multiply the child count")
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

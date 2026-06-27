import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Pins the AppKit VC containment invariants of
/// `DetailRouterViewController` — the merge gate that protects the
/// refactor pulling per-selection VCs out of the formerly-monolithic
/// `ChatSessionViewController`. Three properties guarded:
///
/// 1. The router always has **exactly one** child VC.
/// 2. That child's `view` is mounted as a direct subview of
///    `router.view` (so `removeFromParent` actually tears it out of the
///    tree — no leaked AppKit subviews lingering after a swap).
/// 3. When `model.selection` flips to a new selection that maps to the
///    SAME `ChildKind`, the existing child instance is **reused** (no
///    needless rebuild). Per-`ChildKind` swap behavior gets pinned as
///    each kind is split out of `ChatSessionViewController` in
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

    func testInitialChildIsChatSessionViewController() throws {
        let fixture = try makeFixture(initialSelection: .none)
        let router = fixture.router

        // Force loadView + viewDidLoad. Containment is established in
        // viewDidLoad; we don't need a window for that.
        _ = router.view

        XCTAssertEqual(router.children.count, 1, "router must own exactly one child")
        let child = try XCTUnwrap(router.currentChild)
        XCTAssertTrue(
            child is ChatSessionViewController,
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
        XCTAssertEqual(DetailRouterViewController.childKind(for: .newSession), .compose)
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

    func testNewSessionMountsComposeAndFlipToSessionSwapsToChat() throws {
        // `.newSession` gets its OWN VC (`ComposeSessionViewController`),
        // not `ChatSessionViewController`. This is the split that fixes
        // the click-swallow bug: compose is full-bleed with no transcript
        // behind it, so its host never has to morph between full-bleed
        // and bottom-anchored — the source of the lingering-overlay race.
        let fixture = try makeFixture(initialSelection: .newSession)
        let router = fixture.router
        _ = router.view

        let composeChild = try XCTUnwrap(router.currentChild)
        XCTAssertTrue(
            composeChild is ComposeSessionViewController,
            "`.newSession` must mount ComposeSessionViewController, not the chat VC")
        XCTAssertEqual(router.currentKind, .compose)
        XCTAssertTrue(composeChild.view.superview === router.view)

        // Submitting the compose card flips selection to `.session(_)` —
        // a cross-kind transition (`.compose` → `.transcript`). The
        // compose VC must be fully torn down and a fresh chat VC mounted.
        router.model.selection = .session("sid-promoted")
        router.installChildForCurrentSelection()

        let chatChild = try XCTUnwrap(router.currentChild)
        XCTAssertTrue(chatChild is ChatSessionViewController)
        XCTAssertFalse(chatChild === composeChild)
        XCTAssertEqual(router.children.count, 1)
        XCTAssertNil(composeChild.view.superview, "compose VC's view must be unmounted")
        XCTAssertNil(composeChild.parent, "compose VC must be removed from parent chain")
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
        XCTAssertTrue(initialChild is ChatSessionViewController)

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
        // lingering parent-child registration. This is the property that
        // let us retire the old full-pane chrome-covering overlay: the old
        // VC's overlays vanish with it, so there's nothing left to swallow
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
                // SwiftUI-only demo — hosted via NSHostingController. The
                // root view was un-erased from `AnyView` to the concrete
                // `PermissionCardsDemoView` + `.environment(...)` chain (an
                // unspellable `ModifiedContent<…>` generic), so match on the
                // runtime class — every `NSHostingController<T>`
                // specialization shares the same ObjC class.
                XCTAssertTrue(
                    String(describing: type(of: child)).hasPrefix("NSHostingController"),
                    "\(kind)")
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
        XCTAssertTrue(chatChild is ChatSessionViewController)
        XCTAssertNil(demoChild.view.superview)
        XCTAssertNil(demoChild.parent)
        XCTAssertEqual(router.children.count, 1)
    }
    #endif

    func testFlipFromArchiveBackToSessionMountsFreshTranscriptVC() throws {
        // `.archive` → `.session(_)` flips the other way. The previous
        // ChatSessionViewController instance is gone (torn down
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
        XCTAssertTrue(newChild is ChatSessionViewController)
        XCTAssertNil(archiveChild.view.superview)
        XCTAssertNil(archiveChild.parent)
        XCTAssertEqual(router.children.count, 1)
    }

    // MARK: - Leak regression gate

    func testTranscriptVCDeallocatesAfterCrossKindSwap() throws {
        // The headline regression gate for the session-switch leak: a
        // transcript VC the router swaps out (cross-kind `.session →
        // .archive`) must actually deallocate. It only fails to if some
        // observation task holds a strong `self` across an `await` and
        // re-arms forever (the launch-failure / pending-activation tasks
        // that used to live here did exactly that). Keep `router` alive so
        // this asserts the *child* drops, not that everything teardown.
        let fixture = try makeFixture(initialSelection: .session("sid-1"))
        let router = fixture.router
        _ = router.view  // viewDidLoad mounts the initial transcript child

        weak var weakChild: ChatSessionViewController?
        autoreleasepool {
            weakChild = router.currentChild as? ChatSessionViewController
            XCTAssertNotNil(weakChild, "fixture should start on a transcript child")
            router.model.selection = .archive
            router.installChildForCurrentSelection()
        }

        // ARC + SwiftUI hosting teardown can settle across a runloop turn;
        // poll rather than asserting synchronously (no sleep).
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in weakChild == nil }, object: nil)
        wait(for: [exp], timeout: 5)
        XCTAssertNil(
            weakChild,
            "transcript VC must deallocate after a cross-kind swap — no observation "
                + "task may hold a strong self across an await and pin it")
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
            syntaxEngine: syntaxEngine,
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

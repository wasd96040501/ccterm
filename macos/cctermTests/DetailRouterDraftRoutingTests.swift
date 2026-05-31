import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Phase-aware routing for draft sessions: a `.session(_)` whose `Session`
/// is still a draft mounts `DraftSessionLandingViewController`, and the
/// draft → active promotion (via `promote(to:)`) swaps it for
/// `ChatSessionViewController` — in place, same selection value.
@MainActor
final class DetailRouterDraftRoutingTests: XCTestCase {

    private func makeRouter() -> (DetailRouterViewController, MainSelectionModel, SessionManager) {
        let model = MainSelectionModel()
        let manager = SessionManager(
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in FakeCLIClient() }
        )
        let router = DetailRouterViewController(
            model: model,
            sessionManager: manager,
            recentProjects: RecentProjectsStore(),
            notifications: NotificationService(activation: AppActivationTracker()),
            searchEngine: SyntaxHighlightEngine(),
            searchBus: TranscriptSearchBus(),
            inputDraftStore: InputDraftStore()
        )
        _ = router.view  // force viewDidLoad + initial child install
        return (router, model, manager)
    }

    func test_draftSession_mountsLandingVC() {
        let (router, model, manager) = makeRouter()
        let draftId = manager.createSidebarDraft(seededFrom: nil)
        model.select(.session(draftId))
        XCTAssertTrue(router.currentChild is DraftSessionLandingViewController)
        XCTAssertEqual(router.children.count, 1)
    }

    func test_realSession_mountsTranscriptVC() {
        // A `.session(_)` with no draft (unmaterialized) routes to the
        // transcript, exactly as before the feature.
        let (router, model, _) = makeRouter()
        model.select(.session("real"))
        XCTAssertTrue(router.currentChild is ChatSessionViewController)
    }

    func test_draftPromotion_swapsLandingForTranscript() {
        let (router, model, manager) = makeRouter()
        let draftId = manager.createSidebarDraft(seededFrom: nil)
        model.select(.session(draftId))
        XCTAssertTrue(router.currentChild is DraftSessionLandingViewController)

        // First message promotes the draft; `promote` re-routes in place.
        manager.prepareDraftSession(draftId).send(text: "hello")
        model.promote(to: draftId)
        XCTAssertTrue(router.currentChild is ChatSessionViewController)
        XCTAssertEqual(router.children.count, 1)
    }
}

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

    private func makeRouter(
        manager: SessionManager? = nil
    ) -> (DetailRouterViewController, MainSelectionModel, SessionManager) {
        let model = MainSelectionModel()
        let manager =
            manager
            ?? SessionManager(
                repository: InMemorySessionRepository(),
                cliClientFactory: { _ in FakeCLIClient() }
            )
        let router = DetailRouterViewController(
            context: DetailContext(
                model: model,
                sessionManager: manager,
                recentProjects: RecentProjectsStore(),
                inputDraftStore: InputDraftStore(),
                syntaxEngine: SyntaxHighlightEngine()),
            notifications: NotificationService(activation: AppActivationTracker())
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

    func test_uncachedDraftRow_afterRestart_mountsLandingVC() {
        // Simulate a cold restart: a `.draft` row exists in the store but no
        // `Session` is cached. Routing must consult the durable status and
        // still land on the landing page — not fall through to the transcript
        // (the cache-only `existingSession?.isDraft` would have returned nil).
        let repo = InMemorySessionRepository()
        let draftId = "restored-draft"
        repo.save(
            SessionRecord(
                sessionId: draftId, title: "", cwd: "/proj",
                originPath: "/proj", status: .draft))
        let manager = SessionManager(
            repository: repo, cliClientFactory: { _ in FakeCLIClient() })
        let (router, model, _) = makeRouter(manager: manager)

        model.select(.session(draftId))

        XCTAssertTrue(router.currentChild is DraftSessionLandingViewController)
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

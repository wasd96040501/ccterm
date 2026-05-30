import AppKit
import XCTest

@testable import ccterm

/// Pins the notification-activation routing after it moved off the
/// per-detail-VC `withObservationTracking` poll (which leaked every
/// `ChatSessionViewController` it ran on) onto a single push callback
/// owned by the stable `DetailRouterViewController`.
///
/// Two properties:
/// 1. `NotificationService.activateForSession(_:)` pushes through
///    `onActivateSession` — the real main-actor entry the OS delegate
///    calls, driven directly here so we don't fabricate a
///    `UNNotificationResponse`.
/// 2. The router installs that callback in `viewDidLoad` and routes an
///    activation straight to `MainSelectionModel.select(.session(_))`,
///    synchronously.
@MainActor
final class NotificationActivationRoutingTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testActivateForSessionPushesThroughCallback() {
        let notifications = NotificationService(activation: AppActivationTracker())
        var captured: [String] = []
        notifications.onActivateSession = { captured.append($0) }

        notifications.activateForSession("sid-1")
        notifications.activateForSession("sid-1")  // re-click the same session still fires

        XCTAssertEqual(
            captured, ["sid-1", "sid-1"],
            "every activation must push — no de-dup / clear-after-consume gate")
    }

    func testNoCallbackInstalledIsSafe() {
        // Before the owner wires it (e.g. cold launch), an activation
        // must not crash.
        let notifications = NotificationService(activation: AppActivationTracker())
        notifications.activateForSession("sid-orphan")  // no observer; just NSApp.activate
    }

    func testRouterRoutesActivationToSelection() throws {
        let fixture = try makeFixture(initialSelection: .none)
        let router = fixture.router
        // Force viewDidLoad — that's where the router installs
        // `notifications.onActivateSession`.
        _ = router.view

        fixture.notifications.activateForSession("sid-xyz")

        XCTAssertEqual(
            fixture.model.selection, .session("sid-xyz"),
            "a notification click must flip selection synchronously through the router")
    }

    // MARK: - Fixture

    private struct Fixture {
        let router: DetailRouterViewController
        let model: MainSelectionModel
        let notifications: NotificationService
    }

    private func makeFixture(initialSelection: MainSelection) throws -> Fixture {
        let repo = InMemorySessionRepository()
        let manager = SessionManager(
            repository: repo,
            cliClientFactory: { _ in FakeCLIClient() })

        let suiteName = "ccterm-notif-routing-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let recentProjects = RecentProjectsStore(defaults: defaults)

        let notifications = NotificationService(activation: AppActivationTracker())
        let syntaxEngine = SyntaxHighlightEngine()
        let searchBus = TranscriptSearchBus()

        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-notif-routing-\(UUID().uuidString)", isDirectory: true)
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

        return Fixture(router: router, model: model, notifications: notifications)
    }
}

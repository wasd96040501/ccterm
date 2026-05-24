import AppKit
import XCTest

@testable import ccterm

/// Pins the launch-failure forwarding after it moved off
/// `SessionManager.lastLaunchFailure` (an `@Observable` field that every
/// `ChatSessionViewController` polled through a leaky re-arming task,
/// stacking one alert per leaked VC) onto the `onLaunchFailure` push
/// callback owned by `DetailRouterViewController`.
@MainActor
final class SessionManagerLaunchFailureTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSessionLaunchFailureForwardsToManagerCallback() throws {
        let manager = SessionManager(
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in FakeCLIClient() })
        var captured: [SessionManager.LaunchFailure] = []
        manager.onLaunchFailure = { captured.append($0) }

        // `prepareDraftSession` wires the session's launch-failure sink to
        // the manager's forwarding closure. Drive that sink the way the
        // runtime does (`SessionRuntime.failLaunch` → `onLaunchFailure?`).
        let session = manager.prepareDraftSession("sid-1")
        let sink = try XCTUnwrap(
            session.onLaunchFailure, "manager must wire the session's launch-failure sink")
        sink("CLI binary not found")

        XCTAssertEqual(captured.count, 1, "exactly one push per failure")
        XCTAssertEqual(captured.first?.sessionId, "sid-1")
        XCTAssertEqual(captured.first?.message, "CLI binary not found")
    }

    func testNoManagerCallbackInstalledIsSafe() throws {
        // Before the owner wires it, a failure must not crash.
        let manager = SessionManager(
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in FakeCLIClient() })
        let session = manager.prepareDraftSession("sid-orphan")
        session.onLaunchFailure?("boom")  // no observer installed
    }

    func testRouterInstallsLaunchFailureCallbackOnLoad() throws {
        // The router is the single owner — it installs the alert presenter
        // in `viewDidLoad`. We assert the wiring exists rather than firing
        // it (presentation puts up an `NSAlert`, which must not run in a
        // unit test).
        let repo = InMemorySessionRepository()
        let manager = SessionManager(
            repository: repo, cliClientFactory: { _ in FakeCLIClient() })

        let suiteName = "ccterm-launch-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let recentProjects = RecentProjectsStore(defaults: defaults)
        let notifications = NotificationService(activation: AppActivationTracker())
        let draftDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-launch-failure-\(UUID().uuidString)", isDirectory: true)
        let inputDraftStore = InputDraftStore(directory: draftDir, debounceInterval: 0.05)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: draftDir)
        }

        XCTAssertNil(manager.onLaunchFailure, "no owner before the router loads")

        let router = DetailRouterViewController(
            model: MainSelectionModel(),
            sessionManager: manager,
            recentProjects: recentProjects,
            notifications: notifications,
            searchEngine: SyntaxHighlightEngine(),
            searchBus: TranscriptSearchBus(),
            inputDraftStore: inputDraftStore
        )
        _ = router.view  // forces viewDidLoad

        XCTAssertNotNil(
            manager.onLaunchFailure,
            "router must install the launch-failure alert presenter on load")
    }
}

import Observation
import SwiftUI

@Observable
@MainActor
final class AppState {
    let sessionManager: SessionManager
    let syntaxEngine = SyntaxHighlightEngine()
    let recentProjects = RecentProjectsStore()
    let inputDraftStore = InputDraftStore()
    let sidebarGroupOrder = SidebarSessionGroupOrderStore()
    let activationTracker: AppActivationTracker
    let notificationService: NotificationService
    let openInService = OpenInAppService()

    init() {
        self.sessionManager = SessionManager()
        let tracker = AppActivationTracker()
        self.activationTracker = tracker
        let notifications = NotificationService(activation: tracker)
        self.notificationService = notifications

        // Route every session's turn-end signal through the notification
        // service. Strong capture is fine — both objects are owned by
        // `AppState` and live as long as the app does. The service
        // gates on `tracker.isAppActive` internally, so plumbing here
        // is unconditional.
        sessionManager.onTurnEndedNotice = { [notifications] notice in
            notifications.handleTurnEnded(notice)
        }

        // Same plumbing for "a session is waiting on a permission
        // decision." A pending permission blocks the turn (no turn-end
        // signal fires), so this is the only banner the user gets when
        // the app is backgrounded and Claude needs approval to proceed.
        sessionManager.onPermissionPromptNotice = { [notifications] notice in
            notifications.handlePermissionPrompt(notice)
        }

        // Eagerly load the syntax highlight engine in the background so the
        // first `highlightBatch` call doesn't pay the JSCore / highlight.js
        // init cost (~30ms) on the user-facing path. `.utility` priority keeps
        // it behind real user interactions.
        let engine = syntaxEngine
        Task.detached(priority: .utility) { await engine.load() }

        // Probe installed "Open in …" apps once at launch (off-main,
        // result published back on the main actor). The sidebar context
        // menu reads the result; an empty list just means the scan hasn't
        // landed yet.
        openInService.refresh()
    }
}

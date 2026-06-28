import Observation
import SwiftUI

@Observable
@MainActor
final class AppState {
    let sessionManager: SessionManager
    let syntaxEngine: SyntaxHighlightEngine
    let recentProjects: RecentProjectsStore
    let inputDraftStore: InputDraftStore
    let sidebarGroupOrder: SidebarSessionGroupOrderStore
    let activationTracker: AppActivationTracker
    let notificationService: NotificationService
    let openInService: OpenInAppService

    /// Dependency-injectable initializer. Every parameter defaults to `nil`
    /// and is materialized to its production-wired value inside the body, so
    /// `AppState()` at the app entry point behaves exactly as before. (The
    /// defaults can't be expressed as default parameter values: those are
    /// evaluated in a `nonisolated` context, and these stores'
    /// initializers are `@MainActor`-isolated. The init body runs on the
    /// main actor, so the materialization is legal there.) Tests (and the
    /// AppKit verification harness) override the process-wide singletons /
    /// disk-backed stores with in-memory, per-test instances so a real
    /// `AppState` — and the real `MainSplitViewController` it feeds — can be
    /// stood up without touching `CoreDataSessionRepository`, `~/.claude`, or
    /// `UserDefaults.standard` (all of which would race across the parallel
    /// test processes; see `cctermTests/CLAUDE.md`).
    ///
    /// `eagerlyLoadSyntaxEngine` / `probeOpenInApps` gate the two launch
    /// side effects so a headless test doesn't spawn a JSCore load or an
    /// installed-apps disk scan it never observes.
    init(
        sessionManager: SessionManager? = nil,
        syntaxEngine: SyntaxHighlightEngine? = nil,
        recentProjects: RecentProjectsStore? = nil,
        inputDraftStore: InputDraftStore? = nil,
        sidebarGroupOrder: SidebarSessionGroupOrderStore? = nil,
        activationTracker: AppActivationTracker? = nil,
        openInService: OpenInAppService? = nil,
        notificationService: NotificationService? = nil,
        eagerlyLoadSyntaxEngine: Bool = true,
        probeOpenInApps: Bool = true
    ) {
        let sessionManager = sessionManager ?? SessionManager()
        let syntaxEngine = syntaxEngine ?? SyntaxHighlightEngine()
        let activationTracker = activationTracker ?? AppActivationTracker()
        self.sessionManager = sessionManager
        self.syntaxEngine = syntaxEngine
        self.recentProjects = recentProjects ?? RecentProjectsStore()
        self.inputDraftStore = inputDraftStore ?? InputDraftStore()
        self.sidebarGroupOrder = sidebarGroupOrder ?? SidebarSessionGroupOrderStore()
        self.activationTracker = activationTracker
        self.openInService = openInService ?? OpenInAppService()
        let notifications = notificationService ?? NotificationService(activation: activationTracker)
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
        if eagerlyLoadSyntaxEngine {
            let engine = syntaxEngine
            Task.detached(priority: .utility) { await engine.load() }
        }

        // Probe installed "Open in …" apps once at launch (off-main,
        // result published back on the main actor). The sidebar context
        // menu reads the result; an empty list just means the scan hasn't
        // landed yet.
        if probeOpenInApps {
            self.openInService.refresh()
        }
    }
}

import Foundation

/// Process-scope dependency manifest. Read-only. Assembled once at the
/// composition root (`AppDelegate.applicationWillFinishLaunching`) and
/// threaded top-down through the coordinator tree — never re-`new`'d,
/// never mutated. A read here reads the entire graph.
///
/// Every field is a concrete production instance in the shipping app;
/// tests build their own `AppContext` with in-memory / stubbed
/// substitutes and hand it to the same downstream coordinators. There
/// is intentionally no default initializer that fabricates missing
/// members — that used to live on `AppState` and hid the graph.
@MainActor
struct AppContext {
    let sessionManager: SessionManager
    let syntaxEngine: SyntaxHighlightEngine
    let recentProjects: RecentProjectsStore
    let inputDraftStore: InputDraftStore
    let sidebarGroupOrder: SidebarSessionGroupOrderStore
    let activationTracker: AppActivationTracker
    let notificationService: NotificationService
    let openInService: OpenInAppService
    /// App-scope transcript store registry. Owned by `AppDelegate`, keyed
    /// by transcript id, kept alive for the whole process — the state /
    /// typeset cache that lets sidebar switch-back paint instantly lives
    /// in here, not in the transcript VC.
    let transcriptRegistry: TranscriptRegistryStore
}

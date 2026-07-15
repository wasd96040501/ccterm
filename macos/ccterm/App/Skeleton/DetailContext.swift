import Foundation

/// Detail-scope dependency manifest. A thin slice of `WindowContext` that
/// each detail child VC (and `DetailFlowCoordinator`) actually reads. Split
/// out so children don't take a dependency on the notification service or
/// the search bus (which are consumed only by the flow coordinator / the
/// window controller respectively).
///
/// `sessionManager` + `syntaxEngine` cover every current detail child
/// (transcript session, placeholders, and — in follow-up PRs — the
/// archive / new-session / draft-landing screens). `selectionStore` is
/// here because the coming input-bar migration will read
/// `draftSessionId` from it.
@MainActor
struct DetailContext {
    let sessionManager: SessionManager
    let syntaxEngine: SyntaxHighlightEngine
    let recentProjects: RecentProjectsStore
    let inputDraftStore: InputDraftStore
    let selectionStore: SelectionStore

    init(app: AppContext, selectionStore: SelectionStore) {
        self.sessionManager = app.sessionManager
        self.syntaxEngine = app.syntaxEngine
        self.recentProjects = app.recentProjects
        self.inputDraftStore = app.inputDraftStore
        self.selectionStore = selectionStore
    }
}

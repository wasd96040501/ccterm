import Observation
import SwiftUI

@Observable
@MainActor
final class AppState {
    let sessionManager2: SessionManager2
    let syntaxEngine = SyntaxHighlightEngine()
    let recentProjects = RecentProjectsStore()

    init() {
        self.sessionManager2 = SessionManager2()

        // Eagerly load the syntax highlight engine in the background so the
        // first `highlightBatch` call doesn't pay the JSCore / highlight.js
        // init cost (~30ms) on the user-facing path. `.utility` priority keeps
        // it behind real user interactions.
        let engine = syntaxEngine
        Task.detached(priority: .utility) { await engine.load() }
    }
}

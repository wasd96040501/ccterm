import SwiftUI
import Observation

@Observable
@MainActor
final class AppState {

    // MARK: - Services
    let sessionManager2 = SessionManager2()
    let syntaxEngine = SyntaxHighlightEngine()

    init() {
        // Eagerly load the syntax highlight engine in the background so the
        // first `highlightBatch` call doesn't pay the JSCore / highlight.js
        // init cost (~30ms) on the user-facing path.
        let engine = syntaxEngine
        Task.detached(priority: .utility) { await engine.load() }
    }

    // MARK: - Commands

    /// `Cmd+N` 入口 —— 切到一个空 `.notStarted` handle。
    func startNewConversation() {
        sessionManager2.startNewConversation()
    }
}

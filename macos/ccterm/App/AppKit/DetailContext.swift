import SwiftUI

/// The single value bag threaded from `MainSplitViewController` down through
/// `DetailRouterViewController` into every detail child VC. Replaces the
/// seven-argument imperative DI fan-out the router and each child used to
/// declare verbatim — adding or removing a detail-scope dependency is now one
/// edit here (and one in `injectDetailEnvironment`), not a parallel change in
/// six initializers.
///
/// The five members are exactly the values the detail subtree's SwiftUI
/// content reads from the environment: `model` (the shared selection state)
/// plus the four services every fill-pane host injects (`sessionManager`,
/// `recentProjects`, `inputDraftStore`, `syntaxEngine`).
///
/// **Deliberately excluded:** `NotificationService` (consumed only by the
/// router, which owns the window-lifetime activation signals — passed to it
/// as a separate argument) and `TranscriptSearchBus` (the detail subtree
/// consumes neither; its real consumers — the toolbar search bridge and the
/// ⌘F command — hold their own reference outside this subtree).
@MainActor
struct DetailContext {
    let model: MainSelectionModel
    let sessionManager: SessionManager
    let recentProjects: RecentProjectsStore
    let inputDraftStore: InputDraftStore
    let syntaxEngine: SyntaxHighlightEngine
}

extension View {
    /// Inject the four detail-scope services every fill-pane host depends on
    /// into the SwiftUI environment, in one call. The single home for the
    /// four-line `.environment(...)` block that the four detail VCs (and the
    /// router's permission-cards demo child) each used to repeat verbatim.
    ///
    /// `model` is *not* injected here — it's handed to each SwiftUI view as an
    /// explicit `@Bindable` / value argument at the construction site, so the
    /// modifier carries only the environment-resolved services. The injection
    /// set is the contract: `sessionManager` / `recentProjects` /
    /// `inputDraftStore` as observable objects, `syntaxEngine` on its keyed
    /// `\.syntaxEngine` path. These still resolve at runtime — a missing
    /// `@Environment` read surfaces as a runtime crash, not a compile error.
    func injectDetailEnvironment(_ context: DetailContext) -> some View {
        self
            .environment(context.sessionManager)
            .environment(context.recentProjects)
            .environment(context.inputDraftStore)
            .environment(\.syntaxEngine, context.syntaxEngine)
    }
}

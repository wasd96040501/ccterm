import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: appState.sidebarViewModel, selection: selectionBinding)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
        } detail: {
            ContentView(
                activeAction: appState.activeAction,
                chatRouter: appState.chatRouter,
                sidebarViewModel: appState.sidebarViewModel,
                sessionService: appState.sessionService,
                onJumpToSession: { sessionId in
                    appState.activeAction = nil
                    appState.chatRouter.activateSession(sessionId)
                }
            )
        }
        .frame(minWidth: 800, minHeight: 480)
    }

    /// 从 ChatRouter + AppState 派生的 sidebar selection。
    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: {
                if let action = appState.activeAction { return .action(action) }
                let session = appState.chatRouter.currentViewModel
                if session.handle == nil { return .action(.newConversation) }
                return .session(session.sessionId)
            },
            set: { newValue in
                switch newValue {
                case .session(let id):
                    appState.activeAction = nil
                    appState.chatRouter.activateSession(id)
                    appState.sidebarViewModel.markSessionRead(sessionId: id)
                case .action(.newConversation):
                    appState.activeAction = nil
                    appState.chatRouter.activateNewConversation()
                case .action(let action):
                    appState.activeAction = action
                case nil:
                    break
                }
            }
        )
    }
}

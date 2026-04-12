import SwiftUI

struct RootView: View {
    @Environment(AppViewModel.self) private var appVM
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: appVM.sidebarViewModel, selection: selectionBinding)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
        } detail: {
            ContentView()
        }
        .frame(minWidth: 800, minHeight: 480)
    }

    /// 从 SessionService + AppViewModel 派生的 sidebar selection。
    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: {
                if let action = appVM.activeAction { return .action(action) }
                if appVM.sessionService.activeHandle?.status == .notStarted {
                    return .action(.newConversation)
                }
                return .session(appVM.sessionService.activeSessionId)
            },
            set: { newValue in
                switch newValue {
                case .session(let id):
                    appVM.activeAction = nil
                    appVM.sessionService.activateSession(id)
                    appVM.sidebarViewModel.markSessionRead(sessionId: id)
                case .action(.newConversation):
                    appVM.activeAction = nil
                    appVM.sessionService.activateNewConversation()
                case .action(let action):
                    #if DEBUG
                    if action == .planGallery {
                        appVM.activatePlanGallery()
                        return
                    }
                    #endif
                    appVM.activeAction = action
                case nil:
                    break
                }
            }
        )
    }
}

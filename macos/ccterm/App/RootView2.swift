import SwiftUI

/// v2 根视图:Sidebar v2(含"新对话" action 行)+ ChatHistoryView(NativeTranscript +
/// InputBar 叠放)。选中态由 `SessionManager2.current` 唯一持有,view 不再有
/// `@State selectedSessionId`。
struct RootView2: View {
    @Environment(SessionManager2.self) private var manager
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// 由 `manager.current` derive sidebar selection:`.notStarted` 且空消息的
    /// handle 视为"新对话",高亮顶部 action 行;否则高亮对应历史会话行。
    private var sidebarSelection: SidebarSelection2 {
        let h = manager.current
        if h.status == .notStarted, h.messages.isEmpty {
            return .newConversation
        }
        return .session(h.sessionId)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView2(
                selection: sidebarSelection,
                onSelect: handleSidebarSelect
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
        } detail: {
            // `.id(sessionId)` 必须在调用点 —— 让 ChatHistoryView 整个 struct 随
            // sessionId 重建,`@State openT0` 跟着 reset。
            ChatHistoryView(handle: manager.current)
                .id(manager.current.sessionId)
                .frame(minWidth: 400)
        }
        .frame(minWidth: 800, minHeight: 480)
    }

    private func handleSidebarSelect(_ selection: SidebarSelection2) {
        switch selection {
        case .newConversation:
            manager.startNewConversation()
        case .session(let id):
            manager.select(id)
        }
    }
}

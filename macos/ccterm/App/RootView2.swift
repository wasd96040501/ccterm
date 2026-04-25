import SwiftUI

/// v2 根视图:Sidebar v2 + ChatHistoryView(NativeTranscript + InputBar 叠放)。
/// 选中态由 `SessionManager2.current` 唯一持有,view 不再有 `@State selectedSessionId`。
struct RootView2: View {
    @Environment(SessionManager2.self) private var manager
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView2(
                selectedSessionId: manager.current.sessionId,
                onSelect: { id in manager.select(id) }
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
}

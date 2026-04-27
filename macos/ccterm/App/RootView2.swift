import SwiftUI

/// v2 根视图：Sidebar v2 + 只读 ChatHistoryView。
/// 选中态本地持有，不走 AppState / ChatRouter。
struct RootView2: View {
    @State private var selectedSessionId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView2(selection: $selectedSessionId)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
        } detail: {
            if selectedSessionId == SidebarView2.transcriptDemoTag {
                TranscriptDemoView()
                    .frame(minWidth: 400)
            } else if let sid = selectedSessionId {
                // `.id(sid)` 必须在**调用点**: 让 ChatHistoryView 整个 struct
                // 随 sessionId 重建,`@State handle` 跟着 reset。放在 body 内
                // 的 Group 上无效(只换 Group 子树,@State 保留跨 session)。
                ChatHistoryView(sessionId: sid)
                    .id(sid)
                    .frame(minWidth: 400)
            } else {
                Color.clear
                    .frame(minWidth: 400)
            }
        }
        .frame(minWidth: 800, minHeight: 480)
    }
}

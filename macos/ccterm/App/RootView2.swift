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
            if let sid = selectedSessionId {
                ChatHistoryView(sessionId: sid)
                    .frame(minWidth: 400)
            } else {
                Color.clear
                    .frame(minWidth: 400)
            }
        }
        .frame(minWidth: 800, minHeight: 480)
    }
}

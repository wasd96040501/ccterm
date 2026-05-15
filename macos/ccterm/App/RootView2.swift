import SwiftUI

/// v2 根视图：Sidebar v2 + 只读 ChatHistoryView。
/// 选中态本地持有，不走 AppState / ChatRouter。
struct RootView2: View {
    @State private var selectedSessionId: String? = SidebarView2.newSessionTag
    @State private var draftSessionId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(SessionManager2.self) private var manager

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView2(selection: $selectedSessionId)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
        } detail: {
            detailContent
                .frame(minWidth: 400)
        }
        .frame(minWidth: 800, minHeight: 480)
        .task(id: selectedSessionId) {
            // 进入 NewSession tab 时懒分配 draftSessionId。
            // 已绑定时不重新生成（保留用户尚未启动的草稿）。
            if selectedSessionId == SidebarView2.newSessionTag, draftSessionId == nil {
                draftSessionId = UUID().uuidString.lowercased()
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if selectedSessionId == SidebarView2.transcriptDemoTag {
            TranscriptDemoView()
        } else if selectedSessionId == SidebarView2.transcriptStressTag {
            TranscriptStressView()
        } else if let sid = effectiveSessionId {
            // `.id(sid)` 锁住 ChatHistoryView 身份:NewSession → History 过渡时
            // sid 不变(draft 的 UUID 在 Start 后就是 history 的 sessionId),
            // SwiftUI 不重建 NSView。chrome 作为 z-overlay **常驻**于每个 session,
            // 形态由 `handle.hasRecord` 驱动(card ↔ pill),自身的 spring 动画
            // 就是"底下 transcript view 没被拆"的视觉证据。
            ChatHistoryView(sessionId: sid)
                .id(sid)
                .overlay(alignment: .top) {
                    NewSessionChrome(
                        handle: chromeHandle(for: sid),
                        onStarted: handleStarted
                    )
                }
        } else {
            Color.clear
        }
    }

    /// chrome 用的 handle。`prepareDraft` 对已有 record 的 sessionId 也是
    /// get-or-create — draft 和 history 走同一路径。
    private func chromeHandle(for sid: String) -> SessionHandle2 {
        manager.prepareDraft(sid)
    }

    /// 由 tab + draft 派生的"当前展示的 sessionId"。
    private var effectiveSessionId: String? {
        if selectedSessionId == SidebarView2.newSessionTag {
            return draftSessionId
        }
        return selectedSessionId
    }

    /// Start 按钮回调:同帧完成 records 刷新 + 选中态切换 + draft 清空。
    /// effectiveSessionId 在前后两帧都是同一个 UUID,ChatHistoryView 身份不变。
    private func handleStarted(_ startedSessionId: String) {
        manager.refreshRecords()
        selectedSessionId = startedSessionId
        draftSessionId = nil
    }
}

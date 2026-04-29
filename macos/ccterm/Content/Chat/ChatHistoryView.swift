import SwiftUI

/// 两段式 historyLoadState 映射到视图分支。纯值、可测试。
enum ChatHistoryRenderCase: Equatable {
    /// `.failed` → ContentUnavailableView(reason)
    case error(String)
    /// 其它状态（`.notLoaded / .loadingTail / .tailLoaded / .loaded`）→
    /// `NativeTranscriptView(entries: snapshot.messages, reason: snapshot.reason)`。
    /// 没有 ProgressView —— 两段式 loadHistory 的 tail 一般 < 50 ms，spinner
    /// 闪一下反而劣化视觉。
    case transcript

    static func classify(_ state: SessionHandle2.HistoryLoadState) -> ChatHistoryRenderCase {
        switch state {
        case .failed(let reason): return .error(reason)
        case .notLoaded, .loadingTail, .tailLoaded, .loaded: return .transcript
        }
    }
}

/// 只读浏览历史会话。纯 SwiftUI，无 ViewModel：
/// 从环境拿 `SessionManager2` 懒取 `SessionHandle2`，触发 `loadHistory()`。
///
/// 消费契约：绑定 `handle.snapshot`（而非 `handle.messages`）—— snapshot 含
/// `TranscriptUpdateReason` + `scrollHint`，下传给 `NativeTranscriptView` 让
/// controller 按意图 dispatch scroll 语义。
///
/// **每个 sessionId 独立 NSView 生命周期**：调用点（RootView2）对 ChatHistoryView
/// 加 `.id(sessionId)`,让整个 struct 随 sessionId 重建、`@State handle` 重置
/// 为 nil,避免新 session 的首帧用旧 session 的 snapshot。离开时 `onDismantle`
/// 回调把 scroll 位置写回 `SessionHandle2.savedScrollAnchor`，下次 `.loaded`
/// re-entry 自动带上为 `scrollHint` 恢复位置（对齐 Telegram
/// `ChatInterfaceHistoryScrollState`）。
///
/// - Warning: 不要把 `.id(sessionId)` 加到 body 内部（例如 Group 上）——那样
///   只换子树 View,`@State` 属于 struct 本身不跨 id 边界,handle 会被 carry
///   over,新 session 首帧会短暂显示旧 session 的 entries + scroll state。
struct ChatHistoryView: View {
    let sessionId: String
    @Environment(SessionManager2.self) private var manager
    @State private var handle: SessionHandle2?
    /// 用户点 sidebar 进入此 view 的时间戳。透传给 NativeTranscriptView，
    /// TranscriptController 在首次 `.initialPaint` Phase 1 merge 完成时 emit
    /// OpenMetrics。
    @State private var openT0: CFAbsoluteTime?

    var body: some View {
        Group {
            if let handle {
                switch ChatHistoryRenderCase.classify(handle.historyLoadState) {
                case .error(let reason):
                    ContentUnavailableView(
                        "Failed to load history",
                        systemImage: "exclamationmark.triangle",
                        description: Text(reason)
                    )
                case .transcript:
                    NativeTranscriptView(
                        entries: handle.snapshot.messages,
                        reason: handle.snapshot.reason,
                        scrollHint: handle.snapshot.scrollHint,
                        openT0: openT0,
                        onDismantle: { [weak handle] hint in
                            handle?.savedScrollAnchor = hint
                        })
                }
            } else {
                Color.clear
            }
        }
        .task(id: sessionId) {
            let t0 = CFAbsoluteTimeGetCurrent()
            openT0 = t0
            let h = manager.session(sessionId)
            handle = h
            if let h {
                appLog(.info, "ChatHistoryView",
                    "[history] task-inject session=\(sessionId.prefix(8))… "
                    + "loadState=\(String(describing: h.historyLoadState)) "
                    + "msgCount=\(h.messages.count) "
                    + "snapReason=\(h.snapshot.reason.logTag) "
                    + "snapRev=\(h.snapshot.revision) "
                    + "savedAnchor=\(h.savedScrollAnchor != nil)")
            } else {
                appLog(.warning, "ChatHistoryView",
                    "[history] task-inject session=\(sessionId.prefix(8))… handle=nil")
            }
            h?.loadHistory()
        }
    }
}

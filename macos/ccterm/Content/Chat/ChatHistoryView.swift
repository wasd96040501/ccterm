import SwiftUI

/// 两段式 historyLoadState 映射到视图分支。纯值、可测试。
enum ChatHistoryRenderCase: Equatable {
    /// `.failed` → ContentUnavailableView(reason)
    case error(String)
    /// 其它状态(`.notLoaded / .loadingTail / .tailLoaded / .loaded`) → 渲染
    /// `NativeTranscript2View`。bridge 通过 `handle.onTimelineMutation` 接管
    /// 内容同步,no ProgressView —— Phase A 一般 < 50 ms,闪一下 spinner 反而
    /// 劣化视觉。
    case transcript

    static func classify(_ state: SessionHandle2.HistoryLoadState) -> ChatHistoryRenderCase {
        switch state {
        case .failed(let reason): return .error(reason)
        case .notLoaded, .loadingTail, .tailLoaded, .loaded: return .transcript
        }
    }
}

/// 只读浏览历史会话。纯 SwiftUI,无 ViewModel:
/// 从环境拿 `SessionManager2` 懒取 `SessionHandle2`,触发 `loadHistory()`。
///
/// 消费契约:绑定 `SessionHandle2.onTimelineMutation` — 命令式 sink,每条
/// timeline 写入 emit 一条 `TimelineMutation`,由 `Transcript2EntryBridge`
/// 翻译成 `Transcript2Controller.apply / loadInitial` 对应调用。
///
/// **每个 sessionId 独立 NSView 生命周期**:调用点(RootView2)对
/// `ChatHistoryView` 加 `.id(sessionId)`,让整个 struct 随 sessionId 重建、
/// `@State` 全部 reset,避免新 session 的首帧用旧 session 的 controller 状态。
///
/// - Warning: 不要把 `.id(sessionId)` 加到 body 内部(例如 Group 上)——
///   那样只换子树 View,`@State` 属于 struct 本身不跨 id 边界,bridge 会被
///   carry over,新 session 首帧会短暂渲染旧 session 内容。
struct ChatHistoryView: View {
    let sessionId: String
    @Environment(SessionManager2.self) private var manager
    @State private var handle: SessionHandle2?
    @State private var controller = Transcript2Controller()
    @State private var bridge: Transcript2EntryBridge?

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
                    NativeTranscript2View(controller: controller)
                }
            } else {
                Color.clear
            }
        }
        .task(id: sessionId) {
            let h = manager.session(sessionId)
            handle = h
            guard let h else {
                appLog(.warning, "ChatHistoryView",
                    "[history] task-inject session=\(sessionId.prefix(8))… handle=nil")
                return
            }
            // 先绑 sink,再调 loadHistory。`.loaded` 分支会同步 emit
            // `.reset`,顺序反了会丢首帧。
            let b = Transcript2EntryBridge(controller: controller)
            b.attach(to: h)
            bridge = b
            appLog(.info, "ChatHistoryView",
                "[history] task-inject session=\(sessionId.prefix(8))… "
                + "loadState=\(String(describing: h.historyLoadState)) "
                + "msgCount=\(h.messages.count) "
                + "savedAnchor=\(h.savedScrollAnchor != nil)")
            h.loadHistory()
        }
    }
}

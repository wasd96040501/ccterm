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
/// `TranscriptUpdateReason`，下传给 `NativeTranscriptView` 让 controller 按意图
/// dispatch scroll 语义。
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
                        openT0: openT0)
                }
            } else {
                Color.clear
            }
        }
        .task(id: sessionId) {
            openT0 = CFAbsoluteTimeGetCurrent()
            let h = manager.session(sessionId)
            handle = h
            h?.loadHistory()
        }
    }
}

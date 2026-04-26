import SwiftUI

/// 两段式 historyLoadState 映射到视图分支。纯值、可测试。
enum ChatHistoryRenderCase: Equatable {
    case error(String)
    case transcript

    static func classify(_ state: SessionHandle2.HistoryLoadState) -> ChatHistoryRenderCase {
        switch state {
        case .failed(let reason): return .error(reason)
        case .notLoaded, .loadingTail, .tailLoaded, .loaded: return .transcript
        }
    }
}

/// 单 session 的聊天页面 —— NativeTranscript(顶部贴边、底部留 48 padding 给浮动
/// InputBar)叠加 InputBarView。
///
/// 直接绑 `SessionHandle2`,**不持有 selection、不依赖 SessionManager2**。RootView2 在
/// 切换 handle 时通过 `.id(handle.sessionId)` 触发本 view 重建,`@State` 跟着
/// reset,避免新 handle 拿到旧 session 的 scroll/draft 残留。
struct ChatHistoryView: View {

    @Bindable var handle: SessionHandle2

    /// 用户进入此 view 的时间戳。透传给 NativeTranscriptView 用作 OpenMetrics
    /// 的 TTFP 起点。
    @State private var openT0: CFAbsoluteTime?

    private let inputBarBottomPadding: CGFloat = 16
    private let inputBarHorizontalPadding: CGFloat = 20
    private let transcriptBottomPadding: CGFloat = 48

    /// InputBar 最大宽度 = transcript 内容列上限 + InputBar 两侧圆角半径 ——
    /// 让 InputBar 圆角刚好"包住"transcript 的可读列宽,两边对齐看着齐整。
    private var inputBarMaxWidth: CGFloat {
        TranscriptTheme(markdown: .default).maxContentWidth + 2 * InputBarView.cornerRadius
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            transcriptArea
                .padding(.bottom, transcriptBottomPadding)

            InputBarView(handle: handle)
                .frame(minWidth: 400, idealWidth: inputBarMaxWidth, maxWidth: inputBarMaxWidth)
                .padding(.horizontal, inputBarHorizontalPadding)
                .padding(.bottom, inputBarBottomPadding)
        }
        .ignoresSafeArea(.container, edges: .top)
        .task(id: handle.sessionId) {
            let t0 = CFAbsoluteTimeGetCurrent()
            openT0 = t0
            appLog(.info, "ChatHistoryView",
                "[history] task-inject session=\(handle.sessionId.prefix(8))… "
                + "loadState=\(String(describing: handle.historyLoadState)) "
                + "msgCount=\(handle.messages.count) "
                + "snapReason=\(handle.snapshot.reason.logTag) "
                + "snapRev=\(handle.snapshot.revision) "
                + "savedAnchor=\(handle.savedScrollAnchor != nil)")
            handle.loadHistory()
        }
    }

    @ViewBuilder
    private var transcriptArea: some View {
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
    }
}

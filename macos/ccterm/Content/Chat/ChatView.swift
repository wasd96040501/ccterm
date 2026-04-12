import SwiftUI

// MARK: - Preference Key

private struct InputBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 正式聊天页面：WKWebView 展示对话 + 浮动输入栏。
struct ChatView: View {

    @Environment(AppViewModel.self) private var appVM

    @State private var inputBarHeight: CGFloat = 0

    private var handle: SessionHandle? { appVM.sessionService.activeHandle }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // WKWebView 单例，始终在 view tree 中，用 opacity 控制
                WebViewRepresentable(
                    webView: appVM.chatRendererService.webView,
                    filterToolbarHits: true,
                    cursorGuardRects: cursorGuardRects(containerHeight: geo.size.height)
                )
                .padding(.bottom, 47)
                .opacity(handle != nil && handle?.status != .notStarted
                         && appVM.isContentReady
                         && handle?.activePlanReviewId == nil ? 1 : 0)

                // 空状态占位（无 session 或新会话时显示）
                if handle == nil || handle?.status == .notStarted {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 40))
                            .foregroundStyle(.quaternary)
                        Text("Start New Conversation")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, inputBarHeight)
                }

                // Plan 全屏阅读（覆盖在 chat 上方，始终在 view tree 中，用 opacity 控制）
                WebViewRepresentable(webView: appVM.planRendererService.webView)
                    .padding(.bottom, 47)
                    .opacity(handle?.activePlanReviewId != nil ? 1 : 0)
                    .allowsHitTesting(handle?.activePlanReviewId != nil)
                    .confirmationDialog(
                        "You have unsent comments",
                        isPresented: Binding(
                            get: { handle?.pendingExecuteMode != nil },
                            set: { if !$0 { handle?.pendingExecuteMode = nil } }
                        )
                    ) {
                        Button("Execute and Discard Comments", role: .destructive) {
                            if let mode = handle?.pendingExecuteMode, let handle {
                                appVM.executePlanFromReview(handle: handle, mode: mode)
                            }
                        }
                        Button("Cancel", role: .cancel) {
                            handle?.pendingExecuteMode = nil
                        }
                    } message: {
                        Text("Your comments will be discarded after execution. Continue?")
                    }

                if let handle {
                    InputBarView(handle: handle)
                        .id(appVM.sessionService.activeSessionId)
                        .frame(minWidth: 400, idealWidth: 860, maxWidth: 860)
                        .padding(.top, 32)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(key: InputBarHeightKey.self, value: geo.size.height)
                            }
                        )
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .onPreferenceChange(InputBarHeightKey.self) { height in
            guard height != inputBarHeight else { return }
            inputBarHeight = height
            if handle?.activePlanReviewId != nil {
                appVM.planRendererService.setBottomPadding(height)
            } else {
                appVM.chatRendererService.bridge.setBottomPadding(height)
            }
        }
        .onChange(of: handle?.activePlanReviewId) { _, viewing in
            guard inputBarHeight > 0 else { return }
            if viewing != nil {
                appVM.planRendererService.setBottomPadding(inputBarHeight)
            } else {
                appVM.chatRendererService.bridge.setBottomPadding(inputBarHeight)
            }
        }
        .alert(item: Binding(
            get: { handle?.processExitError },
            set: { handle?.processExitError = $0 }
        )) { error in
            Alert(
                title: Text("Session exited with code \(error.exitCode)"),
                message: error.stderr.map { Text($0) },
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Cursor Guard

    private func cursorGuardRects(containerHeight: CGFloat) -> [CGRect] {
        if handle?.activePlanReviewId != nil {
            return [.infinite]
        }
        var rects: [CGRect] = []
        if inputBarHeight > 0 {
            rects.append(CGRect(x: 0, y: containerHeight - inputBarHeight, width: .infinity, height: inputBarHeight))
        }
        return rects
    }
}

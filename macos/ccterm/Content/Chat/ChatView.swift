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

    @Bindable var chatRouter: ChatRouter

    @State private var inputBarHeight: CGFloat = 0

    private var session: ChatSessionViewModel { chatRouter.currentSession }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // WKWebView 单例，始终在 view tree 中，用 opacity 控制
                WebViewRepresentable(
                    webView: chatRouter.chatContentView.webView,
                    filterToolbarHits: true,
                    cursorGuardRects: cursorGuardRects(containerHeight: geo.size.height)
                )
                .ignoresSafeArea(.container, edges: .top)
                .padding(.bottom, 47)
                .opacity(session.handle != nil && chatRouter.isContentReady && !session.isViewingPlan ? 1 : 0)

                // 空状态占位（无 session 时显示）
                if session.handle == nil && !session.isViewingPlan {
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
                WebViewRepresentable(webView: chatRouter.planWebViewLoader.webView)
                    .ignoresSafeArea(.container, edges: .top)
                    .padding(.bottom, 47)
                    .opacity(session.isViewingPlan ? 1 : 0)
                    .allowsHitTesting(session.isViewingPlan)
                    .confirmationDialog(
                        "You have unsent comments",
                        isPresented: Binding(
                            get: { session.pendingExecuteMode != nil },
                            set: { if !$0 { session.pendingExecuteMode = nil } }
                        )
                    ) {
                        Button("Execute and Discard Comments", role: .destructive) {
                            if let mode = session.pendingExecuteMode {
                                session.executePlan(mode: mode)
                            }
                        }
                        Button("Cancel", role: .cancel) {
                            session.pendingExecuteMode = nil
                        }
                    } message: {
                        Text("Your comments will be discarded after execution. Continue?")
                    }

                SwiftUIChatInputBar(
                    state: session,
                    actions: ChatInputBarActions(onSend: { chatRouter.submitMessage($0) })
                )
                .id(session.sessionId)
                .frame(maxWidth: 860)
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
        .onPreferenceChange(InputBarHeightKey.self) { height in
            guard height != inputBarHeight else { return }
            inputBarHeight = height
            if session.isViewingPlan {
                chatRouter.planWebViewLoader.setBottomPadding(height)
            } else {
                chatRouter.chatContentView.bridge.setBottomPadding(height)
            }
        }
        .onChange(of: session.isViewingPlan) { _, viewing in
            guard inputBarHeight > 0 else { return }
            if viewing {
                chatRouter.planWebViewLoader.setBottomPadding(inputBarHeight)
            } else {
                chatRouter.chatContentView.bridge.setBottomPadding(inputBarHeight)
            }
        }
        .alert(item: Binding(
            get: { session.processExitError },
            set: { session.processExitError = $0 }
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
        if session.isViewingPlan {
            return [.infinite]
        }
        var rects: [CGRect] = []
        // Input bar 区域
        if inputBarHeight > 0 {
            rects.append(CGRect(x: 0, y: containerHeight - inputBarHeight, width: .infinity, height: inputBarHeight))
        }
        return rects
    }
}

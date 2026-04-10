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

    private var viewModel: InputBarViewModel { chatRouter.currentViewModel }

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
                .opacity(viewModel.handle != nil && chatRouter.isContentReady && !viewModel.planReviewVM.isActive ? 1 : 0)

                // 空状态占位（无 session 时显示）
                if viewModel.handle == nil && !viewModel.planReviewVM.isActive {
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
                    .opacity(viewModel.planReviewVM.isActive ? 1 : 0)
                    .allowsHitTesting(viewModel.planReviewVM.isActive)
                    .confirmationDialog(
                        "You have unsent comments",
                        isPresented: Binding(
                            get: { viewModel.planReviewVM.pendingExecuteMode != nil },
                            set: { if !$0 { viewModel.planReviewVM.pendingExecuteMode = nil } }
                        )
                    ) {
                        Button("Execute and Discard Comments", role: .destructive) {
                            if let mode = viewModel.planReviewVM.pendingExecuteMode {
                                viewModel.planReviewVM.executePlan(mode: mode)
                            }
                        }
                        Button("Cancel", role: .cancel) {
                            viewModel.planReviewVM.pendingExecuteMode = nil
                        }
                    } message: {
                        Text("Your comments will be discarded after execution. Continue?")
                    }

                InputBarView(viewModel: viewModel)
                    .id(viewModel.sessionId)
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
        .onPreferenceChange(InputBarHeightKey.self) { height in
            guard height != inputBarHeight else { return }
            inputBarHeight = height
            if viewModel.planReviewVM.isActive {
                chatRouter.planWebViewLoader.setBottomPadding(height)
            } else {
                chatRouter.chatContentView.bridge.setBottomPadding(height)
            }
        }
        .onChange(of: viewModel.planReviewVM.isActive) { _, viewing in
            guard inputBarHeight > 0 else { return }
            if viewing {
                chatRouter.planWebViewLoader.setBottomPadding(inputBarHeight)
            } else {
                chatRouter.chatContentView.bridge.setBottomPadding(inputBarHeight)
            }
        }
        .alert(item: Binding(
            get: { viewModel.processExitError },
            set: { viewModel.processExitError = $0 }
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
        if viewModel.planReviewVM.isActive {
            return [.infinite]
        }
        var rects: [CGRect] = []
        if inputBarHeight > 0 {
            rects.append(CGRect(x: 0, y: containerHeight - inputBarHeight, width: .infinity, height: inputBarHeight))
        }
        return rects
    }
}

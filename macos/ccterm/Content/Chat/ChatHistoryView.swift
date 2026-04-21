import SwiftUI

/// 只读浏览历史会话。纯 SwiftUI，无 ViewModel：
/// 从环境拿 `SessionManager2` 懒取 `SessionHandle2`，触发 `loadHistory()`，
/// 按 `historyLoadState` 分派渲染。
struct ChatHistoryView: View {
    let sessionId: String
    @Environment(SessionManager2.self) private var manager
    @State private var handle: SessionHandle2?

    var body: some View {
        Group {
            if let handle {
                content(for: handle)
            } else {
                Color.clear
            }
        }
        .task(id: sessionId) {
            let h = manager.session(sessionId)
            handle = h
            h?.loadHistory()
        }
    }

    @ViewBuilder
    private func content(for handle: SessionHandle2) -> some View {
        switch handle.historyLoadState {
        case .notLoaded, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let reason):
            ContentUnavailableView(
                "Failed to load history",
                systemImage: "exclamationmark.triangle",
                description: Text(reason)
            )
        case .loaded:
            NativeTranscriptView(entries: handle.messages)
        }
    }
}

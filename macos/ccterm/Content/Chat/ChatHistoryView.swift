import SwiftUI

/// Maps the two-phase `historyLoadState` to a view branch. Pure value, testable.
enum ChatHistoryRenderCase: Equatable {
    case error(String)
    /// Any non-failed state (`.notLoaded / .loadingTail / .tailLoaded / .loaded`)
    /// renders `NativeTranscript2View`. The bridge syncs content via
    /// `handle.onMessagesChange`. No ProgressView — Phase A is typically
    /// < 50 ms, and a flashed spinner reads worse than a brief blank.
    case transcript

    static func classify(_ state: SessionHandle2.HistoryLoadState) -> ChatHistoryRenderCase {
        switch state {
        case .failed(let reason): return .error(reason)
        case .notLoaded, .loadingTail, .tailLoaded, .loaded: return .transcript
        }
    }
}

/// Read-only history browser. Pure SwiftUI, no ViewModel: pulls
/// `SessionManager2` from the environment, lazily acquires a `SessionHandle2`,
/// and kicks `loadHistory()`.
///
/// Consumes `SessionHandle2.onMessagesChange` — a synchronous sink. Each
/// `messages` write pushes one `MessagesChange`, which `Transcript2EntryBridge`
/// translates into `Transcript2Controller.apply / loadInitial` calls.
///
/// **Per-session NSView lifecycle**: the call site (RootView2) attaches
/// `.id(sessionId)` to `ChatHistoryView`, so the whole struct rebuilds when
/// `sessionId` changes and all `@State` resets. This prevents a new session's
/// first frame from inheriting the old session's controller state.
///
/// - Warning: Do not move `.id(sessionId)` inside `body` (e.g. on a Group).
///   That only swaps the child subtree; `@State` belongs to the struct itself
///   and doesn't cross the id boundary, so the bridge carries over and the
///   new session's first frame briefly renders the old session's content.
struct ChatHistoryView: View {
    let sessionId: String
    @Environment(SessionManager2.self) private var manager
    @State private var handle: SessionHandle2?
    @State private var controller = Transcript2Controller()
    @State private var bridge: Transcript2EntryBridge?
    /// `.findInTranscript` notification (posted by the app-scope ⌘F
    /// menu item, see `AppCommands`) toggles this. Per-session
    /// because `ChatHistoryView` is `.id(sessionId)`-rebuilt; users
    /// coming back to a session start with the bar hidden.
    @State private var isSearchVisible: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
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

            if isSearchVisible {
                ChatSearchBarView(
                    controller: controller,
                    onDismiss: { isSearchVisible = false }
                )
                .padding(.top, 12)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isSearchVisible)
        .onReceive(NotificationCenter.default.publisher(for: .findInTranscript)) { _ in
            isSearchVisible.toggle()
        }
        .task(id: sessionId) {
            // Use `prepareDraft` so a draft session (no record yet) still gets a
            // handle and mounts `NativeTranscript2View` — this keeps the NSView
            // identity stable across Start, so the chrome overlay's morph animation
            // is visible proof that the transcript didn't rebuild. `prepareDraft`
            // is idempotent get-or-create for existing-record session ids too.
            let h = manager.prepareDraft(sessionId)
            handle = h
            // Bind the sink before calling loadHistory. The `.loaded` branch
            // synchronously emits `.reset`; reversed order loses the first frame.
            let b = Transcript2EntryBridge(controller: controller)
            b.attach(to: h)
            bridge = b
            appLog(
                .info, "ChatHistoryView",
                "[history] task-inject session=\(sessionId.prefix(8))… "
                    + "loadState=\(String(describing: h.historyLoadState)) "
                    + "msgCount=\(h.messages.count)")
            h.loadHistory()
        }
    }
}

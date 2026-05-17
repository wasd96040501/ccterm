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
/// **Search bar lives in the window toolbar via `.searchable`** — the
/// native macOS search field renders in the toolbar's trailing slot. ⌘F
/// focus is handed in via `TranscriptSearchBus` + `.searchFocused`. The
/// toolbar keeps its natural material background so the search field
/// reads as a native control; the top fade-blur scrim in `RootView2`
/// softens the seam between toolbar chrome and the first transcript row.
///
/// **Navigation keys**: plain `Return` advances to the next match (wired
/// through `.onSubmit(of: .search)` while the field has focus);
/// `Shift+Return` steps to the previous match via `.onKeyPress(.return)`
/// inspecting `KeyPress.modifiers`. There are no prev / next / counter
/// chrome items — the user navigates entirely from the keyboard.
///
/// - Warning: Do not move `.id(sessionId)` inside `body` (e.g. on a Group).
///   That only swaps the child subtree; `@State` belongs to the struct itself
///   and doesn't cross the id boundary, so the bridge carries over and the
///   new session's first frame briefly renders the old session's content.
struct ChatHistoryView: View {
    let sessionId: String
    @Environment(SessionManager2.self) private var manager
    @Environment(TranscriptSearchBus.self) private var searchBus
    @State private var handle: SessionHandle2?
    @State private var controller = Transcript2Controller()
    @State private var bridge: Transcript2EntryBridge?
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFocused: Bool

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
        .searchable(
            text: $searchQuery,
            placement: .toolbar,
            prompt: Text("Find in transcript")
        )
        .searchFocused($isSearchFocused)
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
        }
        .onSubmit(of: .search) { controller.nextSearchHit() }
        // Shift+Return for previous match. `.onKeyPress` fires whenever
        // focus is on this view or any descendant — i.e. the search
        // field. Plain Return is left to `.onSubmit(of: .search)`; we
        // return `.ignored` so SwiftUI propagates the event. The
        // `phases:` overload is the one that exposes `KeyPress.modifiers`.
        .onKeyPress(keys: [.return], phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.shift) else { return .ignored }
            controller.previousSearchHit()
            return .handled
        }
        .onChange(of: searchQuery) { _, new in
            controller.runSearch(new)
        }
        .onChange(of: searchBus.focusRequestCounter) { _, _ in
            isSearchFocused = true
        }
        // `handle?.isRunning` is `@Observable`, so this fires
        // whenever the session's turn count crosses 0. The pill is
        // the controller-managed sentinel row at the transcript's
        // tail — keep the view side strictly read-only against the
        // handle and let the controller own block-level mutation.
        // Also reacts to the initial nil → handle binding so a
        // re-entered running session lights the pill immediately.
        .onChange(of: handle?.isRunning ?? false, initial: true) { _, new in
            controller.setLoading(new)
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

import SwiftUI

/// Maps the two-phase `historyLoadState` to a view branch. Pure value, testable.
enum ChatHistoryRenderCase: Equatable {
    case error(String)
    /// Any non-failed state (`.notLoaded / .loadingTail / .tailLoaded / .loaded`)
    /// renders `NativeTranscript2View`. The bridge syncs content via
    /// `session.onMessagesChange`. No ProgressView — Phase A is typically
    /// < 50 ms, and a flashed spinner reads worse than a brief blank.
    case transcript

    static func classify(_ state: SessionRuntime.HistoryLoadState) -> ChatHistoryRenderCase {
        switch state {
        case .failed(let reason): return .error(reason)
        case .notLoaded, .loadingTail, .tailLoaded, .loaded: return .transcript
        }
    }
}

/// Read-only history browser. Pure SwiftUI, no ViewModel: pulls
/// `SessionManager` from the environment, resolves a `Session`, and
/// hands the session's controller to `NativeTranscript2View`.
///
/// **Controller / bridge ownership.** Both `Transcript2Controller` and
/// `Transcript2EntryBridge` live on `Session` (not on this view) and
/// have the same lifetime as the session. The bridge subscribes to
/// `runtime.onMessagesChange` permanently — live CLI events flow into
/// the controller's block list even when no `ChatHistoryView` is
/// mounted. This view simply rebinds the controller's coordinator to
/// a fresh `NSTableView` per mount; the coordinator's `tableView.didSet`
/// runs `reloadData()` automatically so the table picks up whatever
/// block state accumulated while detached. **Switch-away → switch-back
/// is O(1) on the renderer side** (no JSONL re-read, no re-derive of
/// blocks, no markdown reparse).
///
/// **Per-session NSView lifecycle**: the call site (RootView2) attaches
/// `.id(sessionId)` to `ChatHistoryView`, so the whole struct rebuilds
/// when `sessionId` changes and `@State` resets. The view-local state
/// is just `searchQuery` / `searchFocused` — the heavy renderer state
/// (block list, layout cache, fold/status dicts) belongs to
/// `session.controller` and survives the id flip.
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
/// inspecting `KeyPress.modifiers`.
struct ChatHistoryView: View {
    let sessionId: String
    @Environment(SessionManager.self) private var manager
    @Environment(TranscriptSearchBus.self) private var searchBus
    @State private var session: Session?
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        Group {
            if let session {
                switch ChatHistoryRenderCase.classify(session.historyLoadState) {
                case .error(let reason):
                    ContentUnavailableView(
                        "Failed to load history",
                        systemImage: "exclamationmark.triangle",
                        description: Text(reason)
                    )
                case .transcript:
                    NativeTranscript2View(controller: session.controller)
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
        .onSubmit(of: .search) { session?.controller.nextSearchHit() }
        // Shift+Return for previous match. `.onKeyPress` fires whenever
        // focus is on this view or any descendant — i.e. the search
        // field. Plain Return is left to `.onSubmit(of: .search)`; we
        // return `.ignored` so SwiftUI propagates the event. The
        // `phases:` overload is the one that exposes `KeyPress.modifiers`.
        .onKeyPress(keys: [.return], phases: .down) { keyPress in
            guard keyPress.modifiers.contains(.shift) else { return .ignored }
            session?.controller.previousSearchHit()
            return .handled
        }
        .onChange(of: searchQuery) { _, new in
            session?.controller.runSearch(new)
        }
        .onChange(of: searchBus.focusRequestCounter) { _, _ in
            isSearchFocused = true
        }
        // `session?.isRunning` is `@Observable`, so this fires
        // whenever the session's turn count crosses 0. The pill is
        // the controller-managed sentinel row at the transcript's
        // tail — keep the view side strictly read-only against the
        // session and let the controller own block-level mutation.
        // Also reacts to the initial nil → session binding so a
        // re-entered running session lights the pill immediately.
        .onChange(of: session?.isRunning ?? false, initial: true) { _, new in
            session?.controller.setLoading(new)
        }
        .task(id: sessionId) {
            // `prepareDraftSession` is idempotent get-or-create — a
            // draft session (no record yet) still gets a Session façade,
            // and existing-record session ids return the same cached
            // instance (possibly in `.active` phase). The session's
            // bridge has already been wired to its runtime; nothing for
            // us to do besides kick `loadHistory` and scroll to the tail.
            let s = manager.prepareDraftSession(sessionId)
            session = s
            appLog(
                .info, "ChatHistoryView",
                "[history] task-inject session=\(sessionId.prefix(8))… "
                    + "loadState=\(String(describing: s.historyLoadState)) "
                    + "msgCount=\(s.messages.count) "
                    + "blockCount=\(s.controller.blockCount)")
            s.loadHistory()
            // For re-entry (already loaded, blocks already populated by
            // the continuous bridge), reload's default scroll position
            // is the top; pin to the tail so the user lands where they
            // left off. Cold loads still scroll to bottom via Phase A's
            // `loadInitial(anchor: .bottom)`.
            s.controller.scrollToBottom()
        }
    }
}

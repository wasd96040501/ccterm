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
    /// `false` suppresses the toolbar search field. Compose mode (the
    /// New Session tab) keeps the transcript mounted as a backdrop but
    /// covers it with `NewSessionConfigurator`, so an active search
    /// field there reads as out-of-place chrome.
    var showsSearch: Bool = true
    @Environment(SessionManager.self) private var manager
    @Environment(TranscriptSearchBus.self) private var searchBus
    @State private var session: Session?
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        coreContent
            .modifier(
                TranscriptSearchToolbar(
                    enabled: showsSearch,
                    query: $searchQuery,
                    focused: $isSearchFocused,
                    onNext: { session?.controller.nextSearchHit() },
                    onPrevious: { session?.controller.previousSearchHit() },
                    onQueryChange: { session?.controller.runSearch($0) },
                    focusRequestCounter: searchBus.focusRequestCounter
                )
            )
    }

    @ViewBuilder
    private var coreContent: some View {
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
            // Mounting / re-attaching the transcript view is handled
            // entirely inside the coordinator: every fresh `NSTableView`
            // attach resets `isAnchorSettled` and the next 0→positive
            // `tableFrameDidChange` consumes `desiredAnchor` (default
            // `.bottom`) before flipping `isAnchorSettled` back to true.
            // Cold loads override the anchor through Phase A's
            // `setHistory(anchor: .bottom)`; re-entry uses the carried-
            // over default. The view no longer needs to push scroll.
            // `.onChange(of: isRunning)` only fires on transitions, and
            // its `initial: true` invocation ran above with `session`
            // still nil (no-op via `session?`). If running ended while
            // this view was unmounted, the controller's pill is still
            // installed from the previous mount — explicitly sync to
            // the current value here.
            s.controller.setLoading(s.isRunning)
        }
    }
}

extension View {
    @ViewBuilder
    fileprivate func searchFocusedIfAvailable(_ binding: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15.0, *) {
            self.searchFocused(binding)
        } else {
            self
        }
    }
}

/// Conditionally applies the toolbar search field and its keyboard /
/// navigation modifiers. `enabled=false` strips the entire chain so
/// callers (compose mode) don't show a search field over a backdrop the
/// user can't see. The modifier is the single mount point so callers
/// only set one parameter to toggle the whole feature.
private struct TranscriptSearchToolbar: ViewModifier {
    let enabled: Bool
    @Binding var query: String
    @FocusState.Binding var focused: Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onQueryChange: (String) -> Void
    let focusRequestCounter: Int

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(
                    text: $query,
                    placement: .toolbar,
                    prompt: Text("Find in transcript")
                )
                // `.searchFocused` is macOS 15+. On 14 the search field still works
                // for typing — only the programmatic ⌘F-from-bus focus path degrades.
                .searchFocusedIfAvailable($focused)
                .toolbar {
                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.flexible)
                    }
                }
                .onSubmit(of: .search) { onNext() }
                // Shift+Return for previous match. `.onKeyPress` fires whenever
                // focus is on this view or any descendant — i.e. the search
                // field. Plain Return is left to `.onSubmit(of: .search)`; we
                // return `.ignored` so SwiftUI propagates the event. The
                // `phases:` overload is the one that exposes `KeyPress.modifiers`.
                .onKeyPress(keys: [.return], phases: .down) { keyPress in
                    guard keyPress.modifiers.contains(.shift) else { return .ignored }
                    onPrevious()
                    return .handled
                }
                .onChange(of: query) { _, new in
                    onQueryChange(new)
                }
                .onChange(of: focusRequestCounter) { _, _ in
                    focused = true
                }
        } else {
            content
        }
    }
}

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
/// **Search bar lives in the window toolbar via `.searchable`** — the native
/// macOS `NSSearchField` renders in the toolbar's trailing slot. ⌘F focus
/// is handed in via `TranscriptSearchBus` + `.searchFocused`. The transcript
/// runs flush against the window's top edge with the search field reading as
/// a chromeless floating affordance. That flush behavior is a four-modifier
/// recipe: `.windowStyle(.hiddenTitleBar)` and `.windowToolbarStyle(.unifiedCompact)`
/// on the `Window` scene collapse the toolbar into the title-bar band
/// (instead of stacking under it) and enable `fullSizeContentView`;
/// `.toolbarBackground(.hidden, for: .windowToolbar)` here keeps the
/// toolbar's material from painting over the transcript; and
/// `.ignoresSafeArea(edges: .top)` at the `RootView2` call site lets the
/// transcript extend up under the toolbar slot.
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
        // Hide the toolbar's material background so the transcript can
        // run flush to the window's top edge under the floating search
        // field. Combined with `.ignoresSafeArea(edges: .top)` at the
        // call site in RootView2, this gives a true edge-to-edge
        // transcript with the search field as a chromeless overlay.
        .toolbarBackground(.hidden, for: .windowToolbar)
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
            // Warm up the CLI subprocess now (spawn + initialize round-trip) so
            // slashCommands / availableModels / contextWindow are populated by
            // the time the user types, and the first `send(_:)` doesn't pay
            // the ~6-8s bootstrap cost synchronously after the click. Idempotent
            // on non-fresh / running sessions.
            h.activate()
        }
    }
}

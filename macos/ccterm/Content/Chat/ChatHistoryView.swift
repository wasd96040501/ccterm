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
/// macOS search field renders in the toolbar's trailing slot. ⌘F focus is
/// handed in via `TranscriptSearchBus` + `.searchFocused`. The transcript
/// itself sits flush against the window chrome with no in-pane strip.
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
        .onChange(of: searchQuery) { _, new in
            controller.runSearch(new)
        }
        .onChange(of: searchBus.focusRequestCounter) { _, _ in
            isSearchFocused = true
        }
        .toolbar { searchAccessoryToolbar }
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

    /// Counter + prev / next buttons that sit next to the toolbar search
    /// field. The counter is hidden while the query is empty so the
    /// toolbar isn't cluttered before the user types.
    @ToolbarContentBuilder
    private var searchAccessoryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !searchQuery.isEmpty {
                let total = controller.searchState.totalHits
                let current = total > 0 ? (controller.searchState.currentIndex ?? -1) + 1 : 0
                Text("\(current) / \(total)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .testIdentifier("ChatSearchBar.Counter")
            }

            Button {
                controller.previousSearchHit()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(controller.searchState.totalHits == 0)
            .keyboardShortcut(.return, modifiers: [.shift])
            .testIdentifier("ChatSearchBar.PrevButton")
            .help(String(localized: "Previous match"))

            Button {
                controller.nextSearchHit()
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(controller.searchState.totalHits == 0)
            .testIdentifier("ChatSearchBar.NextButton")
            .help(String(localized: "Next match"))
        }
    }
}

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
/// **Search bar floats as an overlay** — `TranscriptSearchOverlayView` is
/// anchored to the top-trailing corner of the transcript with an `HStack`
/// `Spacer` doing the right-alignment. Floating (rather than living in
/// the AppKit window toolbar via `.searchable(placement: .toolbar)`) keeps
/// the transcript truly flush to the window's top edge — a SwiftUI window
/// toolbar reserves vertical chrome that `.ignoresSafeArea` cannot fully
/// reclaim. The top fade-blur scrim in `RootView2` provides the visual
/// transition between the search field and the first row.
///
/// **Navigation keys**: plain `Return` advances to the next match (the
/// field's `.onSubmit` calls `controller.nextSearchHit()`); `Shift+Return`
/// steps to the previous match via an `.onKeyPress(keys: [.return])` that
/// inspects `KeyPress.modifiers`.
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
    // `@State Bool` rather than `@FocusState` because focus is driven
    // through AppKit (`NSSearchField`-via-`NSViewRepresentable`) — a
    // `Binding<Bool>` is what crosses into the representable. The flag
    // is set from two directions: ⌘F (via `TranscriptSearchBus`) flips
    // it to `true`, and the field's begin / end editing notifications
    // flip it back from AppKit.
    @State private var isSearchFocused: Bool = false

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
        .overlay(alignment: .top) {
            // HStack + leading `Spacer` is the user-requested
            // right-alignment idiom: the spacer absorbs all available
            // horizontal slack so the search field is pushed flush to
            // the trailing edge. The overlay sits in the same band the
            // top fade-blur scrim covers, so the field reads as a
            // chromeless floating affordance over the first row.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                TranscriptSearchOverlayView(
                    query: $searchQuery,
                    isFocused: $isSearchFocused,
                    onNext: { controller.nextSearchHit() },
                    onPrevious: { controller.previousSearchHit() }
                )
            }
            .padding(.top, 16)
            .padding(.trailing, 16)
        }
        .onChange(of: searchQuery) { _, new in
            controller.runSearch(new)
        }
        .onChange(of: searchBus.focusRequestCounter) { _, _ in
            isSearchFocused = true
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
            // Warm up the CLI subprocess now (spawn + initialize round-trip) so
            // slashCommands / availableModels / contextWindow are populated by
            // the time the user types, and the first `send(_:)` doesn't pay
            // the ~6-8s bootstrap cost synchronously after the click. Idempotent
            // on non-fresh / running sessions.
            h.activate()
        }
    }
}

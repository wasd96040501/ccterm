# Chat UI

How the chat pane is assembled. There is **no ViewModel** — `MainSplitViewController` + `TranscriptDetailViewController` (both AppKit) coordinate the pieces, and the three SwiftUI building blocks below don't know about each other.

| Component | Type | Instances | Responsibility |
|---|---|---|---|
| `MainWindowController` | NSWindowController | 1 | Owns the main NSWindow, NSToolbar (project chip + transcript search field). |
| `MainSplitViewController` | NSSplitViewController | 1 | Sidebar item (hosts `SidebarView2`) + detail item (`TranscriptDetailViewController`). |
| `MainSelectionModel` | `@Observable` | 1 | Shared selection / draft state — `selectedSessionId`, `draftSessionId`, draft cwd / worktree / branch, attach + pill rects. |
| `SidebarView2` | View (SwiftUI, hosted via `NSHostingController`) | 1 | Reads `SessionManager.records` to render the history list; writes back the selected `sessionId` via `@Binding` to the model. |
| `TranscriptDetailViewController` | NSViewController | 1 | Owns the `Transcript2ScrollView` directly via `TranscriptScrollViewFactory`; hosts SwiftUI overlays (top + bottom scrim, input bar / compose configurator) via `NSHostingView`. Drives session attach (`loadHistory`, `setLoading`) when `MainSelectionModel.effectiveSessionId` changes. |
| `InputBarView2` | View | per-session | Pure UI (text field + send/stop button); `onSubmit` / `onStop` / `isRunning` are injected. No longer hosts a running pill — the indicator lives inside the transcript. |
| `ChatHistoryView` | View | demo-only | Legacy SwiftUI wrapper retained only for `PermissionSessionDemoView`. Production transcripts go through `TranscriptDetailViewController` directly. |

## Ownership graph

```
AppDelegate (NSApplicationDelegate)
├── appState: AppState
│   ├── sessionManager: SessionManager
│   │   └── sessions: [String: Session]
│   │         └── each Session owns:
│   │             ├── phase: .draft(SessionDraft) | .active(SessionRuntime)
│   │             ├── controller: Transcript2Controller     ← render-side state
│   │             └── bridge:     Transcript2EntryBridge    ← always wired to runtime
│   └── syntaxEngine: SyntaxHighlightEngine
├── searchBus: TranscriptSearchBus
├── selectionModel: MainSelectionModel
└── mainWindowController: MainWindowController
    ├── NSToolbar (project chip + transcript search NSSearchField)
    └── MainSplitViewController
        ├── Sidebar item → NSHostingController(SidebarView2)
        └── Detail item → TranscriptDetailViewController
            ├── transcriptScroll: Transcript2ScrollView (AppKit-native)
            │   └── session.controller drives blocks; isRunning → setLoading
            ├── topScrimHost: NSHostingView<FadeScrim>
            ├── bottomScrimHost: NSHostingView<FadeScrim with cut-outs>
            └── composeOrBarHost: NSHostingView<NewSessionConfigurator | ChatRestingBar>
```

## Data flow

- **History load** — `TranscriptDetailViewController.attachSession(_:)` runs → `manager.prepareDraftSession(sessionId)` returns a `Session` (controller + bridge already exist and are wired to the runtime) → `session.loadHistory()` runs (`.notLoaded` dispatches Phase A/B; `.loadingTail` / `.tailLoaded` / `.loaded` are idempotent no-ops) → for cold loads, the bridge translates `MessagesChange` into `controller.loadInitial / apply` calls → `NativeTranscript2` diff-renders. For re-entry, blocks are already in the controller from the continuous bridge — the new `NSTableView` rebinds to the same coordinator and auto-`reloadData`s; `controller.scrollToBottom()` anchors the table at the tail.
- **Running-state rendering** — `Session.isRunning` is `@Observable` (forwards to `runtime?.isRunning ?? false`). SwiftUI tracks it automatically for the input bar (send ↔ stop swap). For the trailing `.loadingPill` row, `TranscriptDetailViewController.startRunningObservation(for:)` listens via `withObservationTracking` and calls `Transcript2Controller.setLoading(_:)` on every flip. The pill row is the controller's responsibility (not the bridge's) — the bridge stays focused on entry-driven content.
- **Incoming messages** — CLI pushes a message → `SessionRuntime.receive` updates `messages` and fires `onMessagesChange` → `Session.wireRuntimeMessagesSink` closure dispatches first to `bridge.apply`, then to the optional `session.onMessagesChange` external observer. The bridge is wired once at `Session.init` and survives view mount/dismount — events flow into the controller continuously, even for sessions the user is not currently viewing.
- **Session switch** — `SidebarView2` writes a new value → `MainSelectionModel.selectedSessionId` changes → `TranscriptDetailViewController`'s observation tracking fires → `attachSession(_:)` tears down the old `Transcript2ScrollView` (via `TranscriptScrollViewFactory.dismantle`) and constructs a fresh one for the new session's controller. The new `NSTableView` rebinds to `session.controller.coordinator` on `tableView.didSet`, which runs `reloadData()` so the table picks up whatever block state accumulated while detached.
- **Draft → real session** — entering the New Session tab makes `TranscriptDetailViewController.handleSelectionChanged()` lazily allocate a `draftSessionId` on `MainSelectionModel`. The user's first message triggers `session.draft?.setCwd(home)` / `setWorktree` / `setSourceBranch` then `session.send(text)`. `session.send` constructs a `SessionRuntime` via `SessionRuntime.fromDraft(...)`, copies the draft's config / title verbatim, queues the user input, runs `wireRuntimeMessagesSink(runtime)` to install the bridge-then-external multiplex closure on the new runtime, flips `phase = .active(runtime)`, kicks off bootstrap, and fires `onPromoted`. The manager's `refreshRecords()` hook is registered there, so the sidebar surfaces the new session immediately.

## Rules

- Views never mutate session running / status / message state directly. All writes go through `Session` methods (which dispatch on phase under the hood).
- Draft-only setters (`setCwd` / `setWorktree` / `setOriginPath` / `setSourceBranch` / `setPluginDirectories`) are reached through `session.draft?` — non-nil only while the session is still in `.draft` phase. Calls after promotion are silently no-op (the `draft?` is nil).
- Runtime-mutable setters (`setModel` / `setEffort` / `setPermissionMode` / `setFastMode` / `setAdditionalDirectories`) are called as `session.setX(...)` regardless of phase; the façade routes to the draft or the runtime as appropriate.
- The UI only reads `@Observable` properties on the session; it never holds its own copy.
- A new piece of session runtime state means adding an `@Observable` field on `SessionRuntime` AND a forwarding accessor on `Session` — views read it via `session.X`.
- Cross-view coordination uses closures injected from `TranscriptDetailViewController` (e.g. `onSubmit`, `onAttachRect` / `onPillRect` on `InputBarChrome`). Don't introduce a new ViewModel layer.

## See also

- [NativeTranscript2/CLAUDE.md](NativeTranscript2/CLAUDE.md) — the transcript renderer (layouts, diff, tool rendering).
- [Services/Session/CLAUDE.md](../../Services/Session/CLAUDE.md) — `Session` / `SessionRuntime` / `SessionDraft` internals and how state reaches the UI.

# Chat UI

How the chat pane is assembled. There is **no ViewModel** — `RootView2` is the only coordinator, and the three building blocks below don't know about each other.

| Component | Type | Instances | Responsibility |
|---|---|---|---|
| `RootView2` | View | 1 | Owns selection / draft `sessionId` locally; assembles sidebar + transcript + input bar |
| `SidebarView2` | View | 1 | Reads `SessionManager.records` to render the history list; writes back the selected `sessionId` via `@Binding` |
| `ChatHistoryView` | View | per-session (`.id(sessionId)`) | Acquires a `Session`, kicks `loadHistory()`, renders `NativeTranscript2View(controller: session.controller)`; mirrors `session.isRunning` into `Transcript2Controller.setLoading(_:)` so the trailing "running" pill row tracks the session. Does **not** own a controller or bridge — both live on `Session`. |
| `InputBarView2` | View | per-session | Pure UI (text field + send/stop button); `onSubmit` / `onStop` / `isRunning` are injected. No longer hosts a running pill — the indicator lives inside the transcript |

## Ownership graph

```
AppState
├── sessionManager: SessionManager (env)
│   └── sessions: [String: Session]
│         └── each Session owns:
│             ├── phase: .draft(SessionDraft) | .active(SessionRuntime)
│             ├── controller: Transcript2Controller     ← render-side state
│             └── bridge:     Transcript2EntryBridge    ← always wired to runtime
└── syntaxEngine: SyntaxHighlightEngine (env)

RootView2
├── @State selectedSessionId, draftSessionId
└── @Environment SessionManager
    │
    ├── SidebarView2 (selection: $selectedSessionId)
    └── Detail:
        ├── ChatHistoryView(sessionId)
        │   ├── manager.prepareDraftSession(sessionId) → Session
        │   ├── NativeTranscript2View(controller: session.controller)
        │   ├── session.controller.requestAnchor(saved-or-.bottom) on mount
        │   └── .onChange(session.isRunning) → session.controller.setLoading(...)
        └── InputBarChrome
            └── InputBarView2 (onSubmit → session.send / onStop → session.interrupt)
```

## Data flow

- **History load** — `ChatHistoryView` mounts → `manager.prepareDraftSession(sessionId)` returns a `Session` (controller + bridge already exist and are wired to the runtime) → `session.loadHistory()` runs (`.notLoaded` dispatches Phase A/B; `.loadingTail` / `.tailLoaded` / `.loaded` are idempotent no-ops) → for cold loads, the bridge translates `MessagesChange` into `controller.loadInitial / apply` calls → `NativeTranscript2` diff-renders. For re-entry, blocks are already in the controller from the continuous bridge — the new `NSTableView` rebinds to the same coordinator and auto-`reloadData`s.
- **Scroll-anchor lifecycle** — uniform across cold load and re-entry. On mount, `ChatHistoryView.task` calls `controller.requestAnchor(...)` with `.preserved(session.lastVisibleAnchor)` if the user has a saved position, otherwise `.bottom`. The coordinator's `tableView.didSet` resets `lastLayoutWidth = -1`, so the new table's first `tableFrameDidChange` re-fires `onLayoutReady` → `consumePendingAnchor`, landing the scroll after `reloadData()` has settled. On unmount, `NativeTranscript2View.dismantleNSView` snapshots the topmost-visible row + sub-row offset via `coordinator.captureVisibleAnchor()` and the `onWillDetach` hook persists it into `session.lastVisibleAnchor`. Cold load's `loadInitial(anchor: .bottom)` continues to route through the same `pendingAnchor` field; both paths share one consumption mechanism.
- **Running-state rendering** — `Session.isRunning` is `@Observable` (forwards to `runtime?.isRunning ?? false`). SwiftUI tracks it automatically: `InputBarView2` swaps send ↔ stop, and `ChatHistoryView`'s `.onChange(of: session.isRunning)` calls `Transcript2Controller.setLoading(_:)` which inserts / removes a `.loadingPill` row at the transcript's tail. The pill row is the controller's responsibility (not the bridge's) — the bridge stays focused on entry-driven content.
- **Incoming messages** — CLI pushes a message → `SessionRuntime.receive` updates `messages` and fires `onMessagesChange` → `Session.wireRuntimeMessagesSink` closure dispatches first to `bridge.apply`, then to the optional `session.onMessagesChange` external observer. The bridge is wired once at `Session.init` and survives view mount/dismount — events flow into the controller continuously, even for sessions the user is not currently viewing.
- **Session switch** — `SidebarView2` writes a new value → `selectedSessionId` changes → the `.id(sid)` on `ChatHistoryView` forces a SwiftUI rebuild (only `searchQuery` / `searchFocused` reset; the controller and bridge belong to `Session` and survive). The new `NSTableView` rebinds to `session.controller.coordinator` on `makeNSView`; `Transcript2Coordinator.tableView.didSet` runs `reloadData()` so the table picks up whatever block state accumulated while detached.
- **Draft → real session** — entering the New Session tab makes `RootView2` lazily allocate a `draftSessionId`. The user's first message triggers `session.draft?.setCwd(home)` / `setWorktree` / `setSourceBranch` then `session.send(text)`. `session.send` constructs a `SessionRuntime` via `SessionRuntime.fromDraft(...)`, copies the draft's config / title verbatim, queues the user input, runs `wireRuntimeMessagesSink(runtime)` to install the bridge-then-external multiplex closure on the new runtime, flips `phase = .active(runtime)`, kicks off bootstrap, and fires `onPromoted`. The manager's `refreshRecords()` hook is registered there, so the sidebar surfaces the new session immediately.

## Rules

- Views never mutate session running / status / message state directly. All writes go through `Session` methods (which dispatch on phase under the hood).
- Draft-only setters (`setCwd` / `setWorktree` / `setOriginPath` / `setSourceBranch` / `setPluginDirectories`) are reached through `session.draft?` — non-nil only while the session is still in `.draft` phase. Calls after promotion are silently no-op (the `draft?` is nil).
- Runtime-mutable setters (`setModel` / `setEffort` / `setPermissionMode` / `setFastMode` / `setAdditionalDirectories`) are called as `session.setX(...)` regardless of phase; the façade routes to the draft or the runtime as appropriate.
- The UI only reads `@Observable` properties on the session; it never holds its own copy.
- A new piece of session runtime state means adding an `@Observable` field on `SessionRuntime` AND a forwarding accessor on `Session` — views read it via `session.X`.
- Cross-view coordination uses closures injected from `RootView2` (e.g. `onSubmit`, `onBarRect` on `InputBarChrome`). Don't introduce a new ViewModel layer.

## See also

- [NativeTranscript2/CLAUDE.md](NativeTranscript2/CLAUDE.md) — the transcript renderer (layouts, diff, tool rendering).
- [Services/Session/CLAUDE.md](../../Services/Session/CLAUDE.md) — `Session` / `SessionRuntime` / `SessionDraft` internals and how state reaches the UI.

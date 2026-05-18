# Chat UI

How the chat pane is assembled. There is **no ViewModel** — `RootView2` is the only coordinator, and the three building blocks below don't know about each other.

| Component | Type | Instances | Responsibility |
|---|---|---|---|
| `RootView2` | View | 1 | Owns selection / draft `sessionId` locally; assembles sidebar + transcript + input bar |
| `SidebarView2` | View | 1 | Reads `SessionManager.records` to render the history list; writes back the selected `sessionId` via `@Binding` |
| `ChatHistoryView` | View | per-session (`.id(sessionId)`) | Acquires a `Session`, attaches `Transcript2EntryBridge`, kicks `loadHistory()`, renders `NativeTranscript2View`; mirrors `session.isRunning` into `Transcript2Controller.setLoading(_:)` so the trailing "running" pill row tracks the session |
| `InputBarView2` | View | per-session | Pure UI (text field + send/stop button); `onSubmit` / `onStop` / `isRunning` are injected. No longer hosts a running pill — the indicator lives inside the transcript |

## Ownership graph

```
AppState
├── sessionManager: SessionManager (env)
│   └── sessions: [String: Session]  (each toggles between .draft / .active phase internally)
└── syntaxEngine: SyntaxHighlightEngine (env)

RootView2
├── @State selectedSessionId, draftSessionId
└── @Environment SessionManager
    │
    ├── SidebarView2 (selection: $selectedSessionId)
    └── Detail:
        ├── ChatHistoryView(sessionId)
        │   ├── manager.prepareDraftSession(sessionId) → Session
        │   ├── Transcript2Controller + Transcript2EntryBridge.attach(session)
        │   ├── NativeTranscript2View(controller)
        │   └── .onChange(session.isRunning) → controller.setLoading(...)
        └── InputBarChrome
            └── InputBarView2 (onSubmit → session.send / onStop → session.interrupt)
```

## Data flow

- **History load** — `ChatHistoryView` mounts → `manager.prepareDraftSession(sessionId)` returns a `Session` → the view attaches a `Transcript2EntryBridge` → `session.loadHistory()` runs (no-op for `.draft` phase, dispatches Phase A/B for `.active`) → the bridge translates each `MessagesChange` into a `controller.loadInitial` / `controller.apply` call → `NativeTranscript2` diff-renders.
- **Running-state rendering** — `Session.isRunning` is `@Observable` (forwards to `runtime?.isRunning ?? false`). SwiftUI tracks it automatically: `InputBarView2` swaps send ↔ stop, and `ChatHistoryView`'s `.onChange(of: session.isRunning)` calls `Transcript2Controller.setLoading(_:)` which inserts / removes a `.loadingPill` row at the transcript's tail. The pill row is the controller's responsibility (not the bridge's) — the bridge stays focused on entry-driven content.
- **Incoming messages** — CLI pushes a message → `SessionRuntime.receive` updates `messages` and fires `onMessagesChange` → bridge → controller does an incremental reload. The `Session` façade re-wires `runtime.onMessagesChange` to its own subscriber closure at promotion, so the bridge attaches once and survives the phase flip.
- **Session switch** — `SidebarView2` writes a new value → `selectedSessionId` changes → the `.id(sid)` on `ChatHistoryView` forces a rebuild and resets its `@State`.
- **Draft → real session** — entering the New Session tab makes `RootView2` lazily allocate a `draftSessionId`. The user's first message triggers `session.draft?.setCwd(home)` / `setWorktree` / `setSourceBranch` then `session.send(text)`. `session.send` constructs a `SessionRuntime` via `SessionRuntime.fromDraft(...)`, copies the draft's config / title verbatim, queues the user input, wires bridge sinks, flips `phase = .active(runtime)`, kicks off bootstrap, and fires `onPromoted`. The manager's `refreshRecords()` hook is registered there, so the sidebar surfaces the new session immediately.

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

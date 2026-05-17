# Chat UI

How the chat pane is assembled. There is **no ViewModel** — `RootView2` is the only coordinator, and the three building blocks below don't know about each other.

| Component | Type | Instances | Responsibility |
|---|---|---|---|
| `RootView2` | View | 1 | Owns selection / draft `sessionId` locally; assembles sidebar + transcript + input bar |
| `SidebarView2` | View | 1 | Reads `SessionManager2.records` to render the history list; writes back the selected `sessionId` via `@Binding` |
| `ChatHistoryView` | View | per-session (`.id(sessionId)`) | Acquires a `SessionHandle2`, attaches `Transcript2EntryBridge`, kicks `loadHistory()`, renders `NativeTranscript2View`; mirrors `handle.isRunning` into `Transcript2Controller.setLoading(_:)` so the trailing "running" pill row tracks the session |
| `InputBarView2` | View | per-session | Pure UI (text field + send/stop button); `onSubmit` / `onStop` / `isRunning` are injected. No longer hosts a running pill — the indicator lives inside the transcript |

## Ownership graph

```
AppState
├── sessionManager2: SessionManager2 (env)
│   └── handles: [String: SessionHandle2]
└── syntaxEngine: SyntaxHighlightEngine (env)

RootView2
├── @State selectedSessionId, draftSessionId
└── @Environment SessionManager2
    │
    ├── SidebarView2 (selection: $selectedSessionId)
    └── Detail:
        ├── ChatHistoryView(sessionId)
        │   ├── manager.prepareDraft(sessionId) → SessionHandle2
        │   ├── Transcript2Controller + Transcript2EntryBridge.attach(handle)
        │   ├── NativeTranscript2View(controller)
        │   └── .onChange(handle.isRunning) → controller.setLoading(...)
        └── InputBarChrome
            └── InputBarView2 (onSubmit → handle.send / onStop → handle.interrupt)
```

## Data flow

- **History load** — `ChatHistoryView` mounts → `manager.prepareDraft(sessionId)` returns a handle → the view attaches a `Transcript2EntryBridge` → `handle.loadHistory()` runs → the bridge translates each `MessagesChange` into a `controller.loadInitial` / `controller.apply` call → `NativeTranscript2` diff-renders.
- **Running-state rendering** — `SessionHandle2.isRunning` is `@Observable`. SwiftUI tracks it automatically: `InputBarView2` swaps send ↔ stop, and `ChatHistoryView`'s `.onChange(of: handle.isRunning)` calls `Transcript2Controller.setLoading(_:)` which inserts / removes a `.loadingPill` row at the transcript's tail. The pill row is the controller's responsibility (not the bridge's) — the bridge stays focused on entry-driven content.
- **Incoming messages** — CLI pushes a message → `SessionHandle2.receive` updates `messages` and fires `onMessagesChange` → bridge → controller does an incremental reload.
- **Session switch** — `SidebarView2` writes a new value → `selectedSessionId` changes → the `.id(sid)` on `ChatHistoryView` forces a rebuild and resets its `@State`.
- **Draft → real session** — entering the New Session tab makes `RootView2` lazily allocate a `draftSessionId`. The user's first message triggers `handle.setCwd(home)` + `handle.send(text)`; once started, `manager.refreshRecords()` runs and selection switches to the real `sessionId`.

## Rules

- Views never mutate session running / status / message state directly. All writes go through `SessionHandle2` methods.
- The UI only reads `@Observable` properties on the handle; it never holds its own copy.
- A new piece of session runtime state means adding an `@Observable` field on `SessionHandle2` — views read it directly.
- Cross-view coordination uses closures injected from `RootView2` (e.g. `onSubmit`, `onBarRect` on `InputBarChrome`). Don't introduce a new ViewModel layer.

## See also

- [NativeTranscript2/CLAUDE.md](NativeTranscript2/CLAUDE.md) — the transcript renderer (layouts, diff, tool rendering).
- [Services/Session/CLAUDE.md](../../Services/Session/CLAUDE.md) — `SessionHandle2` internals and how state reaches the UI.

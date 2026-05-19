# Chat UI

How the chat pane is assembled. There is **no ViewModel** — `RootView2` is the only coordinator, and the four building blocks below don't know about each other.

| Component | Type | Instances | Responsibility |
|---|---|---|---|
| `RootView2` | View | 1 | Owns selection / draft `sessionId` locally; assembles sidebar + transcript swap host + input bar |
| `SidebarView2` | View | 1 | Reads `SessionManager.records` to render the history list; writes back the selected `sessionId` via `@Binding` |
| `TranscriptSwapHost` | View | 1 | Owns the live-retainer ZStack + image bake double-buffer + `.searchable` field. Sees `targetSessionId` change and runs `performSwap`: snapshot outgoing → mount/promote incoming → drop bake on `firstScreenReady` |
| `ChatHistoryView` | View | per-session (live: permanent; ephemeral: `.id`-keyed) | Acquires a `Session`, kicks `loadHistory()`, renders `NativeTranscript2View(controller: session.controller)`; mirrors `session.isRunning` into `Transcript2Controller.setLoading(_:)` so the trailing "running" pill row tracks the session. Does **not** own a controller or bridge — both live on `Session`. **Does not attach `.searchable`** — that lives on `TranscriptSwapHost` (one search field for the whole detail pane, routed to the visible session). |
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
        │   ├── session.controller.scrollToBottom() on mount
        │   └── .onChange(session.isRunning) → session.controller.setLoading(...)
        └── InputBarChrome
            └── InputBarView2 (onSubmit → session.send / onStop → session.interrupt)
```

## Data flow

- **History load** — `ChatHistoryView` mounts → `manager.prepareDraftSession(sessionId)` returns a `Session` (controller + bridge already exist and are wired to the runtime) → `session.loadHistory()` runs (`.notLoaded` dispatches Phase A/B; `.loadingTail` / `.tailLoaded` / `.loaded` are idempotent no-ops) → for cold loads, the bridge translates `MessagesChange` into `controller.loadInitial / apply` calls → `NativeTranscript2` diff-renders.
- **Session switch — the bake double-buffer** — `SidebarView2` writes a new `selectedSessionId` → `RootView2` derives `effectiveSessionId` → `TranscriptSwapHost.onChange(of: targetSessionId)` fires `performSwap`. In order:
  1. **Snapshot outgoing** — `Session.controller.attachedRootView` (the live `NSScrollView`) is rendered to a CGContext bitmap via `cacheDisplay(_:to:)`, wrapped in `NSImage`, and stored as `bakeImage`.
  2. **Retainer maintenance** — outgoing-if-still-`isLive` and incoming-if-`isLive` both `insertLive`'d into the retainer; sessions in the retainer whose `isLive` has fallen to false (and aren't the currently-visible one) are evicted by `pruneRetainerExceptVisible`. Eviction calls `session.resetTranscript()` to tear the controller blocks back to empty.
  3. **Outgoing ephemeral teardown** — if the outgoing session is not in the retainer, `resetTranscript()` runs now so the next entry cold-loads.
  4. **Visibility flip** — `visibleSessionId = target`. The ZStack re-renders: opacity 1 on the new session's `ChatHistoryView`, opacity 0 on the others. Bake sits on top, hiding the transition.
  5. **Ephemeral replay** — if the incoming session is ephemeral with `runtime.messages` already populated (history was loaded once, then torn down on previous swap), `replayMessagesAsReset()` synthesizes `bridge.apply(.reset(messages))` so the controller refills without re-reading disk.
  6. **Drop bake on ready** — a `Task` polls the incoming `controller.firstScreenReady`; once true, one `Task.sleep(16ms)` lets AppKit commit the new content's first paint, then `bakeImage = nil`. A bounded 1500 ms ceiling prevents the bake from pinning indefinitely on a stuck load. The `swapCounter` guard cancels stale drops when a faster switch supersedes.

  **Live retainer vs. ephemeral slot.** Both branches render through the same `ForEach(renderingOrder)` so identity is stable across an ephemeral → live promotion (draft → first send). `renderingOrder` is `liveOrder + [visibleEphemeralSid]`; SwiftUI's `id: \.self` preserves view (and underlying `NSTableView`) identity even when a session moves from the appended ephemeral slot into the persistent `liveOrder`.

  **First-screen-ready signal.** `Transcript2Controller.firstScreenReady` is the bake's release trigger. It flips synchronously when (a) `loadInitial`'s Phase 1 sync `apply` lands the viewport batch at its final scroll position, (b) `apply(_:)` lands a non-empty block list (covers the draft → first-send path where the user bubble arrives via incremental apply, not `loadInitial`), or (c) `loadInitial` is called with an empty payload (nothing to paint — ready immediately). Reset to false via `controller.resetFirstScreenReady()` during ephemeral teardown so the next entry's cold-load can re-arm.
- **Running-state rendering** — `Session.isRunning` is `@Observable` (forwards to `runtime?.isRunning ?? false`). SwiftUI tracks it automatically: `InputBarView2` swaps send ↔ stop, and `ChatHistoryView`'s `.onChange(of: session.isRunning)` calls `Transcript2Controller.setLoading(_:)` which inserts / removes a `.loadingPill` row at the transcript's tail. The pill row is the controller's responsibility (not the bridge's) — the bridge stays focused on entry-driven content.
- **Incoming messages** — CLI pushes a message → `SessionRuntime.receive` updates `messages` and fires `onMessagesChange` → `Session.wireRuntimeMessagesSink` closure dispatches first to `bridge.apply`, then to the optional `session.onMessagesChange` external observer. The bridge is wired once at `Session.init` and survives view mount/dismount — events flow into the controller continuously, even for live sessions the user is not currently viewing (the retainer keeps their views mounted).
- **Draft → real session** — entering the New Session tab makes `RootView2` lazily allocate a `draftSessionId`. The user's first message triggers `session.draft?.setCwd(home)` / `setWorktree` / `setSourceBranch` then `session.send(text)`. `session.send` constructs a `SessionRuntime` via `SessionRuntime.fromDraft(...)`, copies the draft's config / title verbatim, queues the user input, runs `wireRuntimeMessagesSink(runtime)` to install the bridge-then-external multiplex closure on the new runtime, flips `phase = .active(runtime)`, kicks off bootstrap, and fires `onPromoted`. The manager's `refreshRecords()` hook is registered there, so the sidebar surfaces the new session immediately. `TranscriptSwapHost` watches `visibleSessionIsLive` and `insertLive`s the promoted session into the retainer without remounting its `NSTableView` (same `id: \.self` slot).

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

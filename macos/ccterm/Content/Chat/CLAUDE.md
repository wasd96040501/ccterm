# Chat UI

How the chat pane is assembled. There is **no ViewModel** — `MainSplitViewController` + `ChatSessionViewController` (both AppKit) coordinate the pieces, and the three SwiftUI building blocks below don't know about each other.

| Component | Type | Instances | Responsibility |
|---|---|---|---|
| `MainWindowController` | NSWindowController | 1 | Owns the main NSWindow, NSToolbar (project chip + transcript search field). |
| `MainSplitViewController` | NSSplitViewController | 1 | Sidebar item (`SidebarViewController`) + detail item (`ChatSessionViewController`). |
| `MainSelectionModel` | `@Observable` | 1 | Shared selection / draft state — `selection: MainSelection` (typed: `.none` / `.newSession` / `.session(id)` / `.archive` / `.demo`), `draftSessionId`, attach + pill rects. Production writes go through `select(_:)`, which sets the `@Observable` value **and** synchronously notifies the structural owner (`selectionObserver` = the router) so the detail-side transition lands in the same source phase. SwiftUI consumers still observe `selection` for content re-render. |
| `SidebarViewController` | NSViewController (NSOutlineView, source-list) | 1 | Reads `SessionManager.records` to render the history list; writes back the selected `sessionId` directly on the model. Group ordering is sourced from `SidebarSessionGroupOrderStore` (UserDefaults) and updated on folder drag-and-drop. |
| `ChatSessionViewController` | NSViewController | 1 | Owns the `Transcript2ScrollView` directly via `TranscriptScrollViewFactory`; mounts AppKit `TranscriptScrimView` / `TranscriptBottomScrimView` for top/bottom fades (hitTest passthrough so the table below sees clicks + cursor rects), hosts the SwiftUI chat resting bar via `NSHostingView` (bottom-anchored to the bar's height — **always**, never full-bleed), and hosts the floating permission card via a separate full-pane `PassthroughHostingView` (`permissionCardHost`) layered on top — click-through everywhere outside the card, so the card never pumps the bar host's height and the transcript keeps its clicks. Does **not** observe `MainSelectionModel`; the router drives session attach (`loadHistory`, `setLoading`) imperatively via `present(sessionId:)`. Mounted only for `.session(_)` / `.none`. |
| `ComposeSessionViewController` | NSViewController | 1 | Full-pane VC for `.newSession` only. Hosts the SwiftUI compose card (`ComposeSessionView` → `NewSessionConfigurator` + `InputBarChrome`) via `NSHostingController` (`sizingOptions = []`). Lazy-allocates `MainSelectionModel.draftSessionId`; promotes the draft → real session on submit (shared `submitSessionInput`). Full-bleed with no transcript behind it, so it has none of the chat VC's bar-host hit-test gymnastics — the split is what fixed the "fast sidebar switch swallows transcript clicks" bug. |
| `InputBarView2` | View | per-session | Pure UI (text field + send/stop button); `onSubmit` / `onStop` / `isRunning` are injected. No longer hosts a running pill — the indicator lives inside the transcript. |
| `Transcript2SheetPresenter` | `@MainActor final class` | per-attach | Observes `Transcript2Controller.pendingUserBubbleSheet` / `pendingImagePreview` and opens AppKit-native sheets (`view.window?.beginSheet`) whose `contentViewController` is `NSHostingController(rootView: UserBubbleSheetView / ImagePreviewSheetView)`. Production VC reinstantiates it per session attach; demo VCs each own one for their lifetime. Replaces the deleted SwiftUI bridge's `.sheet(item:)` bindings. |

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
        ├── Sidebar item → SidebarViewController (NSOutlineView)
        └── Detail item → DetailRouterViewController   ← one child VC per selection
            ├── .session(_) / .none → ChatSessionViewController
            │   ├── transcriptScroll: Transcript2ScrollView (AppKit-native)
            │   │   └── session.controller drives blocks; isRunning → setLoading
            │   ├── topScrim: TranscriptScrimView (AppKit, hitTest passthrough)
            │   ├── bottomScrim: TranscriptBottomScrimView (AppKit, attach/pill cutouts)
            │   ├── composeOrBarHost: NSHostingView<AnyView>  (bottom-anchored, chat resting bar)
            │   └── permissionCardHost: PassthroughHostingView (full-pane, click-through, permission card overlay)
            ├── .newSession → ComposeSessionViewController
            │   └── NSHostingController<ComposeSessionView>  (full-bleed compose card)
            └── .archive → ArchiveViewController
```

## Data flow

- **History load** — `ChatSessionViewController.attachSession(_:)` runs (from `present(sessionId:)`) → `manager.prepareDraftSession(sessionId)` returns a `Session` (controller + bridge already exist and are wired to the runtime) → `session.loadHistory()` runs (`.notLoaded` starts the reverse-streaming `TranscriptBackfillPipeline`; `.loading` / `.loaded` are idempotent no-ops) → for cold loads, the pipeline builds blocks off-main and applies them straight to the controller (the tail page as `.append`, older pages as `.prepend`), bypassing the bridge → `NativeTranscript2` diff-renders. For re-entry, blocks are already in the controller from the continuous bridge — `TranscriptScrollViewFactory.make` builds an *unbound* scroll/clip/table shell; the host's `view.layoutSubtreeIfNeeded()` sizes the scroll view to its real width without driving any `heightOfRow` queries (no `dataSource` is wired yet); then `TranscriptScrollViewFactory.bindData` binds the table to the coordinator, and `controller.scrollToTail()`'s internal `tableView.layoutSubtreeIfNeeded()` is what fires the first (and only) row tile, at the final settled width. The deferred bind is what keeps each block from being typeset at 460pt / 720pt / 780pt in a single tick — guarded by `TranscriptReentryLayoutCacheTests` (factory direct) and `TranscriptHostReentryLayoutCacheTests` (real `ChatSessionViewController.present(sessionId:)` → `attachSession` end-to-end, plus the demo VC).
- **Running-state rendering** — `Session.isRunning` is `@Observable` (forwards to `runtime?.isRunning ?? false`). SwiftUI tracks it automatically for the input bar (send ↔ stop swap). For the trailing `.loadingPill` row, `ChatSessionViewController.startRunningObservation(for:)` listens via `withObservationTracking` and calls `Transcript2Controller.setLoading(_:)` on every flip. The pill row is the controller's responsibility (not the bridge's) — the bridge stays focused on entry-driven content.
- **Incoming messages** — CLI pushes a message → `SessionRuntime.receive` updates `messages` and fires `onMessagesChange` → `Session.wireRuntimeMessagesSink` closure dispatches first to `bridge.apply`, then to the optional `session.onMessagesChange` external observer. The bridge is wired once at `Session.init` and survives view mount/dismount — events flow into the controller continuously, even for sessions the user is not currently viewing.
- **Session switch** — `SidebarViewController` calls `model.select(.session(id))` → `MainSelectionModel.select(_:)` synchronously notifies its sole structural observer, `DetailRouterViewController.selectionDidChange(to:)` → `applySelection`. The router installs the correct child VC kind (swap only on a cross-kind change), runs `view.layoutSubtreeIfNeeded()` to settle the child's frame, then calls `ChatSessionViewController.present(sessionId:)`. `present` runs `attachSession` **synchronously in the same source phase as the click** — no async observation hop, no deferred-attach flush. `attachSession` builds the incoming `Transcript2ScrollView` via `TranscriptScrollViewFactory.make` (unbound shell), `addSubview`s it *in front of* the still-mounted outgoing scroll view, settles geometry with `layoutSubtreeIfNeeded`, `bindData`s the new `NSTableView` to `session.controller.coordinator`, `scrollToTail`s (the first tile, at the final width), then **dismantles the outgoing scroll view last** — all wrapped in `CATransaction.setDisableActions(true)` + `allowsImplicitAnimation = false`. Building the incoming transcript before dropping the outgoing one means the swap never flashes a blank pane (the previous teardown-then-build shape did). Warm re-entry picks up whatever block state accumulated while detached; the router defers only its *first* apply to the first framed `viewDidLayout`.
- **Draft → real session** — entering the New Session tab mounts `ComposeSessionViewController`, whose `viewDidLoad` lazily allocates a `draftSessionId` on `MainSelectionModel`. The user's first message (via the shared `submitSessionInput`) triggers `session.draft?.setCwd(home)` / `setWorktree` / `setSourceBranch` then `session.send(text)`, flips `selection` to `.session(_)` (which makes the router swap in `ChatSessionViewController`), and clears `draftSessionId`. `session.send` constructs a `SessionRuntime` via `SessionRuntime.fromDraft(...)`, copies the draft's config / title verbatim, queues the user input, runs `wireRuntimeMessagesSink(runtime)` to install the bridge-then-external multiplex closure on the new runtime, flips `phase = .active(runtime)`, kicks off bootstrap, and fires `onPromoted`. The manager's `refreshRecords()` hook is registered there, so the sidebar surfaces the new session immediately. Because `select(_:)` is **synchronous**, the swap-in of `ChatSessionViewController` tears `ComposeSessionViewController` (and its hosted `InputBarView2`) down in the **same source phase** as the send — SwiftUI never re-evaluates the bar's body afterward, so `InputBarView2.handleSend` clears the persisted draft **imperatively** (a direct `InputDraftStore.clear(draftKey)` before `onSubmit`) instead of relying on the reactive `.onChange(of: text) → scheduleDraftSave` clear, which the teardown would otherwise swallow.

## Rules

- Views never mutate session running / status / message state directly. All writes go through `Session` methods (which dispatch on phase under the hood).
- Draft-only setters (`setCwd` / `setWorktree` / `setOriginPath` / `setSourceBranch` / `setPluginDirectories`) are reached through `session.draft?` — non-nil only while the session is still in `.draft` phase. Calls after promotion are silently no-op (the `draft?` is nil).
- Runtime-mutable setters (`setModel` / `setEffort` / `setPermissionMode` / `setFastMode` / `setAdditionalDirectories`) are called as `session.setX(...)` regardless of phase; the façade routes to the draft or the runtime as appropriate.
- The UI only reads `@Observable` properties on the session; it never holds its own copy.
- A new piece of session runtime state means adding an `@Observable` field on `SessionRuntime` AND a forwarding accessor on `Session` — views read it via `session.X`.
- Cross-view coordination uses closures injected from `ChatSessionViewController` (e.g. `onSubmit`, `onAttachRect` / `onPillRect` on `InputBarChrome`). Don't introduce a new ViewModel layer.

## See also

- [NativeTranscript2/CLAUDE.md](NativeTranscript2/CLAUDE.md) — the transcript renderer (layouts, diff, tool rendering).
- [Services/Session/CLAUDE.md](../../Services/Session/CLAUDE.md) — `Session` / `SessionRuntime` / `SessionDraft` internals and how state reaches the UI.

# Chat UI

How the chat pane is assembled. There is **no ViewModel**: AppKit VCs coordinate the pieces. `DetailRouterViewController` routes (one child VC per selection), `TranscriptSwapCoordinator` owns the transcript swap, and `ChatSessionViewController` owns *what the pane shows* (scrims, resting bar, permission card). The hosted SwiftUI building blocks don't know about each other. Every detail child gets its dependencies as one `DetailContext` (`App/AppKit/DetailContext.swift`: `model` + `sessionManager` / `recentProjects` / `inputDraftStore` / `syntaxEngine`); `injectDetailEnvironment(_:)` puts the four services (not `model`) into the SwiftUI environment.

| Component | Type | Responsibility |
|---|---|---|
| `MainWindowController` | NSWindowController | The main window and its `NSToolbar` (project chip + transcript `NSSearchToolbarItem`). |
| `MainSplitViewController` | NSSplitViewController | Sidebar item + detail item; `init` builds a `SidebarContext` and a `DetailContext`. |
| `MainSelectionModel` | `@Observable` | `selection: MainSelection` (`.none` / `.newSession` / `.session(id)` / `.archive` / `.demo`), `draftSessionId`, attach + pill rects. Writes go through `select(_:)`, which updates the value **and synchronously** notifies its one structural observer (the router), so the detail transition lands in the same source phase as the click. |
| `SidebarViewController` | NSViewController | See [Sidebar/CLAUDE.md](../../Sidebar/CLAUDE.md). |
| `DetailRouterViewController` | NSViewController | Sole structural observer of `MainSelectionModel`. Mounts one `DetailRouterChild` per selection (swaps only on a cross-kind change; crossfades only for "fresh content"), settles the child's frame, then calls its `present(sessionId:)` in the same source phase. Routes `.session`/`.none` → `ChatSessionViewController`, draft `.session` → `DraftSessionLandingViewController`, `.newSession` → `ComposeSessionViewController`, `.archive` → `ArchiveViewController`, `.demo` → demo VCs (DEBUG). Owns window-lifetime app→detail signals (`NotificationService.onActivateSession`, launch-failure alert). Defers only its *first* apply to the first framed `viewDidLayout`. |
| `ChatSessionViewController` | `DetailRouterChild` | Owns what the pane shows: AppKit `TranscriptTopScrimView` / `TranscriptBottomScrimView` (hitTest passthrough), the SwiftUI resting bar in `restingBarHost`, and the permission card in `permissionCardHost`. Lazily builds `TranscriptSwapCoordinator` on first `present` and delegates attach to it. Does **not** observe `MainSelectionModel`. |
| `TranscriptSwapCoordinator` | `@MainActor final class`, per chat VC | The swap state machine and the **single owner** of `currentSession`. Builds / binds / anchors / crossfades / tears down the `Transcript2ScrollView`, and re-creates the per-attach `Transcript2SheetPresenter` + turn-usage + `isRunning` sinks. |
| `DraftSessionLandingViewController` | `DetailRouterChild` | Full-pane landing for a `.session` still in `.draft` phase (`/new`, `/clear`). Mounted via `mountFillPaneHost`. On first send the session promotes and the router swaps in `ChatSessionViewController`. |
| `ComposeSessionViewController` | NSViewController | `.newSession` only. Hosts `ComposeSessionView` (`NewSessionConfigurator` + `InputBarChrome`) full-bleed via `mountFillPaneHost`; lazily allocates `draftSessionId`; promotes on submit via `submitSessionInput`. Kept separate from the chat VC so it carries none of the bar-host hit-test rules. |
| `PermissionCardOverlay` | SwiftUI | Reads `session.pendingPermissions.first`; hosted in `permissionCardHost`. |
| `InputBarView2` | SwiftUI | Text field + send/stop; `onSubmit` / `onStop` / `isRunning` injected. The running indicator lives in the transcript, not here. |
| `Transcript2SheetPresenter` | `@MainActor final class`, per attach | Observes `Transcript2Controller.pendingUserBubbleSheet` / `pendingImagePreview`; opens AppKit sheets hosting `UserBubbleSheetView` / `ImagePreviewSheetView`. |

## Ownership graph

```
AppDelegate
├── appState: AppState
│   ├── sessionManager: SessionManager
│   │   └── sessions: [String: Session]   (phase .draft/.active, controller, bridge)
│   └── syntaxEngine: SyntaxHighlightEngine
├── searchBus: TranscriptSearchBus
├── selectionModel: MainSelectionModel
└── mainWindowController: MainWindowController
    ├── NSToolbar (project chip + transcript search field)
    └── MainSplitViewController
        ├── Sidebar → SidebarViewController
        └── Detail  → DetailRouterViewController
            ├── .session / .none   → ChatSessionViewController
            │   ├── swapCoordinator: TranscriptSwapCoordinator
            │   │   └── Transcript2ScrollView + per-attach sheet presenter / sinks
            │   ├── topScrim, bottomScrim          (AppKit, hitTest passthrough)
            │   ├── restingBarHost                 (NSHostingView, regime B)
            │   └── permissionCardHost             (PassthroughHostingView, regime A)
            ├── .session (draft)   → DraftSessionLandingViewController
            ├── .newSession        → ComposeSessionViewController
            └── .archive           → ArchiveViewController
```

## Data flow

- **Session switch** — sidebar click → `model.select(.session(id))` → router `selectionDidChange(to:)` → install child → `view.layoutSubtreeIfNeeded()` → `ChatSessionViewController.present(sessionId:)` → `TranscriptSwapCoordinator.attachSession`, all **synchronously in the click's source phase** (no observation hop). Attach follows the transcript's deferred-bind contract — build an unbound shell, settle layout, `bindData`, `scrollToTail` — see [NativeTranscript2 §2.19](NativeTranscript2/CLAUDE.md).
- **History load** — `attachSession` → `manager.prepareDraftSession(id)` → `session.loadHistory()` (`.notLoaded` starts `TranscriptBackfillPipeline`; `.loading` / `.loaded` are no-ops). A cold load applies blocks straight to the controller, bypassing the bridge. Warm re-entry finds blocks already there, because the bridge runs for every session whether or not it is mounted.
- **Incoming messages** — `SessionRuntime.receive` → `onMessagesChange` → `bridge.apply` → controller. Wired once at `Session.init`; see [Services/Session/CLAUDE.md](../../Services/Session/CLAUDE.md).
- **Running state** — `Session.isRunning` is `@Observable`. The input bar tracks it directly; the transcript's `.loadingPill` row is driven by `TranscriptSwapCoordinator.startRunningObservation(for:)` (re-armed per attach) calling `Transcript2Controller.setLoading(_:)`. The pill is the controller's job, not the bridge's.
- **Draft → real session** — `ComposeSessionViewController` allocates `draftSessionId`; first submit sets draft config (`session.draft?.setCwd` / `setWorktree` / `setSourceBranch`), calls `session.send(text)` (promotes to `.active`, see the Session doc), selects `.session(_)` and clears `draftSessionId`. Because `select(_:)` is synchronous, the compose VC and its `InputBarView2` are torn down in the same source phase as the send — so `InputBarView2.handleSend` clears the persisted draft **imperatively** (`InputDraftStore.clear(draftKey)` before `onSubmit`); a reactive `.onChange` clear would never run.

## Transcript swap ordering

`TranscriptSwapCoordinator` alone holds `currentSession` (idempotent short-circuit, outgoing capture, assignment, clear). The VC must never hold it too: a crossfade reads the parked outgoing session while the incoming one is bound, and a second owner desyncs them.

- **Flush the parked outgoing scroll before building the incoming one.** `attachSession` calls `finishTranscriptFadeOut()` first. `TranscriptScrollViewFactory.dismantle` does a blanket `removeObserver(coordinator)`; on A→B→A the outgoing and incoming scroll share a coordinator, so a deferred teardown would strip the fresh scroll's observers. A→B→C collapses the same way.
- **Build in front, drop last, inside one disabled transaction.** Insert the incoming scroll `.below topScrim` (above the outgoing one), make it live (typeset, bound, at tail), then dismantle the outgoing one — never the reverse, or the pane flashes blank. Wrap in `CATransaction.setDisableActions(true)` + `allowsImplicitAnimation = false`.
- **The crossfade is opacity-only, outside that transaction**, and runs only for the router's "fresh content" entry with a live window. Headless and warm re-entry stay synchronous.

## SwiftUI hosts: two sizing regimes

Every SwiftUI view in the detail pane sits in an AppKit host, and each host is one of two shapes. Choosing the wrong one either collapses the window or swallows transcript clicks.

| | Regime A — fills a pane | Regime B — subordinate component |
|---|---|---|
| Examples | Compose, draft landing, archive (`mountFillPaneHost`), `permissionCardHost` | `restingBarHost` |
| `sizingOptions` | `[]` | `[.intrinsicContentSize]` |
| Constraints | four-edge pin — the container sizes the host | position + width only (centerX, bottom, width cap `BlockStyle.maxLayoutWidth + 2 * detailHorizontalInset` @high, `leading >=`) — the content sizes its height |
| Why | Default options publish the body's small `fittingSize`, which leaks up the split into the window's solver and collapses the window | The host must be only as tall as the bar so the transcript above keeps its clicks |

- **Use `mountFillPaneHost`** (`App/AppKit/MountFillPaneHost.swift`) for any new fill-pane child — it is the one copy of the regime-A recipe (`NSHostingController`, `sizingOptions = []`, `addChild`, four-edge pin).
- **A full-pane host over the transcript must be a `PassthroughHostingView`.** `hitTest → nil` alone isn't enough: a plain `NSHostingView` registers an arrow cursor rect over its whole bounds, hiding the transcript's I-beam even when clicks pass through. `PassthroughHostingView` no-ops `resetCursorRects()` and maps its transparent background to `nil` in `hitTest`.
- **Z-order in `ChatSessionViewController.loadView`:** `permissionCardHost` is added after `restingBarHost`, so it floats on top; the transcript scroll is re-inserted `.below topScrim` on every attach. The card sits at `chatBottomInset` (36) inside its own full-pane host, so it never changes the bar host's height — `ChatRestingBar` is just the bar.

Merge gates (run on CI): `AppKitSwiftUIBoundaryTests` (regime-A no-collapse, A/B over `sizingOptions`), `HostedComponentCenteringTests` (regime-B centering, width cap, shrink-to-fit, bottom anchor), `DetailRouterLayoutDiagnosticsTests` (archive through the real router). When adding one:

- Assert regime-A on the child's published `fittingSize.height ≈ 0`. An off-screen window runs no live autosize pass, so its **frame** never collapses and a window-height assertion proves nothing.
- Mount in a large window (≥ ~1100×760, `minSize` strictly between the collapse target and the window height) so a partial collapse can't hide under the min clamp.
- Demonstrate the bad regime with a test-local throwaway host; never change a production VC's `sizingOptions` from a test.

## Rules

- Views never mutate session state directly; all writes go through `Session` methods.
- Draft-only setters (`setCwd` / `setWorktree` / `setOriginPath` / `setSourceBranch` / `setPluginDirectories`) are reached via `session.draft?` and are no-ops after promotion. Runtime-mutable setters (`setModel` / `setEffort` / `setPermissionMode` / `setFastMode` / `setAdditionalDirectories`) are `session.setX(...)` in any phase.
- The UI reads `@Observable` session properties and keeps no copies. New runtime state = an `@Observable` field on `SessionRuntime` + a forwarder on `Session`.
- Cross-view coordination uses closures injected from `ChatSessionViewController` (`onSubmit`, `onAttachRect` / `onPillRect` on `InputBarChrome`). Don't add a ViewModel layer.

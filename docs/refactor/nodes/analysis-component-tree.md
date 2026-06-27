# Analysis: Whole-app component tree (as-is) + AppKit↔SwiftUI boundary map

Cross-cutting synthesis of all 12 subsystem surveys, verified against source.
This is the authoritative component tree for the refactor. Source root abbreviated
`…` = `macos/ccterm`. FACT = read in code (cited file:line). INFERENCE = my read.

---

## Executive summary

CCTerm is an **AppKit-rooted shell with SwiftUI leaves**. The spine — app
lifecycle, main window, split, sidebar, detail routing, transcript — is AppKit by
deliberate exception (each justified in the root CLAUDE.md). SwiftUI appears only
where it is hosted, via `NSHostingController` (full-pane children + aux windows) or
`NSHostingView` (toolbar items, the bottom-anchored chat bar, demo overlays).

The architecture is **already substantially unidirectional and well-layered**.
The two genuine data-flow spines are clean:

1. **Selection spine** — `MainSelectionModel.select(_:)` writes the `@Observable`
   `selection` AND synchronously notifies one structural observer (the router).
   The router is the *sole* structural owner; everything downstream is imperative
   `present(sessionId:)` or reactive `@Observable` reads. One deliberate upward
   edge (`selectionObserver`), heavily justified.
2. **Session/render spine** — `Session` (façade) owns `Transcript2Controller` +
   `Transcript2EntryBridge` for its whole lifetime; runtime state reaches SwiftUI
   via `@Observable` pull and reaches the AppKit transcript via synchronous closure
   push. "Pick one channel per piece of state" is enforced by convention and holds.

The structural problems are therefore **not** "the data flow is tangled" — it is
mostly clean. They cluster into five shapes:

- **A. Dependency-injection boilerplate** — the same 6–7 services are re-declared,
  re-threaded, and re-`.environment()`-injected across 5 detail VCs + the router,
  including **two dead injections** (`notifications`, `searchBus`) no SwiftUI view
  reads. This is the single highest-value, lowest-risk cleanup. (P1/P2)
- **B. God-objects with mixed concerns** — `SidebarViewController` (~770 lines, 7
  concerns), `ChatSessionViewController` (~680, "what to show" + "how to swap a
  transcript"), `Transcript2Coordinator` (~1764), `SessionRuntime` (~3000 across 9
  files). All are *internally cohesive* but mix independently-testable clusters.
- **C. Boundary/naming drift** — `composeOrBarHost` (no longer morphs),
  `searchEngine` param that is actually the syntax highlighter, `AnyView` erasure
  at both bar host seams, doc comments describing deleted designs (`.searchable`,
  `RootView2`, `AppState` `.environment`).
- **D. Duplicated derivation logic** — grouping/tool-pairing implemented twice
  (live `receive` vs cold `ReverseEntryBuilder`), crossfade state machine twice
  (router cross-kind vs chat same-session), `StableBlockID` id-coordinate scheme
  replicated across 3 files, status-color/title derived 2–3× in task surfaces.
- **E. Ownership-pattern inconsistency** — 5 services on `AppState`, 3 as `.shared`
  singletons, 2 owned by `AppDelegate` not `AppState`; 2 completion stores as
  process singletons reached from inside closures; `CompletionViewModel` the lone
  ViewModel in a "no ViewModel" area (justified, but mis-named).

One genuine **single unidirectional-flow violation** in production UI:
`BackgroundTaskButton` reaches `session.runtime.markTaskStoppedLocally(...)`
directly, bypassing the `Session` façade (P4).

The card-over-bar geometry coupling (card size → host intrinsic height → animated
band growth) is a real structural coupling and the user's reported "喧宾夺主"
complaint, but it is **out of scope for the tree** and covered by
`survey-permission-cards.md` §6/§7.

---

## 1. The authoritative component tree

Legend:
`[AK]` AppKit (`NSWindowController`/`NSViewController`/`NSView`/`NSObject`) ·
`[SU]` SwiftUI `View` · `[SVC]` `@Observable`/actor service · `[VM]` ViewModel ·
`[MDL]` plain value/model · `«HC»` `NSHostingController` · `«HV»` `NSHostingView`.
Hosting bridges note `sizingOptions` + the reason (verified: §2 below).

```
CCTermApp  [SU App, @main]  ......................................... …/App/CCTermApp.swift:21
├── @NSApplicationDelegateAdaptor → AppDelegate  [AK]  .............. …/App/AppKit/AppDelegate.swift:29
└── Scene: Settings { EmptyView() }  [SU placeholder scene]  ....... …/App/CCTermApp.swift:39
    └── .commands { AppCommands }  [SU Commands]  .................. …/App/CCTermApp.swift:139
          (About / Settings ⌘, / Find ⌘F → AppDelegate.show*Window / searchBus.requestFocus;
           menu items only — no window. The placeholder scene exists so ⌘, never opens a
           SwiftUI Settings window — invariant I9, app-shell survey.)

AppDelegate  [AK]  (app-scope owner; creates main window in applicationDidFinishLaunching)
│   ── owns app-scope state (constructor-injected downward, never reassembled) ──
├── appState: AppState  [SVC, @Observable]  ........................ …/App/AppState.swift:6
│   ├── sessionManager: SessionManager  [SVC]  .................... …/Services/Session/SessionManager.swift:15
│   │     └── sessions: [String: Session]  [SVC, @Observable]  .... …/Services/Session/Session/Session.swift:44
│   │           ├── phase: .draft(SessionDraft) | .active(SessionRuntime)  [SVC]
│   │           ├── controller: Transcript2Controller  [SVC] ← render-side, SESSION-LIFETIME
│   │           │     └── coordinator: Transcript2Coordinator  [AK, NSObject]
│   │           │           ├── selection: Transcript2SelectionCoordinator  [AK]
│   │           │           ├── search:    Transcript2SearchCoordinator     [AK]
│   │           │           └── highlightStorage: Transcript2HighlightStorage
│   │           ├── bridge: Transcript2EntryBridge  [translator] ← ALWAYS WIRED to runtime
│   │           └── backfillPipeline: TranscriptBackfillPipeline? ← alive only during one cold load
│   │                 └── (off-main producer → PipelineInbox → main drain → controller, BYPASSES bridge)
│   ├── syntaxEngine: SyntaxHighlightEngine  [SVC, actor]  ......... …/Services/SyntaxHighlightEngine.swift:4
│   ├── recentProjects: RecentProjectsStore  [SVC, lazy]  ......... …/Services/RecentProjectsStore.swift:30
│   ├── inputDraftStore: InputDraftStore  [SVC]  .................. …/Services/Draft/InputDraftStore.swift:12
│   ├── sidebarGroupOrder: SidebarSessionGroupOrderStore  [SVC, NOT @Observable]
│   ├── activationTracker: AppActivationTracker  [SVC] ─┐ (private dep of ↓; no other reader)
│   ├── notificationService: NotificationService  [SVC]◀┘
│   └── openInService: OpenInAppService  [SVC]
├── searchBus: TranscriptSearchBus  [SVC, @Observable]  ← owned HERE, not on AppState
├── selectionModel: MainSelectionModel  [SVC, @Observable]  ← owned HERE, not on AppState
├── settingsWindowController?: SettingsWindowController  [AK, lazy]
│     └── window.contentVC = «HC» SettingsView  [SU]   (default sizingOptions → sizes window)
├── aboutWindowController?: AboutWindowController  [AK, lazy]
│     └── window.contentVC = «HC» AboutView  [SU]      (default sizingOptions → sizes window)
└── mainWindowController?: MainWindowController  [AK]  ............. …/App/AppKit/MainWindowController.swift:10
    ├── NSToolbar (delegate = self)
    │   ├── .toggleSidebar / .sidebarTrackingSeparator  (system items)
    │   ├── projectChip item → «HV» TranscriptProjectChip  [SU]   sizingOptions=[.intrinsicContentSize]  (:253)
    │   ├── archiveFilter item → «HV» ArchiveFilterToolbarButton [SU] sizingOptions=[.intrinsicContentSize] (:280)
    │   └── search item → NSSearchToolbarItem  [AK]  (:257)
    │         └── searchField.delegate/target = TranscriptSearchToolbarBridge  [AK]  (:403)
    │               (controllerProvider PULLS live session's Transcript2Controller per keystroke)
    └── window.contentVC = MainSplitViewController  [AK]  .......... …/App/AppKit/MainSplitViewController.swift:10
        │   (destructures appState into individual services; passes a 7-bag to the router,
        │    a 4-bag to the sidebar — DI fan-out point)
        ├── sidebar item → SidebarViewController  [AK, NSOutlineView source-list]  … /Sidebar/SidebarViewController.swift:33
        │     │   (100% AppKit; NO hosting boundary; god-VC — 7 concerns)
        │     └── scrollView → NoDisclosureOutlineView  [AK]
        │           └── rows (identity-keyed on SidebarItemNode, reference type):
        │               ├── .fixed   → SidebarFixedCellView   [AK]  (icon + title)
        │               ├── .folder  → SidebarFolderCellView  [AK]  (icon + title + chevron)
        │               └── .history → SidebarHistoryCellView [AK]
        │                     ├── SidebarStatusIndicatorView [AK] (dots / unread; precedence unread>running)
        │                     └── title + ShimmerOverlay (CAGradientLayer mask, lazy)
        │
        └── detail item → DetailRouterViewController  [AK, MainSelectionObserver]  … /App/AppKit/DetailRouterViewController.swift:63
            │   view = NSVisualEffectView(.contentBackground)
            │   currentChild = exactly ONE of the below (+ optional fadingOutChild mid-crossfade)
            │   ChildKind: .transcript | .compose | .draftLanding | .archive | .demo(DEBUG)  (:211)
            │
            ├── .transcript → ChatSessionViewController  [AK, DetailRouterChild]  ← .session(active) / .none
            │     │   view = plain NSView (pinned 4-edge by router); driven imperatively via present()
            │     │   (god-VC: "what to show" + transcript-swap state machine)
            │     ├── transcriptScroll: Transcript2ScrollView  [AK]   (per-attach; pinned 4-edge; FIXED contentInsets)
            │     │     └── Transcript2ClipView → Transcript2TableView → BlockCellView (self-drawn) [all AK]
            │     │           └── leaf SwiftUI ONLY at: LoadingPillUsageView (token counter)
            │     ├── topScrim: TranscriptTopScrimView  [AK]  (INTERCEPTS mouse → title-bar drag/zoom)
            │     ├── bottomScrim: TranscriptBottomScrimView [AK] (hitTest passthrough; attach/pill cutouts)
            │     ├── transcriptSheetPresenter: Transcript2SheetPresenter [AK] (per-attach)
            │     │     └── on demand: NSWindow.beginSheet( «HC» UserBubbleSheetView | ImagePreviewSheetView [SU] )
            │     └── composeOrBarHost: «HV» AnyView  [SU]   sizingOptions=[.intrinsicContentSize]
            │           │  centerX + bottom-anchored, width-capped, NO height constraint (component)
            │           │  ⚠ name stale (no longer "compose OR bar"; only ever the bar), ⚠ AnyView erasure
            │           └── ChatComposeStack  [SU]  (routes model.selection → bar | EmptyView)
            │                 └── ChatRestingBar .id(sid)  [SU]   (only for .session(_))
            │                       └── ZStack(alignment:.bottom)   ⚠ reports UNION height (card-coupling)
            │                             ├── InputBarChrome  [SU]
            │                             │     └── VStack
            │                             │           ├── InputBarView2  [SU]  (handle-free leaf; @State CompletionVM)
            │                             │           │     ├── AttachButton  [SU]  (ReportFrame→onAttachRect)
            │                             │           │     └── pill (ReportFrame→onPillRect)
            │                             │           │           ├── CompletionListView?  [SU]  ← @Bindable CompletionViewModel [VM]
            │                             │           │           ├── thumbnailStrip?
            │                             │           │           └── textArea → TextInputView  [SU→AK NSTextView]
            │                             │           └── InputBarSessionChrome  [SU]
            │                             │                 ├── PermissionModePicker  [SU] (popover)
            │                             │                 ├── BackgroundTaskButton  [SU] (popover + .sheet)
            │                             │                 │     └── .sheet → BackgroundTaskDetailSheet [SU]
            │                             │                 │           └── owns BackgroundTaskOutputStream [SVC]
            │                             │                 ├── TodoButton  [SU] (popover → TodoList)
            │                             │                 ├── ModelEffortPicker  [SU] (popover; ModelStore.shared)
            │                             │                 └── ContextRingButton  [SU] (popover)
            │                             └── PermissionCardView?  [SU]  (only when pending; per-kind body dispatch)
            │
            ├── .compose → ComposeSessionViewController  [AK]  ← .newSession
            │     └── «HC» AnyView  [SU]  sizingOptions=[]  (fill-pane, 4-edge pin)   ⚠ AnyView erasure
            │           └── ComposeSessionView  [SU]
            │                 └── ZStack(DotGridBackground, NewSessionConfigurator{ inputBar: InputBarChrome })
            │                       └── (@State probe: GitProbe [SVC, view-scope] → BranchPickerView)
            │                       └── InputBarChrome → InputBarView2 → (same subtree as above)
            │
            ├── .draftLanding → DraftSessionLandingViewController  [AK, DetailRouterChild]  ← .session whose Session is .draft
            │     └── «HC» AnyView  [SU]  sizingOptions=[]  (re-mounted on draft→draft rebind)
            │           └── DraftSessionLandingView  [SU]
            │                 └── ZStack(DotGridBackground, VStack(hero, path, branchPill, InputBarChrome))
            │
            ├── .archive → ArchiveViewController  [AK]  ← .archive
            │     └── «HC» AnyView  [SU]  sizingOptions=[]  (fill-pane, 4-edge pin)   ⚠ AnyView erasure
            │           └── ArchiveView  [SU]  (selectedFolderPath: Binding↔model.archiveSelectedFolderPath)
            │
            └── .demo(_) (DEBUG) → demo VCs  [AK]
                  TranscriptDemoVC / …Stress / …Perf (each owns its own Controller+scroll+presenter),
                  PermissionSessionDemoVC, and a «HC» PermissionCardsDemoView [SU] sizingOptions=[]

Global singletons (NO tree edge; reached via .shared from views/runtime):
  ModelStore.shared  ·  EffortDefaultStore.shared  ·  NewSessionDefaultsStore.shared
  FileCompletionStore.shared  ·  SlashCommandStore.shared

Data-feed siblings (not in the view tree, but feed it):
  Transcript2EntryBridge  ← live MessagesChange channel (per Session)
  TranscriptBackfillPipeline  ← cold JSONL channel (per load)
  MarkdownDocument/Convert  ← pure value IR, consumed only by MessageEntryBlockBuilder
```

---

## 2. AppKit↔SwiftUI boundary map (every hosting bridge)

Verified by `grep sizingOptions` + each construction site. Two regimes, per the
root CLAUDE.md "host sizing" rule (invariant I8 / card-I2).

| # | Host | Kind | sizingOptions | Regime | Why | file:line |
|---|---|---|---|---|---|---|
| 1 | Settings window content | «HC» SettingsView | default | window-sizing | host sizes the aux window | …/App/AppKit/SettingsWindowController.swift:15 |
| 2 | About window content | «HC» AboutView | default | window-sizing | host sizes the aux window | …/App/AppKit/AboutWindowController.swift:23 |
| 3 | Toolbar project chip | «HV» TranscriptProjectChip | `[.intrinsicContentSize]` | component | toolbar slot sized by content | …/App/AppKit/MainWindowController.swift:253 |
| 4 | Toolbar archive filter | «HV» ArchiveFilterToolbarButton | `[.intrinsicContentSize]` | component | toolbar slot sized by content | …/App/AppKit/MainWindowController.swift:280 |
| 5 | Chat bottom bar | «HV» AnyView(ChatComposeStack) | `[.intrinsicContentSize]` | component | bottom-anchored over a transcript that already fills the pane; content drives HEIGHT | …/App/AppKit/ChatSessionViewController.swift:169 |
| 6 | Compose pane | «HC» AnyView(ComposeSessionView) | `[]` | fill-pane | IS the pane; container drives size | …/Content/Chat/ComposeSessionViewController.swift:115 |
| 7 | Draft-landing pane | «HC» AnyView(DraftSessionLandingView) | `[]` | fill-pane | IS the pane; container drives size | …/Content/Chat/DraftSessionLandingViewController.swift:136 |
| 8 | Archive pane | «HC» AnyView(ArchiveView) | `[]` | fill-pane | IS the pane (the `545×276` leak comment is here) | …/Content/Archive/ArchiveViewController.swift:102 |
| 9 | Demo permission-cards | «HC» PermissionCardsDemoView | `[]` | fill-pane | DEBUG, IS the pane | …/App/AppKit/DetailRouterViewController.swift:443 |
| 10 | Transcript sheets | «HC» UserBubble/ImagePreviewSheetView | (modal) | beginSheet | AppKit-native sheet wrapping SwiftUI body | …/…/Transcript2SheetPresenter.swift |
| 11 | Demo control panels | «HV» (various) | default | component | DEBUG overlays | …/Content/TranscriptDemo/* |

**Boundary asymmetry (FACT, flagged in 2 surveys):** the chat bar is the *only*
production pane host using a bare `«HV»` + `[.intrinsicContentSize]`; all four
full-pane children use `«HC»` + `[]`. This is correct and structural (component vs
fill-pane), not stylistic — but it is the one place a reader must understand both
regimes. The `AnyView` erasure at hosts 5/6/7/8 (and #9) is incidental, not
load-bearing (single concrete body each) — un-erasing would make the dependency
explicit and let the compiler enforce environment injection (P12).

**SwiftUI deepest reach (where AK ends):** inside the transcript subtree, AppKit
goes all the way to the self-drawn `BlockCellView`; SwiftUI appears only at two
leaves (sheet bodies via `beginSheet`, and the loading-pill token counter). The
transcript is the most AppKit-pure region and the §2 perf contract pins it.

---

## 3. Layer & ownership model (who constructs / owns / how long)

| Layer | Members | Constructed by | Lifetime |
|---|---|---|---|
| **App lifecycle** | `AppDelegate` | SwiftUI runtime (`@NSApplicationDelegateAdaptor`) | process |
| **App-scope state** | `AppState`, `searchBus`, `selectionModel` | `AppDelegate` stored-prop init | process |
| **App-scope services** | 8 on AppState + 3 `.shared` singletons | `AppState.init` / lazy static | process |
| **Window shell** | `MainWindowController` → `MainSplitViewController` → `SidebarVC` + `DetailRouterVC` | `applicationDidFinishLaunching` → init chain | window (= process here, single window) |
| **Detail children** | Chat / Compose / DraftLanding / Archive / demo VCs | `DetailRouterViewController.makeChild` (`:363`) | one alive at a time; cross-kind swap tears down + rebuilds; same-kind REUSES |
| **Per-attach (chat)** | `transcriptScroll`, `transcriptSheetPresenter`, running-obs task | `ChatSessionViewController.attachSession` | re-created every session switch |
| **Session core** | `Session` + `controller` + `bridge` | `SessionManager.makeSession` (lazy, cached by id) | session lifetime (survives mount/dismount) |
| **Per-load** | `TranscriptBackfillPipeline` | `Session.loadHistory()` | one cold load |
| **SwiftUI value views** | all `[SU]` nodes | SwiftUI `body` re-eval | per render; reset across sessions by `.id(sid)` |
| **View-scope state** | `CompletionViewModel`, `GitProbe`, `BackgroundTaskOutputStream` | SwiftUI `@State` | view identity |

**The single deliberate upward edge:** `MainSelectionModel.selectionObserver`
(weak) — the router registers itself on the model it is handed. This makes the
"synchronous structural notification" possible. It is the *only* bidirectional link
in an otherwise-downward graph and must be understood (not removed) by a refactor.

**DI fan-out point:** `MainSplitViewController.init` destructures `appState` into
individual services and threads a **7-bag** into the router (which forwards it to
all 4 children) and a **4-bag** into the sidebar. `AppState` is never injected as a
whole; no `.environment(appState)` exists anywhere (FACT — contradicts a root
CLAUDE.md sentence, see P11).

---

## 4. Ranked problems list

Severity reflects risk to / leverage for a **clean unidirectional refactor with no
functional degradation**, not user-facing bugs. Each cites the load-bearing
invariant a fix must not break.

### HIGH

**P1 — Dead SwiftUI-environment injections of `notifications` + `searchBus`.**
Root cause: every detail VC's hosting boundary injects `.environment(notifications)`
and `.environment(searchBus)`, but **no SwiftUI view reads either type** (grep:
`NotificationService.self` → 0, `TranscriptSearchBus.self`/`@Environment(TranscriptSearchBus`
→ 0). Both flow only through AppKit channels (`onActivateSession` push;
`withObservationTracking` toolbar bridge). They imply a dependency edge that does
not exist — an env-driven refactor would chase a phantom.
Location: `…/App/AppKit/DetailRouterViewController.swift:434-435` (+demo `:435`),
`…/App/AppKit/ChatSessionViewController.swift:580-581`,
`…/Content/Chat/ComposeSessionViewController.swift:104-105`,
`…/Content/Archive/ArchiveViewController.swift:79-80`,
`…/Content/Chat/DraftSessionLandingViewController.swift:127-128`.
Fix: delete the two dead injections; the actually-consumed env set is exactly
`SessionManager`, `RecentProjectsStore`, `InputDraftStore`, `\.syntaxEngine`.

**P2 — 7-arg dependency bundle re-declared across the router + 5 child VCs, and the
6-line `.environment(...)` block copy-pasted 5×.** Root cause: `AppState` is
destructured then re-passed; each child VC declares the identical 7 stored props +
identical `init(model:sessionManager:recentProjects:notifications:searchEngine:
searchBus:inputDraftStore:)` + identical `@available init?(coder:)`; `makeChild`
repeats the 7-arg call 4×. Adding/removing one app-scope dep is a 5–6-site edit;
P1's dead entries are the drift this already produced.
Location: `…/App/AppKit/DetailRouterViewController.swift:114-131,363-410,430-435`;
`…/App/AppKit/ChatSessionViewController.swift:124-141,576-581`;
`…/Content/Chat/ComposeSessionViewController.swift:44-61,100-105`;
`…/Content/Chat/DraftSessionLandingViewController.swift:26-60,123-128`;
`…/Content/Archive/ArchiveViewController.swift:31-51,75-80`.
Fix: one `DetailContext`/`AppDependencies` struct (model + the *consumed* services)
threaded whole through `makeChild`; one `View.injectAppEnvironment(_:)` helper.
Does NOT require injecting `AppState` itself (model isn't part of AppState) and
keeps "views never construct services." Highest-value, lowest-risk structural win.

**P3 — `SidebarViewController` is a ~770-line god-VC with 7 interleaved concerns.**
Root cause: one type does view construction, tree building, group ordering, three
`withObservationTracking` loops, drag-and-drop, the whole context menu, and per-row
state application — conforming to `NSOutlineViewDataSource`/`Delegate`/`NSMenuDelegate`
all on itself. The records→tree, model→selection, session→row data paths are
interleaved with menu/DnD plumbing; no unit test covers tree building/grouping/DnD.
Location: `…/Sidebar/SidebarViewController.swift:33-770` (data-source ext `:500`,
delegate `:591`, per-row obs `:677`, menu `:743`).
Fix: extract a pure `SidebarTreeModel` (records + group order → `[SidebarItemNode]`,
testable), a thin VC owning the outline + observation wiring, and a
`SidebarContextMenuController`.
Invariants to keep: `SidebarItemNode` stays a reference type (6.1); echo-suppression
on selection survives (6.3); write to `model.select(_:)` not raw `selection` (6.4);
per-row obs re-arm + recycle guard + non-allocating `existingSession` (6.7/6.8).

**P4 — `BackgroundTaskButton` pierces the `Session` façade to call
`session.runtime.markTaskStoppedLocally(...)`.** Root cause: the only production UI
(outside demos) that reaches `session.runtime` directly; there is no
`Session.stopBackgroundTask(...)` forwarder. Violates the documented rule "views
write through `Session` methods, never `session.runtime.X`" — the single
unidirectional-flow violation in the chat UI.
Location: `…/Content/Chat/InputBarControls/BackgroundTaskButton.swift:80-85`
(method defined only at `…/Services/Session/Session/SessionRuntime+Tasks.swift:124`).
Fix: a one-line phase-aware `Session.stopBackgroundTask(taskId:)` forwarder (no-op
on `.draft`), mirroring `requestContextUsage`. The fix is in the product, and it
strengthens the invariant rather than weakening it.

### MEDIUM

**P5 — `ChatSessionViewController` mixes "what to show" with the transcript-swap
state machine (~680 lines).** Root cause: the VC owns scrim geometry, the bar host,
the per-attach transcript pipeline, a same-session crossfade, the sheet-presenter
lifecycle, focus, the running-obs task, and turn-usage plumbing. The transcript-swap
machinery (`attachSession` + `crossfadeTranscriptSwap` + `finishTranscriptFadeOut`,
`:281-506`) is ~225 invariant-dense lines.
Location: `…/App/AppKit/ChatSessionViewController.swift:46-592`.
Fix: extract a `TranscriptSwapCoordinator` owning the build-in-front→settle→bind→
scrollToTail→drop-outgoing choreography. High value, **highest risk** in the area —
must preserve the §2.19 single-width attach contract (chat-I2), the disabled-
CATransaction scoping (I3), build-in-front ordering (I4), the outgoing-flush-before-
bind observer ordering (I5), and `prepareForRemoval` teardown (I14). Do not touch
without the two reentry-layout tests green.

**P6 — Two parallel crossfade state machines.** Root cause: `DetailRouterViewController`
runs a cross-kind crossfade (`fadingOutChild`/`commitChildTransition`/`finishFadeOut`)
and `ChatSessionViewController` runs a same-session transcript crossfade
(`fadingOutTranscript`/`crossfadeTranscriptSwap`/`finishTranscriptFadeOut`) — same
"park + flush-on-next-swap + guarded-completion + 0.18s" shape, two implementations,
two duplicated duration constants. A regression fix to one won't propagate.
Location: `…/App/AppKit/DetailRouterViewController.swift:96-104,336-361`;
`…/App/AppKit/ChatSessionViewController.swift:113-122,476-506`.
Fix: a shared crossfade helper — but the transcript variant carries the load-bearing
`removeObserver` flush ordering (chat-I5), so any abstraction must preserve it
exactly. Pairs naturally with P5.

**P7 — Grouping + tool-pairing logic implemented twice (live vs cold).** Root cause:
two engines produce `MessageEntry`/`GroupEntry` from `Message2` — the live `receive`
path grows groups forward off `messages.last`; the cold path reverse-folds via
`ReverseEntryBuilder`. They share only `isGroupableAssistant` and a single parity
test. A grouping-rule change is a two-place edit guarded only by that test.
Location: `…/Services/Session/Session/ReverseEntryBuilder.swift:35` (cold) vs
`…/Services/Session/Session/SessionRuntime+Receive.swift:274` (`appendToTimeline`)
+ `:310` (`attachToolResult`).
Fix: factor the grouping/pairing rules into one shared engine both directions call.
Invariants: history never flows through the bridge (bridge-I1); "no `.update` on
load" (bridge-I9); cross-page withhold buffer + doc-order parse (bridge-I8).

**P8 — `SessionRuntime` god-object (~3000 lines / 9 files / 23 @Observable fields +
7 sinks).** Root cause: it owns CLI lifecycle, message timeline, streaming/typewriter,
token accounting, background-task tracking, todo tracking, context-usage caching,
title generation, permission queue, config persistence. Tasks/todos/context-usage/
streaming are self-contained projections with their own scratch state.
Location: `…/Services/Session/Session/SessionRuntime.swift:18-545` + 8 extensions.
Fix: extract `TodoTracker`/`TaskTracker`/`TurnUsageMeter`/`ContextUsageCache` value
or sub-objects the runtime composes — only if the synchronous `onMessagesChange`
fire contract (runtime-I1) and `receive` side-effect ordering (runtime-I3) are
preserved exactly.

**P9 — `Session` wide forwarding façade (~690 lines, ~40 forwarders) + per-field
two-file tax.** Root cause: every runtime field needs a `SessionRuntime` field AND a
`Session` `switch phase` forwarder; ~15 near-identical `runtime?.x ?? default`
one-liners. Tempting to "fix" with a shared phase protocol — but the draft and
runtime read-surfaces genuinely diverge (status/messages/tasks/todos are runtime-
only), so a naive protocol would fabricate runtime-only fields on the draft.
Location: `…/Services/Session/Session/Session.swift:300-498`.
Fix (cautious): this is mechanical boilerplate, not tangled flow. Leave the phase
dispatch; at most generate or group the read forwarders. This is a *do-not-over-
engineer* item — flagged so a refactor doesn't gold-plate it.

**P10 — Closure-sink triple-declaration + `SyntaxHighlightEngine` injected as
`searchEngine`.** Two related boundary-clarity issues:
(a) each AppKit-channel notification is declared in 3 places — runtime field,
`Session` mirror `didSet`, and the `wireRuntimeMessagesSink` re-assignment
(`…/Services/Session/Session/Session.swift:103-149,259-263`). Subtle but
intentional (set-before-promotion vs set-at-promotion timing); the most
error-prone surface for a new sink.
(b) the syntax highlighter is threaded under the param/property name `searchEngine`
across 5 VCs, then re-exposed as `\.syntaxEngine` — a reader expects transcript
*search* machinery; it is unrelated to `TranscriptSearchBus`.
Location (b): `…/App/AppKit/MainSplitViewController.swift:34`,
`…/App/AppKit/DetailRouterViewController.swift:75,119,127,416`,
`…/App/AppKit/ChatSessionViewController.swift:69,129,137`,
`…/Content/Archive/ArchiveViewController.swift:25,36`,
`…/Content/Chat/ComposeSessionViewController.swift:38,49`,
`…/Content/Chat/DraftSessionLandingViewController.swift:30,45`.
Fix: rename `searchEngine` → `syntaxEngine` (pure rename, no behavior); for (a) a
tiny sink-registration helper, or accept it and keep the doc.

**P11 — Ownership-pattern inconsistency across app-scope state.** Root cause: 8
services on `AppState`, 3 as `.shared` singletons (`ModelStore`/`EffortDefaultStore`/
`NewSessionDefaultsStore`) reached directly from views + runtime, and 2 (`searchBus`,
`selectionModel`) owned by `AppDelegate` not `AppState`. Two completion stores
(`FileCompletionStore`/`SlashCommandStore`) are *also* process singletons reached
from inside trigger-rule closures. Plus root CLAUDE.md says AppState is "injected
through `.environment()`" — it is never injected whole (doc drift).
Location: `…/Services/ModelStore.swift:13`, `…/Services/EffortDefaultStore.swift:25`,
`…/Services/NewSessionDefaultsStore.swift:19`, `…/App/AppKit/AppDelegate.swift:31,34`;
doc at root CLAUDE.md AppState section.
Fix: a judgment call balanced against "no over-engineering." `ModelStore` (mutable
observable catalog + spawns a CLI subprocess) is the most questionable singleton; the
two UserDefaults wrappers are low-harm. Reconcile the doc either way.

### LOW (cleanups; none block the refactor)

**P12 — Stale names / doc drift / AnyView erasure.** `composeOrBarHost` no longer
morphs (only the bar; `…/App/AppKit/ChatSessionViewController.swift:94`);
`TranscriptSearchBus` doc describes a deleted `.searchable` design
(`…/App/TranscriptSearchBus.swift:5-11`); multiple `RootView2` references in
`InputBarView2`/`NewSessionConfigurator` point at a deleted owner; the 5 pane hosts
use `AnyView` where a concrete generic would let the compiler enforce env injection;
`CompletionViewModel` reads as a "no ViewModel" rule violation but is a legitimate
self-contained input-method state machine (justified — consider rename to
`CompletionState`). Pure renames / doc edits / un-erasure.

**P13 — Dead code paths.** Directory-completion machinery is fully vestigial
(`DirectoryCompletionItem` never constructed; `tryConfirmFromInput`/`hasInputValidation`
zero callers; `onDeleteRecent` + "recent" pill dead) — `…/Content/Chat/Completion/*`;
deleting it removes 3 of 7 `CompletionSession` closures with no behavior change.
`ClaudeCodeStats` (~460 lines, fully tested) has no production consumer
(`…/Services/ClaudeCodeStats.swift`). `FileCompletionStore` `invalidate*` have zero
callers (slow FSEvent-stream leak).

**P14 — Duplicated derivation + cross-file magic-constant coupling.** `StableBlockID`
id-coordinate scheme replicated across `MessageEntryBlockBuilder`,
`Transcript2EntryBridge`, `ToolUseToChild` (4× verbatim fallback string); task
`titleLine`/`statusColor` derived 2–3× with diverging palettes
(`…/Content/Chat/InputBarControls/BackgroundTaskRow.swift` vs `…BackgroundTaskDetailSheet.swift`);
pill corner-radius `16` hardcoded in both `InputBarView2` and `TranscriptBottomScrimView`;
scrim/inset constants hand-summed from the bar's resting height. Each is a silent
coupling a refactor can break invisibly.

**P15 — Layering nits.** View-layer concerns (`SyntaxTheme`, `PermissionMode+Color`,
`Effort+Display`, `ANSIAttributedBuilder`) filed under `Models/` (which CLAUDE.md
defines as "plain data"); `SedEditParser` colocated with input-controls it has no
relation to; `ShimmerOverlay`/`collapsedSingleLineForDisplay` Sidebar-scoped but
app-generic; `GitProbe` is `@Observable` without `@MainActor` while every peer has it.

---

## 5. What's good — PRESERVE THIS

These are the deliberate, well-justified design decisions a refactor must keep. Each
is sourced from code + the invariant lists in the surveys.

1. **AppKit-rooted shell + the documented AppKit exceptions.** Window created in
   `applicationDidFinishLaunching` (not a SwiftUI scene) so the transcript mount +
   `frameDidChange` run in AppKit's source phase (app-shell I10). Transcript/main-
   window/sidebar/toolbar AppKit by measured exception; everything else SwiftUI. Do
   not "SwiftUI-ify" the spine or move window creation into a `WindowGroup`.

2. **The synchronous single-observer selection spine.** `select(_:)` writes the
   `@Observable` value AND synchronously notifies the *one* structural observer
   (router) in the click's source phase (I1). The router is the sole structural
   owner; the chat VC does NOT observe selection (I5); same-kind transitions REUSE
   the child VC (I3); `promote(to:)` re-fires on the unchanged-value draft→active
   case (I6); draft routing reads the durable status fresh (I7/I9). This is the
   whole point of the design — keep it synchronous and single-owner.

3. **Session owns controller + bridge for its whole lifetime.** Live CLI events
   flow into `controller.blocks` even with no view mounted; switch-back is O(1)
   warm re-entry (runtime-I2/I11). Bridge wired once, never at attach-time.

4. **Two disjoint, correctly-directed render channels.** SwiftUI reads `@Observable`
   (pull, no shadow copies); AppKit transcript gets synchronous closure push;
   history bypasses the bridge via the off-main backfill pipeline. "Pick one channel
   per piece of state" holds. The off-main build + off-main typeset + main-applies-
   cache-hits contract (bridge-I2/I3/I4) and the §2 perf contract are load-bearing.

5. **Handle-free input-bar leaf.** `InputBarView2` holds no `Session`; all inputs
   arrive by value from `InputBarChrome`, all mutations leave via injected closures.
   This is what lets one bar serve chat / compose / draft-landing / demo (input-bar
   I1). The `.id(sid)` reset and the imperative draft-clear-on-send (teardown-proof,
   I12) are subtle but correct.

6. **Closure-injection cross-view coordination ("no ViewModel" for session state).**
   The shared sinks `submitSessionInput` / `runBuiltinSlashCommand` centralize the
   write-back to the model; their step ordering is load-bearing (builtin order I11).
   Keep this instead of introducing a coordinating ViewModel.

7. **Host-sizing discipline.** `[]` + 4-edge pin for fill-pane children;
   `[.intrinsicContentSize]` + position-pin for subordinate components. Documented
   with the exact window-collapse failure it prevents (I8). The two-regime split is
   correct even though it makes the chat bar host look different from its siblings.

8. **Deterministic teardown + macOS-26 deinit workaround.** `DetailRouterChild.
   prepareForRemoval()` releases per-attach resources at swap time (I14);
   `nonisolated deinit {}` on every `@MainActor @Observable` / VC type (I13/I10)
   dodges the `swift_task_deinitOnExecutorImpl` abort. Keep both on any new type.

9. **Pure, off-main-safe value boundaries.** The Markdown IR (`MarkdownDocument`,
   `nonisolated MarkdownConvert`), `StableBlockID` content-independent identity, and
   `SedEditParser` purity are clean seams the diff/backfill fast paths depend on.

10. **Single shared `SyntaxHighlightEngine` reaching two renderers** (transcript via
    `attachSyntaxEngine`, `DiffView` via `\.syntaxEngine`) with one LRU + same-tick
    coalescing; lazy `RecentProjectsStore` (TCC-prompt-safe); single-owner push for
    notifications (no per-VC observation leak). All deliberate, all tested.

---

## 6. Refactor sequencing note (INFERENCE)

Lowest-risk → highest-value order: **P1 → P2 → P4 → P10(b rename) → P13(deletions)**
are mechanical, test-safe, and collapse the most surface. **P3 (sidebar split)** and
**P7 (grouping dedupe)** are extraction wins guarded by existing tests. **P5/P6
(transcript-swap + crossfade)** are the riskiest (touch the §2.19 attach contract +
observer-flush ordering) — do last, behind green reentry-layout tests. **P8/P9
(runtime/façade)** are large but the façade boilerplate (P9) is a *don't-gold-plate*
item; only P8's self-contained projections are worth extracting.

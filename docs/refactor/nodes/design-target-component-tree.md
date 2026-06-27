# Design: Target component tree (refactored) + AppKit↔SwiftUI boundary

Authoritative target-state design for the CCTerm component tree after the
unidirectional-flow refactor. Grounded in `analysis-component-tree.md` (the
synthesized as-is tree + ranked problems P1–P15) and the subsystem surveys
(`survey-chat-detail-vcs.md`, `survey-app-shell-routing.md`, `survey-sidebar.md`,
`survey-app-services-models.md`), and verified against the load-bearing
invariants in all four CLAUDE.md files.

Source root abbreviated `…` = `macos/ccterm`. Legend identical to the as-is tree:
`[AK]` AppKit · `[SU]` SwiftUI `View` · `[SVC]` `@Observable`/actor service ·
`[VM]` ViewModel/state-machine value · `[MDL]` plain value/model ·
`«HC»` `NSHostingController` · `«HV»` `NSHostingView`. Hosting bridges note
`sizingOptions` + regime.

> **Design stance.** The as-is architecture is *already substantially clean and
> unidirectional* (analysis §Executive summary, §5). This is NOT a re-architecture.
> It is a **surgical** pass: collapse DI boilerplate, split the two true god-VCs
> along their existing internal seams, name nodes honestly, and remove dead edges —
> while leaving every load-bearing invariant (selection spine, render channels,
> §2 transcript perf contract, §2.19 attach contract, host-sizing discipline,
> macOS-26 deinit workaround) byte-for-byte intact. Where a "clean" idea would
> touch one of those invariants, I stop and design around it; those are recorded
> under *Rejected alternatives*.

---

## 0. What changes at a glance (before → after summary)

| # | Change | Maps to | Layer impact | Risk |
|---|---|---|---|---|
| C1 | Introduce a single `DetailContext` value carrying `model` + the *consumed* services; thread it whole through `makeChild` and every child VC init | P2, S1 | AppKit shell DI | Low |
| C2 | One `View.injectDetailEnvironment(_:)` helper replaces 5 copies of the `.environment(...)` block; drops the 2 dead injections | P1, P2, S2 | AppKit↔SwiftUI seam | Low |
| C3 | Rename `searchEngine` → `syntaxEngine` everywhere it is threaded; un-erase the 5 `AnyView` pane hosts to concrete generics | P10(b), P12 | naming/typing | Low |
| C4 | Add `Session.stopBackgroundTask(taskId:)` façade forwarder; `BackgroundTaskButton` calls it instead of `session.runtime.markTaskStoppedLocally` | P4, S(button) | Service façade | Low |
| C5 | Extract `SidebarTreeModel` (pure records→`[SidebarItemNode]`) + `SidebarContextMenuController`; VC keeps outline + observation wiring | P3, S5.1 | Sidebar (AK) | Med |
| C6 | Extract `TranscriptSwapCoordinator` from `ChatSessionViewController`; the VC keeps "what to show", the coordinator owns the attach/crossfade state machine | P5, S9 | Chat detail (AK) | **High** |
| C7 | Extract a shared `CrossfadeController` helper used by both the router (cross-kind) and the swap coordinator (same-session) | P6, S6 | AppKit shell | Med |
| C8 | Add `SessionPresentingChild` protocol so the router calls `present` polymorphically | S9 (shell) | AppKit shell | Low |
| C9 | Add `mountFillPaneHost(_:in:)` helper shared by the 3 full-pane VCs | S4 | AppKit↔SwiftUI seam | Low |
| C10 | Factor grouping/tool-pairing into one `EntryGrouping` engine both live + cold call | P7 | Session/bridge | Med |
| C11 | Extract self-contained runtime projections (`TodoTracker`/`TaskTracker`/`TurnUsageMeter`/`ContextUsageCache`) the runtime composes | P8 | Session runtime | Med |
| C12 | Reconcile ownership doc + (optionally) fold the 3 UserDefaults `.shared` stores onto `AppState`; leave `ModelStore` as-is, documented | P11 | App-scope state | Low |
| C13 | Rename stale symbols: `composeOrBarHost`→`restingBarHost`; `CompletionViewModel`→`CompletionState`; fix doc drift | P12 | naming | Low |
| C14 | Delete vestigial paths (directory-completion, `ClaudeCodeStats`, unused `FileCompletionStore.invalidate*`) | P13 | dead-code | Low |

**Explicitly NOT done** (rejected as over-engineering or invariant-violating):
collapse `Session`'s phase-dispatch forwarders behind a protocol (P9 — the draft
and runtime read-surfaces genuinely diverge); merge `Transcript2Controller` +
`Transcript2Coordinator` (NativeTranscript2 §1.1 says don't); convert the router's
structural notification to `withObservationTracking` (I1); SwiftUI-ify any AppKit
spine node. See *Rejected alternatives*.

---

## 1. The target component tree (authoritative)

Changes from the as-is tree are flagged inline: `★NEW`, `★SPLIT`, `★RENAMED`,
`★UNERASED`, `★DELETED`. Nodes with no flag are unchanged.

```
CCTermApp  [SU App, @main]  ......................................... …/App/CCTermApp.swift
├── @NSApplicationDelegateAdaptor → AppDelegate  [AK]  .............. …/App/AppKit/AppDelegate.swift
└── Scene: Settings { EmptyView() }  [SU placeholder scene]
    └── .commands { AppCommands }  [SU Commands]
          (About / Settings ⌘, / Find ⌘F — UNCHANGED; invariant I9 preserved)

AppDelegate  [AK]  (app-scope owner; creates main window in applicationDidFinishLaunching — I10)
│   ── owns app-scope state, constructor-injected downward ──
├── appState: AppState  [SVC, @Observable]  ........................ …/App/AppState.swift
│   ├── sessionManager: SessionManager  [SVC]
│   │     └── sessions: [String: Session]  [SVC, @Observable]
│   │           ├── phase: .draft(SessionDraft) | .active(SessionRuntime)  [SVC]
│   │           │     └── SessionRuntime composes (★SPLIT-C11 — projections, not new edges):
│   │           │           ├── todos: TodoTracker         [MDL/value] ★NEW
│   │           │           ├── tasks: TaskTracker         [MDL/value] ★NEW
│   │           │           ├── turnUsage: TurnUsageMeter  [MDL/value] ★NEW
│   │           │           └── contextUsage: ContextUsageCache [MDL/value] ★NEW
│   │           │              (runtime stays the @Observable owner + sink fire site;
│   │           │               trackers are plain projections it mutates — runtime-I1/I3 intact)
│   │           ├── controller: Transcript2Controller  [SVC] ← render-side, SESSION-LIFETIME (UNCHANGED)
│   │           │     └── coordinator: Transcript2Coordinator  [AK, NSObject] (DON'T MERGE — §1.1)
│   │           ├── bridge: Transcript2EntryBridge  [translator] (ALWAYS WIRED — UNCHANGED)
│   │           │     └── uses EntryGrouping  [MDL, pure] ★NEW-C10 (shared with ReverseEntryBuilder)
│   │           └── backfillPipeline: TranscriptBackfillPipeline?  (UNCHANGED — bypasses bridge)
│   │                 └── ReverseEntryBuilder → EntryGrouping  ★NEW-C10 (same engine, cold direction)
│   ├── syntaxEngine: SyntaxHighlightEngine  [SVC, actor]
│   ├── recentProjects: RecentProjectsStore  [SVC, lazy]
│   ├── inputDraftStore: InputDraftStore  [SVC]
│   ├── sidebarGroupOrder: SidebarSessionGroupOrderStore  [SVC]
│   ├── activationTracker / notificationService / openInService  [SVC]
│   └── (★C12 optional) modelStore / effortDefaults / newSessionDefaults  [SVC]
│         folded onto AppState from .shared, OR left .shared + doc reconciled (see §6.C12)
├── searchBus: TranscriptSearchBus  [SVC, @Observable]  (owned here — UNCHANGED)
├── selectionModel: MainSelectionModel  [SVC, @Observable]  (owned here — UNCHANGED)
├── settingsWindowController? → «HC» SettingsView  [SU]   (default sizingOptions — UNCHANGED)
├── aboutWindowController?    → «HC» AboutView     [SU]   (default sizingOptions — UNCHANGED)
└── mainWindowController?: MainWindowController  [AK]
    ├── NSToolbar (delegate = self)  (UNCHANGED items)
    │   ├── projectChip → «HV» TranscriptProjectChip [SU]   [.intrinsicContentSize]
    │   ├── archiveFilter → «HV» ArchiveFilterToolbarButton [SU] [.intrinsicContentSize]
    │   └── search → NSSearchToolbarItem [AK] → TranscriptSearchToolbarBridge [AK]
    │         (controllerProvider PULLS live session's controller — UNCHANGED)
    └── window.contentVC = MainSplitViewController  [AK]
        │   ★CHANGED-C1: builds ONE `DetailContext` value (model + consumed services);
        │   passes it whole to the router; builds one `SidebarContext` for the sidebar.
        │   (no more 7-bag / 4-bag fan-out)
        │
        ├── sidebar item → SidebarViewController  [AK, NSOutlineView]  ★SPLIT-C5
        │     │   thin VC: owns outline + 3 observation loops + selection wiring
        │     ├── treeModel: SidebarTreeModel  [MDL, pure, testable] ★NEW-C5
        │     │     (records + groupOrder → [SidebarItemNode]; replaces inline
        │     │      buildRootChildren/groupedRecords/lastSeenGroups state)
        │     ├── contextMenu: SidebarContextMenuController [AK] ★NEW-C5
        │     │     (NSMenuDelegate + Open-in submenu + archive/copy-path actions)
        │     └── scrollView → NoDisclosureOutlineView [AK]
        │           └── rows: SidebarFixedCellView / SidebarFolderCellView /
        │               SidebarHistoryCellView (→ SidebarStatusIndicatorView + ShimmerOverlay)
        │               (all cells UNCHANGED — invariants 6.1/6.2/6.7/6.9/6.11/6.12 intact)
        │
        └── detail item → DetailRouterViewController  [AK, MainSelectionObserver]
            │   view = NSVisualEffectView(.contentBackground)
            │   ★CHANGED: holds one `DetailContext`; `makeChild` passes it whole.
            │   crossfade now delegated to ↓
            ├── crossfade: CrossfadeController  [AK helper] ★NEW-C7
            │     (park-outgoing → flush-on-next-swap → guarded-completion → duration)
            │   currentChild = exactly ONE of the below (single-child invariant I2 intact)
            │
            ├── .transcript → ChatSessionViewController  [AK, SessionPresentingChild] ★SPLIT-C6
            │     │   NOW: "what to show" only — owns scrims, the resting-bar host,
            │     │   focus, turn-usage plumbing, running-obs. Delegates the transcript
            │     │   attach/swap state machine to ↓.
            │     ├── swap: TranscriptSwapCoordinator  [AK] ★NEW-C6
            │     │     │   owns: build-in-front → settle → bindData → scrollToTail →
            │     │     │   drop-outgoing; the same-session crossfade; the per-attach
            │     │     │   transcriptScroll + sheet-presenter lifetimes.
            │     │     │   (§2.19 attach contract + chat-I3/I4/I5 live HERE now, unchanged)
            │     │     │   uses CrossfadeController ★C7
            │     │     ├── transcriptScroll: Transcript2ScrollView [AK] (per-attach)
            │     │     │     └── Transcript2ClipView → Transcript2TableView → BlockCellView
            │     │     │           └── leaf SwiftUI: LoadingPillUsageView
            │     │     └── transcriptSheetPresenter: Transcript2SheetPresenter [AK] (per-attach)
            │     │           └── «HC» UserBubbleSheetView | ImagePreviewSheetView [SU] (beginSheet)
            │     ├── topScrim: TranscriptTopScrimView  [AK]  (intercepts mouse — UNCHANGED)
            │     ├── bottomScrim: TranscriptBottomScrimView [AK] (passthrough — UNCHANGED)
            │     └── restingBarHost: «HV» ChatComposeStack  [SU] ★RENAMED-C13 ★UNERASED-C3
            │           sizingOptions=[.intrinsicContentSize]  (component — I7/I8 intact)
            │           └── ChatComposeStack  [SU]  (routes selection → bar | EmptyView)
            │                 └── ChatRestingBar .id(sid)  [SU]
            │                       └── ZStack(alignment:.bottom)
            │                             ├── InputBarChrome → InputBarView2 + InputBarSessionChrome
            │                             │     ├── PermissionModePicker / TodoButton /
            │                             │     │   ModelEffortPicker / ContextRingButton  [SU]
            │                             │     └── BackgroundTaskButton  [SU] ★CHANGED-C4
            │                             │           → session.stopBackgroundTask(taskId:)  (façade)
            │                             │           └── .sheet → BackgroundTaskDetailSheet [SU]
            │                             │                 └── BackgroundTaskOutputStream [SVC]
            │                             └── PermissionCardView?  [SU]  (UNCHANGED — card geometry out of scope)
            │                       (InputBarView2 handle-free leaf + .id(sid) reset +
            │                        imperative draft-clear — input-bar I1/I12 intact)
            │
            ├── .compose → ComposeSessionViewController  [AK]
            │     └── «HC» ComposeSessionView  [SU] ★UNERASED-C3  sizingOptions=[] (fill-pane)
            │           via mountFillPaneHost(_:in:) ★NEW-C9
            │           └── ComposeSessionView → NewSessionConfigurator{ InputBarChrome }
            │                 └── (@State GitProbe → BranchPickerView)
            │
            ├── .draftLanding → DraftSessionLandingViewController  [AK, SessionPresentingChild] ★C8
            │     └── «HC» DraftSessionLandingView  [SU] ★UNERASED-C3  sizingOptions=[] (fill-pane)
            │           via mountFillPaneHost(_:in:) ★NEW-C9
            │
            ├── .archive → ArchiveViewController  [AK]
            │     └── «HC» ArchiveView  [SU] ★UNERASED-C3  sizingOptions=[] (fill-pane)
            │           via mountFillPaneHost(_:in:) ★NEW-C9
            │
            └── .demo(_) (DEBUG) → demo VCs  [AK]  (each owns its own swap pieces — UNCHANGED)

Global singletons (★C12 candidates):
  ModelStore.shared (KEEP .shared — see §6.C12)  ·  EffortDefaultStore.shared
  NewSessionDefaultsStore.shared  ·  FileCompletionStore.shared  ·  SlashCommandStore.shared

Data-feed siblings (not in the view tree):
  Transcript2EntryBridge ← live channel ·  TranscriptBackfillPipeline ← cold channel
  EntryGrouping [pure] ★NEW ·  MarkdownDocument/Convert [pure value IR]
```

---

## 2. Side-by-side: before → after, per node

| Node | As-is | Target | Why |
|---|---|---|---|
| **DI into detail children** | 7-arg init re-declared on router + 5 VCs; `makeChild` repeats 7-arg call 4× | One `DetailContext` value threaded whole | P2/S1: add/remove a dep = 1-site edit; eliminates the drift that produced the 2 dead injections |
| **`.environment(...)` block** | 6-line chain copy-pasted 5× incl. 2 dead (`notifications`, `searchBus`) | `View.injectDetailEnvironment(ctx)`; injects only the 4 consumed (`SessionManager`, `RecentProjectsStore`, `InputDraftStore`, `\.syntaxEngine`) | P1/P2/S2: missed injection becomes a compile error after un-erasure; phantom edges removed |
| **`searchEngine` param** | `SyntaxHighlightEngine` threaded under name `searchEngine`, re-exposed as `\.syntaxEngine` | renamed `syntaxEngine` end-to-end | P10(b): reader no longer expects search machinery |
| **5 pane `AnyView` hosts** | `«HC» AnyView(...)` / `«HV» AnyView(...)` | concrete generic body | P12: compiler enforces env injection; dependency explicit |
| **`session.runtime.markTaskStoppedLocally`** | `BackgroundTaskButton` pierces façade | `session.stopBackgroundTask(taskId:)` forwarder (no-op on `.draft`) | P4: closes the lone production unidirectional-flow violation; strengthens the rule |
| **`SidebarViewController`** | ~770-line god-VC, 7 concerns | thin VC + `SidebarTreeModel` (pure) + `SidebarContextMenuController` | P3/S5.1: records→tree becomes testable + pure; menu/DnD localized |
| **`lastSeenGroups`** | hand-maintained derived cache in VC | absorbed into `SidebarTreeModel` (new-folder detection an explicit input to a pure build) | S5.3/6.10: duplicated state removed; seeding semantics preserved inside the model |
| **`ChatSessionViewController`** | ~680-line VC: "what to show" + transcript-swap state machine | VC keeps "what to show"; `TranscriptSwapCoordinator` owns attach/swap | P5/S9: VC reads top-to-bottom; the invariant-dense region is isolated behind tests |
| **Two crossfade machines** | router cross-kind + chat same-session, duplicated | one `CrossfadeController`, two call sites | P6/S6: one fix propagates; transcript variant's `removeObserver` flush stays in the swap coordinator (NOT in the shared helper — see §6.C7) |
| **`present` downcasts** | router downcasts to each concrete VC | `SessionPresentingChild` protocol | S9: one polymorphic call, one branch dropped |
| **3 fill-pane hosts** | identical `«HC»+[]+4-edge-pin` recipe × 3 + 3 rationale comments | `mountFillPaneHost(_:in:)` helper | S4: one recipe, one comment |
| **Live vs cold grouping** | `appendToTimeline`/`attachToolResult` vs `ReverseEntryBuilder`, parity test only | shared `EntryGrouping` engine | P7: grouping-rule change = 1-site edit |
| **`SessionRuntime` god-object** | 23 `@Observable` fields + 7 sinks across 9 files | runtime composes 4 projection trackers | P8: self-contained projections extracted; runtime stays the sink-fire site |
| **`composeOrBarHost`** | stale name (only ever the bar) | `restingBarHost` | P12/S7 |
| **`CompletionViewModel`** | mis-named "ViewModel" in a no-ViewModel area | `CompletionState` | P12: it's a self-contained input-method state machine, not a coordinating VM |
| **dead code** | directory-completion, `ClaudeCodeStats`, unused `invalidate*` | deleted | P13 |
| **`Session` façade forwarders** | ~40 phase-dispatch one-liners | **UNCHANGED** | P9: do-not-over-engineer — draft/runtime surfaces diverge; a protocol would fabricate fields |

---

## 3. AppKit↔SwiftUI boundary map (target)

The boundary moves in exactly **zero** places. Every hosting bridge keeps its
kind, `sizingOptions`, and regime. The only edits are (a) un-erasing `AnyView` to
concrete bodies, (b) routing the 3 fill-pane hosts through one helper, (c) renaming
the chat bar host. The two-regime split (fill-pane `[]` vs component
`[.intrinsicContentSize]`) is **preserved exactly** — it is invariant I7/I8 and the
documented window-collapse guard.

| # | Host | Kind | sizingOptions | Regime | Δ vs as-is |
|---|---|---|---|---|---|
| 1 | Settings window | «HC» SettingsView | default | window-sizing | — |
| 2 | About window | «HC» AboutView | default | window-sizing | — |
| 3 | Toolbar project chip | «HV» TranscriptProjectChip | `[.intrinsicContentSize]` | component | — |
| 4 | Toolbar archive filter | «HV» ArchiveFilterToolbarButton | `[.intrinsicContentSize]` | component | — |
| 5 | Chat bottom bar | «HV» **ChatComposeStack** (was AnyView) | `[.intrinsicContentSize]` | component | ★UNERASED, ★RENAMED host (`restingBarHost`) |
| 6 | Compose pane | «HC» **ComposeSessionView** (was AnyView) | `[]` | fill-pane | ★UNERASED, via `mountFillPaneHost` |
| 7 | Draft-landing pane | «HC» **DraftSessionLandingView** (was AnyView) | `[]` | fill-pane | ★UNERASED, via `mountFillPaneHost` |
| 8 | Archive pane | «HC» **ArchiveView** (was AnyView) | `[]` | fill-pane | ★UNERASED, via `mountFillPaneHost` |
| 9 | Demo permission-cards | «HC» PermissionCardsDemoView | `[]` | fill-pane | — (DEBUG) |
| 10 | Transcript sheets | «HC» UserBubble/ImagePreview | (modal) | beginSheet | — (now owned by `TranscriptSwapCoordinator`'s presenter, same lifetime) |
| 11 | Demo control panels | «HV» (various) | default | component | — (DEBUG) |

**Sidebar stays 100% AppKit** (no hosting boundary) even after the C5 split —
`SidebarTreeModel` is a plain value type, `SidebarContextMenuController` is an
`NSObject`/`NSMenuDelegate`. The transcript stays the most AppKit-pure region; the
C6 split does NOT introduce any new SwiftUI inside it — `TranscriptSwapCoordinator`
is AppKit and owns the same AppKit per-attach objects the VC owned before.

---

## 4. Layer & ownership model (target)

| Layer | Members (Δ flagged) | Constructed by | Lifetime |
|---|---|---|---|
| App lifecycle | `AppDelegate` | SwiftUI runtime | process |
| App-scope state | `AppState`, `searchBus`, `selectionModel` | `AppDelegate` | process |
| App-scope services | 8 on AppState (+ ★C12: 3 folded-or-documented) | `AppState.init` / lazy | process |
| Window shell | `MainWindowController` → `MainSplitViewController` → `SidebarVC` + `DetailRouterVC` | `applicationDidFinishLaunching` | window |
| **DI context** ★NEW | `DetailContext`, `SidebarContext` (plain value bags) | `MainSplitViewController.init` (built once from `appState`) | window |
| Detail children | Chat / Compose / DraftLanding / Archive / demo VCs | `DetailRouterViewController.makeChild` (now ctx-threaded) | one alive; same-kind REUSES (I3) |
| **Crossfade** ★NEW | `CrossfadeController` (× router, × swap coordinator) | each owner | with its owner |
| **Transcript swap** ★NEW | `TranscriptSwapCoordinator` | `ChatSessionViewController` | VC lifetime; owns per-attach transcriptScroll + presenter |
| Per-attach (chat) | `transcriptScroll`, `sheetPresenter`, running-obs | `TranscriptSwapCoordinator.attach` (moved from VC) | re-created per switch |
| Session core | `Session` + `controller` + `bridge` (+ ★C11 projection trackers) | `SessionManager.makeSession` | session lifetime |
| **Sidebar tree** ★NEW | `SidebarTreeModel` (value), `SidebarContextMenuController` | `SidebarViewController` | VC lifetime |
| Per-load | `TranscriptBackfillPipeline` (→ `EntryGrouping`) | `Session.loadHistory()` | one cold load |
| Pure value | `EntryGrouping` ★NEW, `SidebarTreeModel` ★NEW, Markdown IR, `StableBlockID` | call site | per call |
| SwiftUI value views | all `[SU]` nodes (now concrete, not AnyView) | `body` re-eval | per render; `.id(sid)` reset |
| View-scope state | `CompletionState` ★RENAMED, `GitProbe`, `BackgroundTaskOutputStream` | `@State` | view identity |

**The single deliberate upward edge is preserved**: `MainSelectionModel.selectionObserver`
(weak) → router. `DetailContext` does not change this — it carries *downward* deps
only. The router still registers itself as the sole structural observer in `viewDidLoad`.

**`DetailContext` shape** (the one new DI value — kept minimal, only the consumed set):

```swift
struct DetailContext {                 // value type, no @Observable
    let model: MainSelectionModel
    let sessionManager: SessionManager
    let recentProjects: RecentProjectsStore
    let inputDraftStore: InputDraftStore
    let syntaxEngine: SyntaxHighlightEngine   // ★ renamed from searchEngine
    let notifications: NotificationService     // kept: router OWNS onActivateSession/onLaunchFailure
    // searchBus DROPPED from the SwiftUI-env set (P1) — but still passed to the
    // router for the toolbar bridge if needed; NOT injected into any child env.
}
```

> Note: `notifications` stays in the context because the **router** consumes it
> (it wires `onActivateSession` / `onLaunchFailure` in `viewDidLoad`). What P1
> removes is the *SwiftUI-environment injection* of `notifications` + `searchBus`
> into child bodies — no SwiftUI view reads either. The context still carries
> `notifications`; `injectDetailEnvironment` simply does not put it in the env.

---

## 5. The two true splits, in detail (C5, C6)

### C5 — Sidebar god-VC split (P3)

```
BEFORE                                    AFTER
SidebarViewController (770L)              SidebarViewController (thin)
  buildRootChildren / groupedRecords  →   ├─ treeModel: SidebarTreeModel  [pure]
  lastSeenGroups state                →   │    func build(records:, groupOrder:,           ← input
  prependIfAbsent diffing             →   │               previouslySeenGroups:) -> Result   (no stored state)
  NSOutlineViewDataSource/Delegate    →   ├─ (kept on VC — outline + the 3 obs loops)
  NSMenuDelegate + Open-in submenu    →   └─ contextMenu: SidebarContextMenuController
  archive/copy-path/open-in actions   →        (owns NSMenu, representedObject plumbing,
                                                 isEnabled toggling; calls back via closures)
```

- `SidebarTreeModel.build(...)` is a **pure function**: `(records, groupOrder,
  previouslySeenGroups) -> (nodes: [SidebarItemNode], newGroups: [String])`. The
  VC feeds it `previouslySeenGroups` and applies `newGroups` to the order store —
  so invariant **6.10** (existing folders at launch are NOT treated as new) is
  preserved as an *explicit input*, not a hidden `lastSeenGroups` cache (S5.3).
  This makes tree building + grouping + new-folder detection unit-testable for the
  first time (analysis "no unit test covers tree building/grouping/DnD").
- `SidebarItemNode` **stays a reference type** (invariant 6.1) — the tree model
  produces them but they remain class instances for `NSOutlineView` identity keying.
- DnD `acceptDrop` still mutates `rootChildren` in place + persists folder order
  (invariant 6.6) — it lives on the VC (it needs the live `outlineView.moveItem`),
  but the order it persists comes from the same model.
- Echo-suppression (`isApplyingSelectionFromModel`) + write-through `model.select(_:)`
  (invariants 6.3, 6.4) stay on the VC. Per-row observation re-arm + recycle guard +
  non-allocating `existingSession` (6.7, 6.8) stay on the VC.

### C6 — Chat detail-VC split (P5, S9) — **highest risk**

```
BEFORE                                    AFTER
ChatSessionViewController (680L)          ChatSessionViewController ("what to show")
  scrim geometry                      →    ├─ topScrim / bottomScrim (kept)
  restingBarHost                      →    ├─ restingBarHost (kept, renamed)
  focus / turn-usage / running-obs    →    ├─ focus + turn-usage + running-obs (kept)
  present(sessionId:)                 →    ├─ present(sessionId:) → swap.attach(...)
  attachSession (225L, invariant-dense) →  └─ swap: TranscriptSwapCoordinator
  crossfadeTranscriptSwap                       owns: attach pipeline, same-session crossfade,
  finishTranscriptFadeOut                             per-attach transcriptScroll + sheetPresenter,
  tearDownTranscript                                  prepareForRemoval teardown
```

`TranscriptSwapCoordinator` owns the **entire** §2.19 attach contract and the
chat-side crossfade. The VC's `present(sessionId:)` becomes a thin forwarder that
hands the coordinator the resolved `Session` + the settled host view. **Every
ordering invariant moves intact**, it does not change:

- I2/§2.19 single-width attach: `factory.make` (unbound) → `addSubview` →
  `view.layoutSubtreeIfNeeded()` → `factory.bindData` → `controller.scrollToTail()`.
  The router still settles the frame before calling `present` (I4/I6).
- I3: structural attach inside `CATransaction.setDisableActions(true)` +
  `allowsImplicitAnimation = false`; the alpha fade OUTSIDE it.
- I4: build-in-front-then-drop (no blank-pane flash).
- **I5: `finishTranscriptFadeOut()` runs synchronously at the head of `attach`,
  BEFORE the new `bindData`** — because `dismantle` does a blanket
  `removeObserver(coordinator)` and a parked outgoing scroll for the SAME session
  shares the coordinator. **This is exactly why the shared `CrossfadeController`
  (C7) must NOT own the flush** (see §6.C7).
- I14: `prepareForRemoval()` → coordinator teardown (transcriptScroll dismantle,
  sheet presenter stop, running task cancel, parked crossfade flush).

The two merge-gate tests (`TranscriptReentryLayoutCacheTests`,
`TranscriptHostReentryLayoutCacheTests`) drive `ChatSessionViewController.present`
end-to-end — they keep passing because `present`'s observable behavior is identical;
only the internal owner of the choreography moved. **These tests are the gate: C6
does not land until both stay green against the existing three regression shapes.**

---

## 6. Per-change rationale, alternatives, and invariant proofs

### C1 `DetailContext` — why a value bag, not `AppState`
Injecting `AppState` whole was considered and **rejected**: `MainSelectionModel`
is NOT part of `AppState` (it's owned by `AppDelegate`), so a child would still
need a second param; and `AppState` carries services no child needs (e.g.
`activationTracker`), widening every child's surface. A purpose-built value bag of
*exactly the consumed set* is the minimal honest dependency edge. It keeps "views
never construct services" (the bag holds references, constructs nothing). Reconciles
the doc-drift (P11/S3: root CLAUDE.md claims AppState is `.environment`-injected;
it never is) by making the real injected set explicit.

### C2 `injectDetailEnvironment` — and the dead-edge deletion
After un-erasure (C3), a missing `.environment(...)` is a compile error, so the
helper is safe to centralize. It injects only `{ SessionManager, RecentProjectsStore,
InputDraftStore, \.syntaxEngine }` — the verified consumed set (P1: grep proved 0
SwiftUI readers of `NotificationService` / `TranscriptSearchBus`).

### C4 `Session.stopBackgroundTask(taskId:)`
One phase-aware forwarder mirroring `requestContextUsage`: `.active` → `runtime.markTaskStoppedLocally`,
`.draft` → no-op. Strengthens the documented rule "views write through `Session`,
never `session.runtime.X`" — the fix is in the product, not a test hack.

### C7 — the shared `CrossfadeController` boundary (the delicate one)
The shared helper owns ONLY the generic, identical part: **park outgoing → animate
opacity over `duration` → guarded completion (drop if superseded) → flush-on-next-swap.**
It does **NOT** own the transcript-specific `removeObserver` flush ordering (I5) —
that stays inside `TranscriptSwapCoordinator.attach`, called synchronously at the
head, before any new bind. The router's cross-kind path has no such observer
coupling, so it uses the helper plainly. This is why C7 is "extract the shape, not
the side effects": the abstraction is the animation/lifecycle skeleton; each owner
keeps its own pre-flush. Rejected: a fully-generic crossfade that also owns teardown
— it would have to know about coordinator-shared observers, leaking transcript
internals into a shell helper.

### C10 `EntryGrouping` — preserving the bridge invariants
One pure engine for `isGroupableAssistant` + tool-pairing + group growth, called
both forward (live `appendToTimeline`/`attachToolResult`) and reverse
(`ReverseEntryBuilder`). The live path still grows off `messages.last`; the cold
path still reverse-folds — they share the *rules*, not the traversal. Invariants
preserved: history never flows through the bridge (bridge-I1); no `.update` on load
(bridge-I9); cross-page withhold buffer + doc-order parse (bridge-I8). The existing
parity test becomes the regression net for the shared engine.

### C11 `SessionRuntime` projections — what is NOT extracted
Extract ONLY the self-contained projections with their own scratch state:
`TodoTracker`, `TaskTracker`, `TurnUsageMeter`, `ContextUsageCache`. The runtime
**stays** the `@Observable` owner (fields remain on it / forward to the tracker),
the CLI-lifecycle owner, and the **synchronous `onMessagesChange` fire site**
(runtime-I1) with unchanged `receive` side-effect ordering (runtime-I3). The
trackers are plain value/sub-objects the runtime mutates inline — no new async
channel, no second mutation path. Streaming/typewriter is NOT extracted (too
entangled with `receive` ordering). This is bounded; if a tracker can't be lifted
without touching `receive` ordering, it stays.

### C12 `ModelStore` / UserDefaults stores — the judgment call
- **`EffortDefaultStore` / `NewSessionDefaultsStore`** — thin UserDefaults
  wrappers, low harm; fold onto `AppState` for ownership consistency (they become
  `appState.effortDefaults` etc., reached via the context where a view needs them).
  Cheap win.
- **`ModelStore.shared` — KEEP as `.shared`.** It's a mutable observable catalog
  that spawns a CLI subprocess to refresh; it's read from deep inside SwiftUI
  pickers AND from the runtime. Threading it through every context + env for a
  process-global catalog is more plumbing than it saves. **The right move is to
  reconcile the doc** (note the deliberate `.shared` exception), not to over-thread.
- **`FileCompletionStore` / `SlashCommandStore`** — reached from inside trigger-rule
  closures; leave `.shared` (they're completion-engine internals, not app state).

This is explicitly a *don't-over-engineer* line: ownership consistency where it's
cheap, documented exception where threading would cost more than it's worth.

### P9 — explicitly NOT done (do-not-gold-plate)
The ~40 `Session` forwarders are mechanical boilerplate, not tangled flow. A shared
phase protocol was **rejected**: the draft and runtime read-surfaces genuinely
diverge (status/messages/tasks/todos are runtime-only) — a naive protocol would
fabricate runtime-only fields on the draft. Leave the phase `switch`. At most,
group the read forwarders by section. This item is flagged so the refactor doesn't
waste risk-budget on it.

---

## 7. Rejected alternatives (and why)

1. **Inject `AppState` whole / `.environment(appState)`.** Rejected — `model` isn't
   in AppState, and AppState over-broadens every child's surface. `DetailContext`
   (exact consumed set) is the minimal honest edge. (C1)
2. **Merge `Transcript2Controller` + `Transcript2Coordinator`.** Rejected — NativeTranscript2
   §1.1 enumerates three load-bearing reasons (NSObject conformance vs `@Observable`,
   file size, real-logic-vs-forwarding boundary) and says "Don't merge."
3. **Convert the router's structural notification to `withObservationTracking`** (to
   match the window/sidebar async loops). Rejected — invariant I1: the swap must land
   in the click's source phase; async re-fragments it (bug #195).
4. **Fully-generic `CrossfadeController` that also owns teardown/observer flush.**
   Rejected — would leak the transcript's coordinator-shared-observer coupling (I5)
   into a shell helper. The helper owns the shape; each owner keeps its pre-flush. (C7)
5. **Collapse `Session` phase forwarders behind a protocol** (P9). Rejected — draft vs
   runtime surfaces diverge; a protocol fabricates runtime-only fields on the draft.
6. **Merge `ComposeSessionViewController` + `DraftSessionLandingViewController`** (they're
   ~90% identical). Rejected — the differences are real (draft-id allocation + resume vs
   re-bind + focus sweep + builtin commands). Only the host-mounting recipe is shared
   (C9); merging the VCs would entangle two genuinely different lifecycles.
7. **Fine-grained diff (insert/remove/move) for the sidebar** instead of `reloadData()`
   (S5.4). Rejected for this pass — the sidebar row count is bounded, there's no perf
   contract here, and `reloadData()` is invariant-safe (6.1 identity keying survives it).
   `SidebarTreeModel` makes a future diff *possible* without doing it speculatively now.
8. **SwiftUI-ify any spine node** (sidebar, transcript, window root). Rejected — each is
   a documented, measured AppKit exception (analysis §5.1); the §2 perf contract pins
   the transcript specifically.
9. **Extract streaming/typewriter or the whole `receive` path from `SessionRuntime`**
   (P8 maximalist). Rejected — too entangled with the synchronous fire + side-effect
   ordering (runtime-I1/I3). Only the self-contained projections come out (C11).

---

## 8. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| C6 transcript-swap extraction silently breaks the §2.19 single-width attach (the 2-3× typeset regression) | **High** | Land behind green `TranscriptReentryLayoutCacheTests` + `TranscriptHostReentryLayoutCacheTests`; do not `XCTSkip` or widen tolerance; read the per-stage offender report on any red. Do C6 LAST. |
| C7 shared crossfade drops the I5 `removeObserver` pre-flush, ripping observers off a re-entry (A→B→A) bind | **High** | Helper owns the shape ONLY; the pre-flush stays in `TranscriptSwapCoordinator.attach`, called before bind. Covered by the same host re-entry test. |
| C11 runtime projection extraction perturbs `onMessagesChange` synchronous fire or `receive` ordering | Med | Extract only projections that don't touch `receive` ordering; runtime stays the fire site. Guard with `SessionRuntime*` + bridge dispatch tests. |
| C10 shared grouping engine diverges live vs cold behavior | Med | Existing parity test is the gate; keep traversal per-direction, share only rules. |
| C5 `SidebarTreeModel` changes new-folder seeding (6.10) | Med | `previouslySeenGroups` is an explicit input; add a unit test (now possible) for "launch folders not treated as new." |
| C2 dead-edge deletion removes an env value some path actually reads | Low | Un-erasure (C3) turns any real reader into a compile error; grep already proved 0 readers. |
| C12 folding stores onto AppState changes init order / observation | Low | UserDefaults wrappers are construction-order-independent; `ModelStore` left `.shared`. |
| Doc drift after renames (C3/C13) | Low | Update the 4 CLAUDE.md references (`searchEngine`, `composeOrBarHost`, `.searchable`, `RootView2`, AppState `.environment`) in the same PRs. |

---

## 9. Functional-parity guarantee

No feature is removed or degraded; the design is structure-only. Concretely:

- **Selection / routing.** The selection spine is byte-identical: `select(_:)`
  writes the `@Observable` value + synchronously notifies the sole structural
  observer (router) in the click's source phase (I1); same-kind reuse (I3);
  `promote(to:)` re-fire on unchanged value (I6); phase-aware `isDraftSession`
  routing read fresh (I7/I9); deterministic `prepareForRemoval` teardown (I14).
  `DetailContext` only changes *how deps arrive*, never the flow.
- **Transcript.** Every §2 perf-contract item and the §2.19 attach contract are
  untouched — C6 *moves* the choreography into a coordinator with identical
  ordering; it does not weaken any item. The two merge-gate tests pin
  `present`'s end-to-end behavior. No SwiftUI is introduced into the transcript.
- **Render channels.** SwiftUI pull via `@Observable`, AppKit transcript via
  synchronous closure push, history via off-main backfill bypassing the bridge —
  all preserved (analysis §5.4). C10/C11 keep "one channel per piece of state."
- **Sidebar.** All 12 sidebar invariants (6.1–6.12) preserved: reference-type
  nodes, disclosure suppression, echo suppression, source-phase select, folder-only
  DnD clamps, per-row observation re-arm + recycle guard, non-allocating
  `existingSession`, title sanitization, shimmer locations, status precedence.
  C5 only relocates pure tree-building + menu plumbing.
- **Input bar / sends / builtins.** Handle-free leaf (input-bar I1), `.id(sid)`
  reset, imperative draft-clear (I12), builtin ordering (I11), draft→active
  promotion via `promote` (I10) — all unchanged. C4 routes one stop-task call
  through the façade (same effect, cleaner edge).
- **Host sizing.** The two-regime split ([] fill-pane vs `[.intrinsicContentSize]`
  component) is preserved exactly (I7/I8); un-erasure + the `mountFillPaneHost`
  helper change syntax, not sizing posture. No window-collapse risk introduced.
- **Lifecycle.** AppKit-rooted shell, window created in `applicationDidFinishLaunching`
  (I10), lazy non-restorable aux windows + `Settings { EmptyView() }` placeholder
  (I9), XCTest guards (I11), `nonisolated deinit {}` on every `@MainActor @Observable`/VC
  including any NEW type (`TranscriptSwapCoordinator`, `SidebarContextMenuController`,
  trackers) — all preserved.

Every behavior currently covered by a test stays covered; the splits (C5, C6, C10,
C11) *add* testable seams (pure tree model, isolated swap coordinator, shared
grouping engine, projection trackers) without changing any observable output.

---

## 10. Sequencing (lowest-risk → highest-value, mirrors analysis §6)

1. **C3, C13, C14** (renames, un-erasure, dead-code) — mechanical, test-safe.
2. **C1, C2** (`DetailContext` + `injectDetailEnvironment`, drop dead edges) — highest
   value, lowest risk; un-erasure (C3) must precede C2 so missing env = compile error.
3. **C4** (`stopBackgroundTask` forwarder) — one-liner, closes the flow violation.
4. **C8, C9** (`SessionPresentingChild`, `mountFillPaneHost`) — small shell cleanups.
5. **C5** (sidebar split) — extraction win, guarded by a NEW pure-model test.
6. **C10, C11** (grouping dedupe, runtime projections) — guarded by existing parity +
   runtime tests.
7. **C7 then C6** (crossfade helper, then transcript-swap coordinator) — riskiest;
   do LAST, behind green reentry-layout tests. C7 first so C6 reuses it.
8. **C12** (ownership reconcile) — anytime; mostly a doc + cheap fold.
```

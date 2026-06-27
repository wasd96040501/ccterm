# Survey: App shell, window assembly, selection & detail routing

Scope: `App/` (CCTermApp, AppState, TranscriptSearchBus, BuildInfo, AboutView) and
`App/AppKit/` (AppDelegate, MainWindowController, MainSplitViewController,
DetailRouterViewController, MainSelectionModel, MainSelection, SettingsWindowController,
AboutWindowController), plus `AppCommands` (defined inline in CCTermApp.swift).

All paths below are relative to
`/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm`.

FACT = present in the code. INFERENCE = my read.

---

## 1. Component / type inventory

| Type | Kind | One-line responsibility | file:line |
|---|---|---|---|
| `CCTermApp` | SwiftUI `App` (`@main`) | Entry point. Declares one `Settings { EmptyView() }` placeholder scene + `.commands { AppCommands(...) }`; `init()` does test-mode setup, watchdog, model prefetch. | `App/CCTermApp.swift:21` |
| `AppCommands` | SwiftUI `Commands` struct | Menu bar: About / Settings… (⌘,) / Find in Transcript (⌘F). Routes to `AppDelegate.show*Window()` and `searchBus.requestFocus()`. | `App/CCTermApp.swift:139` |
| `NSWindow` (extension) | AppKit extension | Test-only window-ordering swizzle (`suppressOrderingForTesting`, `ccterm_orderFrontForTesting`). | `App/CCTermApp.swift:79` |
| `AppDelegate` | `NSObject, NSApplicationDelegate` (`@MainActor`) | App-scope owner: constructs `AppState`, `TranscriptSearchBus`, `MainSelectionModel`; creates main window in `applicationDidFinishLaunching`; owns lazy Settings/About windows; parallel CLI shutdown. | `App/AppKit/AppDelegate.swift:29` |
| `AppState` | `@Observable @MainActor final class` | Process-scope service container: `sessionManager`, `syntaxEngine`, `recentProjects`, `inputDraftStore`, `sidebarGroupOrder`, `activationTracker`, `notificationService`, `openInService`. Wires turn-end / permission notices in init. | `App/AppState.swift:6` |
| `TranscriptSearchBus` | `@Observable @MainActor final class` | ⌘F focus command bus — a monotonic `focusRequestCounter`; `requestFocus()` bumps it. | `App/TranscriptSearchBus.swift:21` |
| `BuildInfo` | `enum` (namespace) | Reads `Info.plist`: marketing version, build number, git commit. | `App/BuildInfo.swift:3` |
| `AboutView` | SwiftUI `View` | Static About panel body (icon + version + commit). | `App/AboutView.swift:4` |
| `MainWindowController` | `NSWindowController, NSToolbarDelegate` (`@MainActor`) | Owns the main `NSWindow` + `NSToolbar` (toggle-sidebar, separator, project chip, archive filter, search). Observes `model.selection` to add/remove conditional toolbar items. | `App/AppKit/MainWindowController.swift:10` |
| `ArchiveFilterToolbarButton` | SwiftUI `View` (private) | Toolbar popover for archive folder filter; reads/writes `model.archiveSelectedFolderPath`. | `App/AppKit/MainWindowController.swift:299` |
| `TranscriptProjectChip` | SwiftUI `View` (private) | Toolbar leading chip: dirName + branch for the current `.session`. | `App/AppKit/MainWindowController.swift:337` |
| `TranscriptSearchToolbarBridge` | `NSObject, NSSearchFieldDelegate` (`@MainActor`) | Wires the toolbar `NSSearchField` → `TranscriptSearchBus` (⌘F focus) and → live session's `Transcript2Controller` (query / next / prev). | `App/AppKit/MainWindowController.swift:403` |
| `MainSplitViewController` | `NSSplitViewController` (`@MainActor`) | Two-item split: sidebar item (`SidebarViewController`) + detail item (`DetailRouterViewController`). Owns autosave + thickness. | `App/AppKit/MainSplitViewController.swift:10` |
| `DetailRouterViewController` | `NSViewController, MainSelectionObserver` (`@MainActor`) | Sole structural owner of the detail-side transition. Mounts exactly one child VC per selection; crossfades cross-kind swaps; owns launch-failure alert + notification→selection mapping. | `App/AppKit/DetailRouterViewController.swift:63` |
| `DetailRouterChild` | `protocol: NSViewController` (`@MainActor`) | `prepareForRemoval()` — deterministic per-session teardown on swap-out. | `App/AppKit/DetailRouterViewController.swift:13` |
| `DetailRouterViewController.ChildKind` | nested `enum: Equatable` | Routing kinds: transcript / compose / draftLanding / archive / demo. | `App/AppKit/DetailRouterViewController.swift:211` |
| `MainSelectionModel` | `@Observable @MainActor final class` | Shared selection/draft state: `selection`, `draftSessionId`, `archiveSelectedFolderPath`; `select(_:)`/`promote(to:)` mutators that synchronously notify the structural observer. | `App/AppKit/MainSelectionModel.swift:35` |
| `MainSelectionObserver` | `protocol: AnyObject` (`@MainActor`) | One method `selectionDidChange(to:)` — the synchronous structural hook. | `App/AppKit/MainSelectionModel.swift:19` |
| `MainSelection` | `enum: Equatable` | Typed selection: `.none` / `.newSession` / `.session(String)` / `.archive` / `.demo(DemoKind)` (DEBUG). | `App/AppKit/MainSelection.swift:18` |
| `DemoKind` | `enum: String, CaseIterable, Equatable` (DEBUG) | Stable identity for DEBUG demo tabs. | `App/AppKit/MainSelection.swift:42` |
| `SettingsWindowController` | `NSWindowController, NSToolbarDelegate` (`@MainActor`) | Lazy AppKit-rooted Settings window hosting `SettingsView` via `NSHostingController`; carries the `.sidebarTrackingSeparator` toolbar. | `App/AppKit/SettingsWindowController.swift:13` |
| `AboutWindowController` | `NSWindowController` (`@MainActor`) | Lazy AppKit-rooted About window hosting `AboutView` via `NSHostingController`. | `App/AppKit/AboutWindowController.swift:21` |

Child VCs the router constructs (out of strict scope but on the boundary):
`ChatSessionViewController` (`App/AppKit/ChatSessionViewController.swift:46`),
`ComposeSessionViewController` (`Content/Chat/ComposeSessionViewController.swift:28`),
`DraftSessionLandingViewController` (`Content/Chat/DraftSessionLandingViewController.swift:20`),
`ArchiveViewController` (`Content/Archive/ArchiveViewController.swift:15`).

---

## 2. Component tree (this area)

Legend: `[AK]` AppKit, `[SU]` SwiftUI, `<<HC>>` = `NSHostingController`, `<<HV>>` =
`NSHostingView`. `sizingOptions` noted where it's set.

```
CCTermApp [SU App] ............................................. App/CCTermApp.swift:21
├── @NSApplicationDelegateAdaptor → AppDelegate [AK] ........... App/AppKit/AppDelegate.swift:29
└── Scene: Settings { EmptyView() } [SU placeholder] .......... App/CCTermApp.swift:39
    └── .commands { AppCommands } [SU] ........................ App/CCTermApp.swift:139
        (menu items only — merged into NSMenu; not a window)

AppDelegate [AK]  (owns app-scope state)
├── appState: AppState [@Observable] .......................... App/AppState.swift:6
├── searchBus: TranscriptSearchBus [@Observable] .............. App/TranscriptSearchBus.swift:21
├── selectionModel: MainSelectionModel [@Observable] .......... App/AppKit/MainSelectionModel.swift:35
├── settingsWindowController?: SettingsWindowController [AK, lazy]
│   └── window.contentViewController = <<HC>> SettingsView [SU]  (default sizingOptions — sizes window)
├── aboutWindowController?: AboutWindowController [AK, lazy]
│   └── window.contentViewController = <<HC>> AboutView [SU]     (default sizingOptions — sizes window)
└── mainWindowController?: MainWindowController [AK] ........... App/AppKit/MainWindowController.swift:10
    ├── NSToolbar (delegate = self) ........................... :76
    │   ├── .toggleSidebar / .sidebarTrackingSeparator (system)
    │   ├── projectChip item → <<HV>> TranscriptProjectChip [SU]  sizingOptions=[.intrinsicContentSize] :253
    │   ├── archiveFilter item → <<HV>> ArchiveFilterToolbarButton [SU] sizingOptions=[.intrinsicContentSize] :280
    │   └── search item → NSSearchToolbarItem [AK] ........... :257
    │        └── searchField.delegate/target = TranscriptSearchToolbarBridge [AK] :403
    └── window.contentViewController = MainSplitViewController [AK] .. App/AppKit/MainSplitViewController.swift:10
        ├── sidebar item → SidebarViewController [AK, NSOutlineView] (out of scope)
        └── detail item → DetailRouterViewController [AK] ...... App/AppKit/DetailRouterViewController.swift:63
            view = NSVisualEffectView (.contentBackground) ...... :145
            └── exactly ONE currentChild (+ optional fadingOutChild during crossfade):
                ├── .transcript → ChatSessionViewController [AK]  (pinned 4-edge)
                │      ├── topScrim / bottomScrim [AK]
                │      ├── transcriptScroll: Transcript2ScrollView [AK]
                │      └── composeOrBarHost: <<HV>> AnyView(chat bar) [SU]  ([.intrinsicContentSize], bottom-anchored)
                ├── .compose → ComposeSessionViewController [AK]
                │      └── <<HC>> ComposeSessionView [SU]  sizingOptions=[] (pinned 4-edge)
                ├── .draftLanding → DraftSessionLandingViewController [AK]
                │      └── <<HC>> ... [SU]  (pinned 4-edge)
                ├── .archive → ArchiveViewController [AK]
                │      └── <<HC>> ArchiveView [SU]  sizingOptions=[] (pinned 4-edge)
                └── .demo(_) (DEBUG) → demo VC (one is <<HC>> with sizingOptions=[])  :437
```

INFERENCE: every detail child that *fills the pane* uses `sizingOptions = []` and pins all four
edges, matching the root CLAUDE.md "fill-a-pane → []" rule; the only `[.intrinsicContentSize]`
hosts in this area are the two toolbar items and the chat bar host (subordinate components).

---

## 3. Data flow

### 3a. State entry (what flows INTO this area)

- **Construction-time injection (one direction, downward).** `AppDelegate` constructs
  `AppState`, `TranscriptSearchBus`, `MainSelectionModel` (`AppDelegate.swift:30-34`) and
  passes `model`, `appState`, `searchBus` into `MainWindowController.init`
  (`AppDelegate.swift:78`). `MainWindowController` forwards the same three into
  `MainSplitViewController.init` (`MainWindowController.swift:33`), which **destructures
  `appState` into individual services** and passes a 7-tuple
  (`model, sessionManager, recentProjects, notifications, searchEngine, searchBus,
  inputDraftStore`) into `DetailRouterViewController.init` (`MainSplitViewController.swift:29`)
  and a 4-tuple into `SidebarViewController.init` (`MainSplitViewController.swift:23`).
- **AppState fans out, never reassembles.** `AppState` is **not** injected as a single object
  anywhere — `grep` for `.environment(appState` / `@Environment(AppState` returns nothing
  (FACT). Each leaf service is injected/passed individually. The router then re-injects the
  same 6 services into the SwiftUI environment of every child
  (`DetailRouterViewController.swift:430-435`, and identically in each child VC's
  `viewDidLoad`).

### 3b. Selection propagation (the core data flow of this area)

```
sidebar click / notification / submit
        │  (writes)
        ▼
MainSelectionModel.select(_:)  [MainSelectionModel.swift:53]
        │  1. selection = newSelection      (the @Observable write)
        │  2. selectionObserver?.selectionDidChange(to:)   ← SYNCHRONOUS, same source phase
        ├───────────────────────────────────────────────┐
        ▼ (async, beforeWaiting)                          ▼ (synchronous)
  SwiftUI content re-render               DetailRouterViewController.selectionDidChange [DRVC:454]
  (project chip, sidebar cells,                 → applySelection [DRVC:472]
   input bar visibility)                           ├ installChildForCurrentSelection(animated:) [DRVC:284]
        │                                          ├ view.layoutSubtreeIfNeeded()  (settle width)
        ▼                                          ├ child.present(sessionId:animated:)  (transcript / draftLanding)
  MainWindowController.startSelectionObservation   └ commitChildTransition()  (kick crossfade)
  [MWC:144] → updateProjectChipPresence /
              updateArchiveFilterPresence
        │
  SidebarViewController.startSelectionObservation
  [Sidebar:385] → applyModelSelection (reflect row highlight)
```

- **`selection` has TWO consumer channels by design (documented).** The `@Observable`
  `selection` is the single source of truth; `select(_:)` additionally fires the
  `selectionObserver` synchronously (`MainSelectionModel.swift:53-57`). The router is the
  **sole** structural observer; SwiftUI consumers + `MainWindowController` +
  `SidebarViewController` observe the `@Observable` field asynchronously (their own
  `withObservationTracking` re-arm loops). The doc comment
  (`MainSelectionModel.swift:4-21`, `MainSelection.swift` and the `MainSelectionObserver`
  comment) is explicit that the delegate is "strictly additive, never a second source of
  truth."
- **`promote(to:)` is a back-channel for the no-op case.** When a draft's selection value is
  unchanged after `.draft → .active` (`.session(sid)` before and after), `select(_:)` would
  no-op and never swap the VC. `promote(to:)` (`MainSelectionModel.swift:72-79`) fires the
  observer directly to force the router to re-read the (now `.active`) phase. Caller:
  `SessionInputSubmit.swift:65`.

### 3c. Event / mutation flow OUT of this area

- **Sidebar → model.** `SidebarViewController` writes selection via `model.select(...)`
  (`Sidebar/SidebarViewController.swift:480`, `:647`).
- **Compose / draft-landing → model + session.** `submitSessionInput`
  (`Content/Chat/SessionInputSubmit.swift`) promotes the draft, calls `session.send`, then
  `model.promote(to:)` + clears `model.draftSessionId` (`:65-66`). Compose resume:
  `model.select(.session(resumeSid))` (`ComposeSessionViewController.swift:96`).
- **Archive → model.** Unarchive calls `model.select(.session(resumeSid))`
  (`ArchiveViewController.swift:72`); folder filter is a two-way `Binding` onto
  `model.archiveSelectedFolderPath` (`ArchiveViewController.swift:63-66`), shared with the
  toolbar popover (`MainWindowController.swift:318-322`).
- **Notifications → model.** `notifications.onActivateSession` maps a banner click to
  `model.select(.session(sid))` — owned **once** by the router
  (`DetailRouterViewController.swift:162-164`).
- **App → CLI lifecycle.** `AppState.init` wires `sessionManager.onTurnEndedNotice` /
  `onPermissionPromptNotice` to `NotificationService` (`AppState.swift:28-38`);
  `AppDelegate.applicationShouldTerminate` drives parallel CLI shutdown
  (`AppDelegate.swift:110-119`).

### 3d. Search flow

- **⌘F focus.** `AppCommands` Find button → `searchBus.requestFocus()` bumps
  `focusRequestCounter` (`CCTermApp.swift:160`, `TranscriptSearchBus.swift:28`) →
  `TranscriptSearchToolbarBridge.startFocusObservation` observes the counter and calls
  `window.makeFirstResponder(field)` (`MainWindowController.swift:425-447`).
- **Query / nav.** Typing → `controlTextDidChange` → `controllerProvider()?.runSearch`
  (`MainWindowController.swift:454-457`). Return/Shift-Return → next/prev hit
  (`MainWindowController.swift:459-476`). `controllerProvider` resolves the live session's
  `Transcript2Controller` lazily via `model.effectiveSessionId` +
  `sessionManager.existingSession` (`MainWindowController.swift:196-204`) — **a pull, not a
  push**: the bridge re-reads the current session every keystroke rather than being
  re-bound on session swap.

### BIDIRECTIONAL / back-channel coupling (marked)

- **`MainSelectionModel.selectionObserver`** (`MainSelectionModel.swift:45`) — a `weak`
  back-reference from the model up to the router. The model is constructed by `AppDelegate`
  and threaded down; the router reaches *back up* to register itself
  (`DetailRouterViewController.swift:156`). INFERENCE: this is the one deliberate
  upward edge in the otherwise-downward graph; it is what makes the "synchronous structural
  notification" possible and is heavily justified in comments. Not a smell to remove, but it
  is the single bidirectional link a refactor must understand.
- **`model.archiveSelectedFolderPath`** is read/written from two places (toolbar popover +
  `ArchiveView` binding) — shared mutable state on the model, by design
  (`MainSelectionModel.swift:94-99` explains the toolbar can't host a SwiftUI `.toolbar{}`).
- **`MainWindowController.searchBridge.controllerProvider`** closes over `self.model` and
  `self.appState` (`MainWindowController.swift:196-204`) — the toolbar reaches into selection
  + session state to find the controller. Hidden coupling: the search field's behavior depends
  on `model.effectiveSessionId` even though the field is owned by the window, not the detail.

---

## 4. Ownership & lifetime

| Object | Constructed by | Retained by | Torn down |
|---|---|---|---|
| `AppDelegate` | `@NSApplicationDelegateAdaptor` in `CCTermApp` | the SwiftUI App runtime | process exit |
| `AppState`, `TranscriptSearchBus`, `MainSelectionModel` | `AppDelegate` stored-property initializers (`AppDelegate.swift:30-34`) | `AppDelegate` (strong `let`/`var`) | process exit |
| `MainWindowController` | `AppDelegate.applicationDidFinishLaunching` (`AppDelegate.swift:78`) | `AppDelegate.mainWindowController` (strong) | never (no close → terminate; `isReleasedWhenClosed=false`) |
| `NSWindow` (main) | `MainWindowController.init` (`:36`) | the window controller | with the controller |
| `MainSplitViewController` | `MainWindowController.init` (`:33`) | `window.contentViewController` + `splitController` let | with the window |
| `SidebarViewController` / `DetailRouterViewController` | `MainSplitViewController.init` (`:23`, `:29`) | split items (strong) | with the split |
| `NSToolbar` + items | `MainWindowController.installToolbar` (`:76`) | `window.toolbar`; conditional items inserted/removed imperatively (`:121`, `:167`) | conditional items removed on selection change; toolbar with window |
| `TranscriptSearchToolbarBridge` | `makeSearchBridgeIfNeeded` (`:192`), once | `MainWindowController.searchBridge` (strong) | with the window controller (cancels `focusObservationTask` in `deinit`, `:423`) |
| `searchToolbarItem` | toolbar delegate callback (`:257`) | `MainWindowController.searchToolbarItem` (strong) + toolbar | with toolbar |
| `currentChild` (detail child VC) | `DetailRouterViewController.makeChild` (`:363`) | `currentChild` strong + `addChild` containment | on cross-kind swap: `prepareForRemoval()` + `removeFromParent` (sync `:323-326` or crossfade completion `:354-361`) |
| `fadingOutChild` | parked in `installChildForCurrentSelection` (`:318`) | `fadingOutChild` (strong) | crossfade completion or flushed at next swap (`finishFadeOut`, `:354`) |
| `SettingsWindowController` / `AboutWindowController` | lazy in `AppDelegate.show*Window` (`:42-73`) | `AppDelegate` (strong, optional) | never auto-released (`isReleasedWhenClosed=false`, `isRestorable=false`); survive close→reopen |
| `AppState`'s services (`SessionManager`, `NotificationService`, …) | `AppState.init` (`:16-52`) | `AppState` (strong `let`) | process exit |

Key lifetime notes:
- **`MainSelectionModel.selectionObserver` is `weak`** (`MainSelectionModel.swift:45`) — the
  model outlives any single observer registration but never retains the router (router is
  retained by the split). The router sets it in `viewDidLoad` (`:156`) and never clears it
  (FACT — there's no `viewWillDisappear` cleanup), which is safe because the router has window
  lifetime.
- **`nonisolated deinit {}`** appears on `MainSelectionModel` (`:121`), `TranscriptSearchBus`
  (`:35`), `DetailRouterViewController` (`:69`), `ComposeSessionViewController` (`:32`),
  `DraftSessionLandingViewController` (`:24`), `ArchiveViewController` (`:19`) — the macOS-26
  `swift_task_deinitOnExecutorImpl` workaround. **`ChatSessionViewController` has a
  *non-empty* `nonisolated deinit`** (`ChatSessionViewController.swift:589`) that does real
  teardown — the asymmetry is intentional (it owns the transcript task).

---

## 5. Smells / debt

### S1 — The 7-argument dependency bundle, duplicated across 4 child VCs + the router. (MEDIUM)
Every detail child VC (`ChatSessionViewController.swift:124-141`,
`ComposeSessionViewController.swift:44-61`, `ArchiveViewController.swift:31-48`,
`DraftSessionLandingViewController.swift:~40-55`) and the router
(`DetailRouterViewController.swift:114-131`) declare the **identical** 7 stored properties +
identical `init(model:sessionManager:recentProjects:notifications:searchEngine:searchBus:
inputDraftStore:)`. `makeChild` (`DetailRouterViewController.swift:363-410`) repeats the same
7-arg call 4 times.
Why it's debt: this is `AppState` re-destructured then re-passed. Several children don't use
all 7 (e.g. `ArchiveViewController.viewDidLoad` ignores `searchEngine`/`searchBus`/
`notifications` for its own logic, only forwarding them to the environment). A change to the
dependency set means editing 5 files. INFERENCE: the cleanest unidirectional fix is a single
context value object (a `DetailContext`/`AppDependencies` struct carrying `model` + the 6
services) constructed once and passed whole — collapses 5 init signatures and the `makeChild`
fan-out to one. This does **not** require injecting `AppState` itself (the model is not part
of AppState), and keeps "views never construct services" intact.

### S2 — The 6-line `.environment(...)` re-injection block, copy-pasted 4× (+ demo). (MEDIUM)
`DetailRouterViewController.swift:430-435`, `ChatSessionViewController.swift:576-581`,
`ArchiveViewController.swift:75-80`, `ComposeSessionViewController.swift:100-105`,
`DraftSessionLandingViewController.swift:123-128` each apply the exact same six
`.environment(...)` modifiers. Drift risk: add a new app-scope service and you must touch all
5. INFERENCE: a single `View` extension (`.injectAppEnvironment(context)`) or a shared
`AnyView` wrapper would centralize it; pairs naturally with S1.

### S3 — Root CLAUDE.md claims "AppState ... injected through `.environment()`"; the code never injects AppState. (LOW, doc drift)
Root `CLAUDE.md` AppState section says AppState is "injected through `.environment()`". In
reality `AppState` is destructured in `MainSplitViewController` and only its *leaves* are
injected individually (no `.environment(appState)` anywhere — FACT, §3a). Either the doc or the
code lies; a refactor toward a single context object (S1) is an opportunity to make them agree.

### S4 — `TranscriptSearchBus` doc comment describes a SwiftUI `.searchable` design that no longer exists. (LOW, doc drift)
`TranscriptSearchBus.swift:5-11` says the field is "rendered by SwiftUI's `.searchable`
modifier in the window toolbar" and the focus state "lives on the toolbar's
`NSSearchToolbarItem`". The actual implementation is a pure-AppKit `NSSearchToolbarItem` +
`TranscriptSearchToolbarBridge` (`MainWindowController.swift:257-265`, `:403`). The
`.searchable` story is stale (the transcript NativeTranscript2 CLAUDE.md §6.5 already
describes the AppKit toolbar version). Misleads a refactor.

### S5 — Three independent `withObservationTracking` self-re-arming loops watching `model.selection`. (MEDIUM)
`MainWindowController.startSelectionObservation` (`:144-159`),
`SidebarViewController.startSelectionObservation` (`Sidebar:385-398`), and the per-session
`startRunningObservation` family all use the same hand-rolled
`withObservationTracking { … } onChange: { Task { cont.resume() } }` + recursive re-arm
pattern. Each is an async re-arm hop (one tick of latency, per the runloop model). The router
deliberately escapes this via the synchronous `selectionObserver`; the window/sidebar
intentionally stay async (they only need cosmetic updates). Smell: the pattern is duplicated
verbatim and is easy to get subtly wrong (cancel-on-deinit, weak-self). INFERENCE: a tiny
shared `observe(_:onChange:)` helper would dedupe without changing semantics. Do NOT convert
the *router's* path to this — that one must stay synchronous (invariant I1).

### S6 — `MainWindowController` is doing four unrelated jobs in one ~480-line file. (LOW)
`MainWindowController.swift` owns: window/frame lifecycle, the whole `NSToolbarDelegate`
implementation, two private SwiftUI toolbar views (`TranscriptProjectChip`,
`ArchiveFilterToolbarButton`), and the `TranscriptSearchToolbarBridge`. The two SwiftUI views
and the search bridge are logically separable (toolbar item factories vs. window controller).
Not urgent, but the file mixes AppKit window plumbing with SwiftUI view bodies.

### S7 — Project-chip presence uses remove-then-insert with a comment about NSToolbar not re-measuring; archive-filter uses a presence guard. Two slightly different idioms for "conditional toolbar item." (LOW)
`updateProjectChipPresence` (`:121-142`) always remove-then-(maybe)insert (to force
re-measure); `updateArchiveFilterPresence` (`:167-190`) early-returns when state matches
(`if shouldShow == (currentIndex != nil) { return }`). The divergence is justified by a real
NSToolbar measurement quirk for the chip, but the inconsistency is a readability cost — a
reader must notice the chip is intentionally not guarded.

### S8 — `model.effectiveSessionId` + `model.isComposeMode` are convenience derivations that partially duplicate the router's `resolvedChildKind` switch. (LOW)
`MainSelectionModel.effectiveSessionId` (`:126`) and `isComposeMode` (`:104`) switch over
`MainSelection`; `DetailRouterViewController.childKind`/`resolvedChildKind` (`:230`, `:257`)
switch over the same enum for routing; `MainWindowController.isHistorySession`/`isArchiveSelected`
(`:92-104`) do yet another switch. The selection→meaning mapping is decoded in ~4 places.
INFERENCE: not harmful (each derivation is small and answers a different question), but a
refactor toward unidirectional flow could consider whether some of these belong on
`MainSelection` itself as computed properties so the mapping lives in one type.

### S9 — `DraftSessionLandingViewController` and `ChatSessionViewController` both implement `present(sessionId:animated:)` but only the former conforms structurally to a "presentable" notion; there's no shared protocol. (LOW)
The router calls `(currentChild as? ChatSessionViewController)?.present(...)` and
`(currentChild as? DraftSessionLandingViewController)?.present(...)` in separate branches
(`DetailRouterViewController.swift:489-501`). Both have an identical `present` signature but no
common protocol, so the router downcasts to each concrete type. A `SessionPresentingChild`
protocol (sibling to `DetailRouterChild`) would let the router call `present` polymorphically
and drop one branch.

---

## 6. Load-bearing invariants (a refactor MUST preserve)

- **I1 — `select(_:)` notifies the structural observer SYNCHRONOUSLY, in the click's source
  phase.** `MainSelectionModel.swift:53-57` + `MainSelectionObserver` doc (`:4-17`). The detail
  swap + transcript mount must land in the same runloop iteration as the click; an async hop
  (e.g. converting the router to a `withObservationTracking` loop like the others) re-fragments
  the switch across frames. This is the whole point of the `selectionObserver` design. Tests:
  `DetailRouterContainmentTests`, `MainSelectionModelPromoteTests`.

- **I2 — There is always exactly ONE structural child attached to the router's `view`.** Router
  doc (`:60-61`) + `DetailRouterContainmentTests`. A crossfade may transiently mount a second
  (`fadingOutChild`) but it is always torn down (`finishFadeOut`). Refactors to the swap logic
  must keep this invariant and the deterministic `prepareForRemoval()` teardown.

- **I3 — Same-kind transitions REUSE the child VC; only cross-kind swaps tear down/rebuild.**
  `installChildForCurrentSelection` early-returns when `kind == currentKind`
  (`:286`); flipping between two history sessions keeps `ChatSessionViewController` alive and
  re-drives `present(sessionId:)`. Breaking this (rebuilding the transcript VC per session
  switch) destroys the O(1) warm re-entry and the §2.19 single-width attach guarantees.

- **I4 — The transcript attach must run against a SETTLED frame, one width per id.** The router
  runs `view.layoutSubtreeIfNeeded()` *before* `present` (`:486`) and gates the first attach on
  a framed `viewDidLayout` (`didInitialApply`, `:180-189`). This is the source-phase / §2.19
  contract from the NativeTranscript2 performance contract — LOAD-BEARING, do not weaken. Tests:
  `TranscriptHostReentryLayoutCacheTests`, `TranscriptReentryLayoutCacheTests`.

- **I5 — `ChatSessionViewController` does NOT observe `MainSelectionModel` for structure.**
  `ChatSessionViewController.swift:13-17`. The router is the sole structural owner; the chat VC
  is driven imperatively via `present`. Re-introducing a selection observer on the chat VC
  re-creates the two-async-observer race the refactor removed.

- **I6 — `promote(to:)` must re-fire the observer even when the selection value is unchanged.**
  `MainSelectionModel.swift:72-79` + `SessionInputSubmit.swift:65`. Draft → active promotion
  keeps `.session(sid)` identical; only `promote` forces the router to re-read the now-`.active`
  phase and swap `.draftLanding → .transcript`. A refactor that routes promotion through
  `select(_:)` would no-op and leave the landing page mounted. Test:
  `MainSelectionModelPromoteTests`, `DetailRouterDraftRoutingTests`.

- **I7 — Routing is phase-aware via `isDraftSession`, read FRESH every `applySelection`.**
  `resolvedChildKind` (`:257-264`) refines `.session` to `.draftLanding` when
  `sessionManager.isDraftSession(sid)` is true, and must use `isDraftSession` (not the cache-only
  `existingSession(_:)?.isDraft`) so a disk-restored draft still routes to the landing page. Never
  cache the resolved kind across the phase flip.

- **I8 — Fill-the-pane detail children use `sizingOptions = []` + 4-edge pin; subordinate hosts
  use `[.intrinsicContentSize]`.** Archive/compose/draft/permission-demo hosts
  (`ArchiveViewController.swift:102`, `ComposeSessionViewController.swift:115`,
  `DetailRouterViewController.swift:443`) vs. toolbar items + chat bar host. Violating this
  collapses the window (the long comment at `ArchiveViewController.swift:84-101` documents the
  exact failure). Root CLAUDE.md "Embedding SwiftUI in AppKit: host sizing".

- **I9 — Every window (main, Settings, About) is AppKit-rooted + lazy + non-restorable; the only
  SwiftUI scene is the `Settings { EmptyView() }` placeholder.** `CCTermApp.swift:4-49`,
  `AppDelegate.swift:42-73`, `Settings/AboutWindowController`. The placeholder exists *because*
  `Settings` is the only built-in scene that doesn't auto-open at launch; ⌘, is overridden so
  users never reach it. Re-introducing a real `Window` scene resurrects the "window pops up at
  launch / OS state-restores it" bugs (#219 chain). Auxiliary windows must stay
  `isReleasedWhenClosed=false` + `isRestorable=false`.

- **I10 — The main window is created in `applicationDidFinishLaunching`, not as a SwiftUI scene,
  so the transcript's mount + `frameDidChange` cascade runs in AppKit's source phase.**
  `AppDelegate.swift:75-83` + the doc comment. This is the foundational reason the whole shell
  is AppKit-rooted; do not move window creation back into a SwiftUI `WindowGroup`.

- **I11 — `XCTest` mode must skip all window creation + swizzle ordering selectors.**
  `CCTermApp.isUnderXCTest` (`:28`, `init` `:53-63`) + `AppDelegate.isUnderXCTest`
  (`:76`, `:111`, `:125`). Snapshot/AppKit tests need `NSApp` alive but no visible window. A
  refactor must keep both guards (they are independent — one in `CCTermApp.init`, one in the
  delegate).

- **I12 — `model.archiveSelectedFolderPath` is the single shared source of truth between the
  toolbar filter popover and `ArchiveView`.** `MainSelectionModel.swift:94-99`,
  `ArchiveViewController.swift:63-66`, `MainWindowController.swift:310-322`. The field lives on
  the model precisely because a SwiftUI `.toolbar{}` inside an `NSHostingController` child is
  silently dropped — don't move it back into `ArchiveView`'s local `@State`.

- **I13 — `nonisolated deinit {}` must remain on the `@MainActor @Observable` /
  `@MainActor NSViewController` types in this area** (`MainSelectionModel:121`,
  `TranscriptSearchBus:35`, `DetailRouterViewController:69`, and the three sibling child VCs).
  Removing it reintroduces the macOS-26 `swift_task_deinitOnExecutorImpl` abort under XCTest.
  Test: `MainSelectionModelDeinitTests`.

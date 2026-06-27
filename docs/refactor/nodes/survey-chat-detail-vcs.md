# Survey: Detail-side host VCs (chat / compose / draft-landing / archive)

Scope: the AppKit child view controllers the `DetailRouterViewController`
mounts in the detail pane, plus the shared free functions and SwiftUI bodies
they wire up. This file is the durable record for a refactor whose goal is
**cleaner, more unidirectional data flow with no functional degradation**.

Source root: `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f/macos/ccterm`

Files surveyed (all absolute):
- `App/AppKit/ChatSessionViewController.swift`
- `App/AppKit/DetailRouterViewController.swift` (the structural owner — drives all four child VCs)
- `App/AppKit/MainSelectionModel.swift`
- `App/AppKit/MainSelection.swift`
- `Content/Chat/ComposeSessionViewController.swift`
- `Content/Chat/DraftSessionLandingViewController.swift`
- `Content/Chat/SessionInputSubmit.swift`
- `Content/Chat/BuiltinSlashCommandHandler.swift`
- `Content/Chat/InputBarChrome.swift` (the SwiftUI bar bodies the chat/draft VCs host)
- `Components/TranscriptScrimView.swift` (the three scrim NSViews)
- `Content/Archive/ArchiveViewController.swift`
- `Content/Archive/ArchiveView.swift` (SwiftUI body; read for the binding/closure surface)

Convention: **FACT** = directly in the code at the cited line. **INFERENCE** =
my read. file:line is relative to the source root unless noted.

---

## 1. Component / type inventory

| Type | Kind | One-line responsibility | file:line |
|---|---|---|---|
| `ChatSessionViewController` | `NSViewController`, `DetailRouterChild` (AppKit) | Owns the transcript scroll view + scrims + bottom-anchored bar host; attaches a session imperatively via `present(sessionId:)`. Mounted for `.session(_)` (active) / `.none`. | `App/AppKit/ChatSessionViewController.swift:46` |
| `ChatComposeStack` | SwiftUI `View` | Bottom-anchored bar host's SwiftUI body. Routes `model.selection` → either a `ChatRestingBar` (for `.session(_)`) or `EmptyView`. Holds the pure static routing fn `content(for:draftSessionId:)`. | `App/AppKit/ChatSessionViewController.swift:605` |
| `ChatComposeStack.Content` | `enum` (`.none` / `.chat(sessionId:)`) | Routing decision value; `Equatable` so it's directly unit-testable. | `App/AppKit/ChatSessionViewController.swift:623` |
| `ComposeSessionViewController` | `NSViewController` (AppKit) | Full-pane VC for `.newSession`. Lazily allocates `model.draftSessionId`, seeds the draft cwd, hosts `ComposeSessionView` via `NSHostingController` (`sizingOptions = []`). | `Content/Chat/ComposeSessionViewController.swift:28` |
| `ComposeSessionView` | SwiftUI `View` | Compose card body: `DotGridBackground` + centered `NewSessionConfigurator` + embedded `InputBarChrome`. Binds the three configurator controls straight to `session.draft.config`. | `Content/Chat/ComposeSessionViewController.swift:160` |
| `ComposeSessionView.ComposeBindings` | private `struct` of `Binding`s | Carries the folder / useWorktree / sourceBranch bindings the configurator reads. | `Content/Chat/ComposeSessionViewController.swift:199` |
| `DraftSessionLandingViewController` | `NSViewController`, `DetailRouterChild` (AppKit) | Full-pane VC for a `.session(_)` whose `Session` is still `.draft` (a `/new`/`/clear` landing page). Re-bindable across draft→draft via `present(sessionId:)`; hosts `DraftSessionLandingView` (`NSHostingController`, `sizingOptions = []`). | `Content/Chat/DraftSessionLandingViewController.swift:20` |
| `DraftSessionLandingView` | SwiftUI `View` | Landing body: dot grid + hero ("Start Building <project>") + path + read-only branch pill + embedded draft `InputBarChrome`. | `Content/Chat/DraftSessionLandingViewController.swift:158` |
| `ArchiveViewController` | `NSViewController` (AppKit) | Full-pane VC for `.archive`. Hosts `ArchiveView` via `NSHostingController` (`sizingOptions = []`); bridges the folder filter through `model.archiveSelectedFolderPath`. | `Content/Archive/ArchiveViewController.swift:15` |
| `ArchiveView` | SwiftUI `View` | The archive list/grid body (out of primary scope; read for its closure surface `selectedFolderPath` binding + `onUnarchive`). | `Content/Archive/ArchiveView.swift` |
| `DetailRouterViewController` | `NSViewController`, `MainSelectionObserver` (AppKit) | The structural owner: mounts exactly one child VC per selection, drives the synchronous transition + crossfade, owns app→detail signals (notification activation, launch-failure alert). | `App/AppKit/DetailRouterViewController.swift:63` |
| `DetailRouterChild` | `@MainActor protocol: NSViewController` | Marks a child the router can ask to `prepareForRemoval()` (deterministic teardown). Conformed by `ChatSessionViewController` + `DraftSessionLandingViewController`. | `App/AppKit/DetailRouterViewController.swift:13` |
| `DetailRouterViewController.ChildKind` | `enum` (`.transcript` / `.compose` / `.draftLanding` / `.archive` / `.demo`) | The kind of child currently mounted; compared to decide same-kind reuse vs cross-kind swap. | `App/AppKit/DetailRouterViewController.swift:211` |
| `MainSelectionModel` | `@Observable` `@MainActor final class` (service/state) | Shared selection + draft + archive-filter state. `select(_:)` / `promote(to:)` mutate `selection` AND notify the structural observer synchronously. | `App/AppKit/MainSelectionModel.swift:35` |
| `MainSelectionObserver` | `@MainActor protocol: AnyObject` | The synchronous, source-phase selection-change hook the router registers as. | `App/AppKit/MainSelectionModel.swift:19` |
| `MainSelection` | `enum` (`.none` / `.newSession` / `.session(String)` / `.archive` / `.demo`) | Typed selection; replaces the old "stringly typed" `selectedSessionId: String?` + sentinels. | `App/AppKit/MainSelection.swift:18` |
| `DemoKind` | `enum: String` (DEBUG) | Stable identity for the demo tabs. | `App/AppKit/MainSelection.swift:42` |
| `submitSessionInput(_:sessionId:sessionManager:recentProjects:model:)` | free `@MainActor func` | Shared "user pressed send" handler for compose / draft-landing / chat. Promotes a draft on first send, composes mentions+images, flips selection via `promote(to:)`. | `Content/Chat/SessionInputSubmit.swift:16` |
| `runBuiltinSlashCommand(_:currentSessionId:sessionManager:model:)` | free `@MainActor func` | Shared `/new` + `/clear` dispatcher: create a seeded sidebar draft, (clear → archive source), select the new draft. | `Content/Chat/BuiltinSlashCommandHandler.swift:15` |
| `InputBarChrome` | SwiftUI `View` | Per-session wrapper around `InputBarView2` + `InputBarSessionChrome`. Resolves the `Session` to read `isRunning` / call `interrupt()`. Hosts the prewarm `.task`. | `Content/Chat/InputBarChrome.swift:12` |
| `ChatRestingBar` | SwiftUI `View` | Chat-mode resting input region: `InputBarChrome` + floating `PermissionCardView` in a `ZStack(alignment:.bottom)`. | `Content/Chat/InputBarChrome.swift:111` |
| `TranscriptScrimView` | `NSView` (AppKit, base) | Decorative top/bottom fade band; `hitTest` returns `nil` (passthrough). | `Components/TranscriptScrimView.swift:23` |
| `TranscriptBottomScrimView` | `NSView : TranscriptScrimView` (AppKit) | Bottom fade with even-odd cutouts at the attach button + pill; reads `attachRect` / `pillRect` pushed by the VC. | `Components/TranscriptScrimView.swift:110` |
| `TranscriptTopScrimView` | `NSView : TranscriptScrimView` (AppKit) | Top fade that ALSO intercepts mouse in its band to act as a title bar (`performDrag` / `performZoom`). NOT passthrough. | `Components/TranscriptScrimView.swift:171` |
| `BuiltinSlashCommand` | `enum: String` (`.new` / `.clear`) | The two builtin slash commands. | `Services/Completion/BuiltinSlashCommand.swift` |

External collaborators referenced (constructed elsewhere, injected in):
`SessionManager`, `Session`/`SessionRuntime`/`SessionDraft`, `Transcript2Controller`,
`Transcript2ScrollView`, `TranscriptScrollViewFactory`, `Transcript2SheetPresenter`,
`RecentProjectsStore`, `NotificationService`, `SyntaxHighlightEngine`,
`TranscriptSearchBus`, `InputDraftStore`.

---

## 2. Component tree (this area)

Hosting boundaries marked `[NSHostingController …]` / `[NSHostingView …]` with
`sizingOptions`. AppKit nodes prefixed `AK`, SwiftUI prefixed `SU`.

```
AK DetailRouterViewController                      (root NSVisualEffectView, .contentBackground)
│   owns exactly ONE child below at a time; swaps on selection
│
├── AK ChatSessionViewController            ← .session(_) (active) / .none
│   │   view = plain transparent NSView
│   ├── AK Transcript2ScrollView            (created per-attach by TranscriptScrollViewFactory; nil for .none)
│   │     └─ Transcript2ClipView → Transcript2TableView → BlockCellView  (see NativeTranscript2)
│   │   (a SECOND, outgoing Transcript2ScrollView is briefly mounted behind during a same-session crossfade)
│   ├── AK TranscriptTopScrimView           (full-bleed; INTERCEPTS mouse → title-bar drag/zoom)
│   ├── AK TranscriptBottomScrimView        (full-bleed; hitTest passthrough; attach/pill cutouts)
│   └── [NSHostingView<AnyView>  sizingOptions = [.intrinsicContentSize]]   ← composeOrBarHost
│         centerX + bottom-anchored, width ≤ maxHostWidth (component, content drives HEIGHT)
│         └── SU ChatComposeStack
│               └── SU ChatRestingBar  (.id(sid))    [only for .chat(sid); EmptyView otherwise]
│                     └── SU ZStack
│                           ├── SU InputBarChrome → InputBarView2 + InputBarSessionChrome
│                           └── SU PermissionCardView (conditional)
│
├── AK ComposeSessionViewController         ← .newSession
│   │   view = plain NSView
│   └── [NSHostingController<AnyView>  sizingOptions = []]   ← host (fill-pane, container drives size)
│         4-edge pinned
│         └── SU ComposeSessionView
│               └── SU ZStack(DotGridBackground, NewSessionConfigurator{ inputBar: InputBarChrome })
│
├── AK DraftSessionLandingViewController     ← .session(_) whose Session is .draft
│   │   view = plain NSView
│   └── [NSHostingController<AnyView>  sizingOptions = []]   ← host (re-mounted on draft→draft rebind)
│         4-edge pinned
│         └── SU DraftSessionLandingView
│               └── SU ZStack(DotGridBackground, VStack(hero, path, branchPill, InputBarChrome))
│
├── AK ArchiveViewController                 ← .archive
│   │   view = plain NSView
│   └── [NSHostingController<AnyView>  sizingOptions = []]   ← host (fill-pane)
│         4-edge pinned
│         └── SU ArchiveView (selectedFolderPath: Binding, onUnarchive: closure)
│
└── AK demo VCs (DEBUG)                       ← .demo(_)
      TranscriptDemoViewController / …Stress / …Perf / PermissionSessionDemoVC /
      [NSHostingController<PermissionCardsDemoView> sizingOptions = []]
```

**Boundary asymmetry worth noting (FACT):** the chat VC is the ONLY one that
hosts its SwiftUI via a bare `NSHostingView` with `[.intrinsicContentSize]`
(`ChatSessionViewController.swift:161,169`). Compose / draft-landing / archive /
permission-cards-demo all use `NSHostingController` with `sizingOptions = []`
and a 4-edge pin. The reason is structural, not stylistic: the chat bar is a
*subordinate component* over a transcript that already fills the pane (content
drives height), whereas the other three *are* their pane's content (container
drives size). This split is exactly the "fill-a-pane vs subordinate component"
rule in the root CLAUDE.md "host sizing" section, and is load-bearing
(see §6).

---

## 3. Data flow

### 3a. How state enters this area

The single structural input is **`MainSelectionModel.selection`** (typed
`MainSelection`). Production writes go through `select(_:)` /
`promote(to:)` (`MainSelectionModel.swift:53,72`), which do two things in one
source phase (FACT, `:55-56`):
1. write the `@Observable` `selection` (so SwiftUI consumers re-render at the
   next `beforeWaiting`), and
2. **synchronously** call `selectionObserver?.selectionDidChange(to:)` — the
   router, the sole structural observer.

The router resolves the kind (`resolvedChildKind(for:)`,
`DetailRouterViewController.swift:257`), swaps the child VC only on a cross-kind
change, settles the frame with `layoutSubtreeIfNeeded()` (`:486`), then hands
the child the session imperatively via `present(sessionId:)` (`:490`/`:499`).
So **selection → child VC → session attach is unidirectional and synchronous**;
the chat / draft-landing VCs do NOT observe the model for structure.

Secondary state injected into each child VC (FACT — same 7-field init on every
VC): `model`, `sessionManager`, `recentProjects`, `notifications`,
`searchEngine`, `searchBus`, `inputDraftStore`. All passed by initializer from
the router's `makeChild` (`:363-410`).

### 3b. How state propagates inside a chat attach

`ChatSessionViewController.present` → `attachSession`
(`ChatSessionViewController.swift:249,281`):
- `sessionManager.prepareDraftSession(sessionId)` → a `Session` (controller +
  bridge already wired) (`:291`).
- Build incoming `Transcript2ScrollView` (unbound), `addSubview` in front of the
  outgoing one, `layoutSubtreeIfNeeded`, `bindData`, `scrollToTail`, attach
  syntax engine, instantiate `Transcript2SheetPresenter`, `loadHistory`,
  `setLoading(isRunning)` (`:341-428`).
- Imperative pushes to the controller for the loading pill + turn usage:
  `setTurnUsage` / `setTurnStartedAt` once on mount, then live via the
  `session.onTurnUsageChange` closure (`:436-442`); `isRunning` via a
  `withObservationTracking` re-arm task `startRunningObservation`
  (`:525-541`).

State **read** by the SwiftUI bar bodies (pull, via `@Observable`, at
`beforeWaiting`): `session.isRunning`, `session.pendingPermissions`,
`session.cwd` / `additionalDirectories` / `pluginDirectories` /
`slashCommands` (`InputBarChrome.swift:55-76`, `ChatRestingBar.swift:143`).

### 3c. How events / mutations flow OUT

All outward flow is via **closures injected by the AppKit VC into the SwiftUI
body** (the project's explicit "no ViewModel" rule, Chat CLAUDE.md "Rules"):

- `ChatSessionViewController.makeComposeOrBarStack` wires four closures into
  `ChatComposeStack` (`ChatSessionViewController.swift:545-575`):
  - `onSubmit` → `submitSessionInput(...)`
  - `onAttachRect` → store `lastAttachRect`, call `applyScrimCutouts()`
  - `onPillRect` → store `lastPillRect`, call `applyScrimCutouts()`
  - `onBuiltinCommand` → `runBuiltinSlashCommand(...)`
- `ComposeSessionViewController` wires `onSubmit` → `submitSessionInput` and
  `onResumeSession` → `model.select(.session(resumeSid))` + clear draft
  (`ComposeSessionViewController.swift:85-99`).
- `DraftSessionLandingViewController` wires `onSubmit` → `submitSessionInput`
  and `onBuiltinCommand` → `runBuiltinSlashCommand`
  (`DraftSessionLandingViewController.swift:105-121`).
- `ArchiveViewController` wires `onUnarchive` → `model.select(.session(...))`
  and a two-way `selectedFolderPath` binding to `model.archiveSelectedFolderPath`
  (`ArchiveViewController.swift:63-74`).

`submitSessionInput` (`SessionInputSubmit.swift:16`): resolves the session,
detects first-start via `!session.hasRecord`, seeds cwd/originPath fallback,
calls `session.send(...)`, and on first start calls
`sessionManager.refreshRecords()` + `model.promote(to: sessionId)` +
`model.draftSessionId = nil` (`:56-67`). The mutation flows back into the SAME
selection model, which re-fires the router — closing the loop unidirectionally:
**bar → submitSessionInput → session.send + model.promote → router →
ChatSessionViewController.present**.

`runBuiltinSlashCommand` (`BuiltinSlashCommandHandler.swift:33-37`):
`createSidebarDraft(seededFrom:)` → optional `archive(source)` (clear only) →
`model.select(.session(draftId))`. Order is documented load-bearing (`:21-32`).

### 3d. Direction summary + back-channels

Predominantly **unidirectional**: `model.selection` → router → child VC →
session; events return through closures → `submitSessionInput` /
`runBuiltinSlashCommand` → `model.*` → router. Notable couplings:

- **BIDIRECTIONAL (by design):** `model.archiveSelectedFolderPath` —
  `ArchiveViewController` exposes a two-way `Binding` (`ArchiveViewController.swift:63-66`)
  AND the toolbar folder-filter button writes the same field
  (`MainSelectionModel.swift:96-99`). Two writers, one source of truth.
- **Hidden back-channel (FACT, documented):** the input bar clears the
  persisted draft **imperatively** inside `InputBarView2.handleSend`
  (`Content/Chat/InputBarView2.swift:470-472` — `draftStore.clear(key)`)
  *before* calling `onSubmit`, because `submitSessionInput`'s synchronous
  `model.promote` tears the SwiftUI body down in the same source phase, so the
  reactive `.onChange(of: text) → scheduleDraftSave` clear
  (`InputBarView2.swift:206`) would never fire. This couples the bar's send
  path to the selection model's synchronous teardown timing. It is correct but
  non-obvious and not local to this area.
- **Scrim cutout push (FACT):** `onAttachRect` / `onPillRect` flow from
  SwiftUI `GeometryReader` callbacks → VC stores `lastAttachRect`/`lastPillRect`
  → `applyScrimCutouts()` converts coords and writes
  `bottomScrim.attachRect` / `.pillRect` (`ChatSessionViewController.swift:231-234`).
  This is a SwiftUI→AppKit geometry feedback path with no Observation hop
  (intentional; rects are VC-local).
- **`session.controller.onFirstScreenReady` / `onTurnUsageChange`** are
  closures the VC installs on the controller/session per attach
  (`ChatSessionViewController.swift:420-442`); they're cleared/overwritten on
  the next attach (see §4 lifetime concern).

---

## 4. Ownership & lifetime

**Construction.** Every detail child VC is constructed exclusively by
`DetailRouterViewController.makeChild(for:)` (`DetailRouterViewController.swift:363-410`),
which forwards the 7 injected dependencies. The router itself is constructed by
`AppDelegate` / `MainSplitViewController` (one level up, per the root CLAUDE.md
ownership graph). No child VC constructs another, and no VC constructs a
service.

**Retention / single-child invariant (FACT).** The router holds at most one
live child in `currentChild` and the kind in `currentKind`
(`DetailRouterViewController.swift:85-89`), plus possibly one outgoing child
mid-crossfade in `fadingOutChild` (`:96`). On a cross-kind swap it adds the new
child, parks or tears down the old (`installChildForCurrentSelection`,
`:284-327`). `DetailRouterContainmentTests` pins "always exactly one child
attached to `view`."

**Teardown (FACT, deterministic).** Cross-kind swaps call
`(old as? DetailRouterChild)?.prepareForRemoval()` before
`removeFromSuperview()` + `removeFromParent()` (`:323-326`, `:354-361`). For
`ChatSessionViewController`, `prepareForRemoval` → `tearDownTranscript`
(`ChatSessionViewController.swift:263-265,508-523`) dismantles the scroll view,
stops the sheet presenter, cancels the running-observation task, and flushes any
parked crossfade scroll. `DraftSessionLandingViewController.prepareForRemoval`
is a no-op (`DraftSessionLandingViewController.swift:69`) — its hosted SwiftUI
tree releases with the VC. `ComposeSessionViewController` / `ArchiveViewController`
do NOT conform to `DetailRouterChild`, so they get plain
`removeFromSuperview` + ARC teardown.

**Per-attach lifetimes inside ChatSessionViewController.** These are re-created
on every session swap (FACT): `transcriptScroll` (`:79`), `currentSession`
(`:75`), `transcriptSheetPresenter` (`:86`, stopped + reinstantiated at
`:401-403`), `runningObservationTask` (`:105`, re-armed at `:445`). The three
scrims + the bar host are created once in `loadView` and live for the VC's
lifetime (`:153-170`).

**Draft-id ownership.** `model.draftSessionId` is allocated lazily by
`ComposeSessionViewController.ensureDraftSession()`
(`ComposeSessionViewController.swift:135-146`), and cleared in
`submitSessionInput` after promotion (`SessionInputSubmit.swift:66`) and in the
compose `onResumeSession` closure (`ComposeSessionViewController.swift:97`).
`DraftSessionLandingViewController` does NOT allocate it — it binds the id the
router hands it via `present(sessionId:)` and stores it in `boundSessionId`
(`DraftSessionLandingViewController.swift:37,76-82`).

**Deinit hygiene (FACT).** Every VC + the scrims + `MainSelectionModel` +
`DetailRouterViewController` declare `nonisolated deinit` to dodge the macOS 26
`swift_task_deinitOnExecutorImpl` XCTest abort
(e.g. `ChatSessionViewController.swift:589`,
`DetailRouterViewController.swift:69`, `MainSelectionModel.swift:121`,
`TranscriptScrimView.swift:27,113`). `ChatSessionViewController.deinit` also
cancels `runningObservationTask` (`:589-591`).

---

## 5. Smells / debt

### S1. Seven-field dependency bundle copy-pasted into five VCs — MEDIUM
Every detail child VC declares the identical 7 stored properties + identical
init + identical `@available init?(coder:)` boilerplate:
`ChatSessionViewController.swift:65-141`,
`ComposeSessionViewController.swift:34-64`,
`DraftSessionLandingViewController.swift:26-60`,
`ArchiveViewController.swift:21-51`, and the router itself
`DetailRouterViewController.swift:71-131`. The router's `makeChild`
(`:363-404`) repeats the same 7-arg call site four times.
**Why it's debt:** adding/removing one app-scope dependency is a 5-site edit
plus the `makeChild` switch. A `DetailChildDependencies` struct (or passing the
whole `AppState`) would make the wiring a single value threaded through
`makeChild`, and would be a clean unidirectional improvement with zero behavior
change. (`ArchiveViewController` doesn't actually use `recentProjects` /
`notifications` / `searchBus` for anything but environment injection — the
bundle is over-broad for some children — INFERENCE from reading its `viewDidLoad`.)

### S2. The environment-injection block is duplicated verbatim — MEDIUM
The six-line `.environment(sessionManager) … .environment(notifications)` chain
appears identically in `ChatSessionViewController.makeComposeOrBarStack`
(`:576-581`), `ComposeSessionViewController.viewDidLoad` (`:100-105`),
`DraftSessionLandingViewController.mountHost` (`:123-128`),
`ArchiveViewController.viewDidLoad` (`:75-80`), and the demo branch
(`DetailRouterViewController.swift:430-435`). Five copies of the same injection
list. **Why it's debt:** a new app-scope environment value is a 5-site edit and
easy to miss one (a missed injection is a runtime `@Environment` crash, not a
compile error). A shared `func injectAppEnvironment<V: View>(_:) -> some View`
helper would centralize it. Tightly coupled to S1.

### S3. `prepareDraftSession(sessionId)` is called as a render-time side door — LOW/MEDIUM
The SwiftUI bodies resolve the `Session` by calling
`manager.prepareDraftSession(sessionId)` *inside* `body` /
computed properties: `ComposeSessionView.body:168`,
`DraftSessionLandingView.body:166` and `:251`,
`InputBarChrome.session:33-35`, `ChatRestingBar.body:125`. It's idempotent
get-or-create and documented as "pure in-memory" (`InputBarChrome.swift:31-32`),
so it's not a correctness bug, but it's a `body`-path call that *can mutate the
manager's `sessions` dict* on first call (`SessionManager.swift:217-237`
inserts into `sessions[sessionId]`). **Why it's debt:** the project rule "No
expensive work / no side effects from the body construction path" (root
CLAUDE.md SwiftUI rules) is technically grazed here — a `body` that allocates +
caches a `Session` on first render is a side effect, even if benign. It also
means the *same* session is re-resolved at several layers per render. A cleaner
shape passes the resolved `Session` down once. INFERENCE: low risk today
because the VC already holds the same instance, but it blurs "who creates the
session."

### S4. Two near-identical full-pane-hosting VCs (Compose vs DraftLanding) — LOW
`ComposeSessionViewController` and `DraftSessionLandingViewController` are
~90% structurally identical: same fields, same `loadView`, same
`NSHostingController + sizingOptions=[] + 4-edge pin`, same focus sweep.
`ComposeSessionViewController.viewDidLoad:108-125` and
`DraftSessionLandingViewController.mountHost:131-146` are almost line-for-line.
The differences are real (compose allocates the draft id + has resume; landing
re-binds across ids + has a focus sweep + builtin commands), so merging them is
**not** clearly worth it, but the host-mounting boilerplate
(`NSHostingController` + `sizingOptions=[]` + pin-4-edges) is a candidate for a
tiny shared helper (`mountFillPaneHost(_:in:)`) reused by all three full-pane
VCs incl. `ArchiveViewController`. **Why it's debt:** three copies of the exact
same "fill-pane host" recipe with three multi-line rationale comments.

### S5. `updateFocus` duplicated across chat + draft-landing — LOW
`ChatSessionViewController.updateFocus(activeSessionId:)` (`:270-277`) and
`DraftSessionLandingViewController.updateFocus(activeSessionId:)` (`:91-96`)
implement the same defocus-everyone-else-then-focus-active sweep with a slightly
different signature (`String?` vs `String`). **Why it's debt:** the unread-clear
invariant lives in two places; a change to focus semantics must touch both.
Candidate for a `SessionManager` method (`setFocusedSession(_:)`) so the sweep
is owned where the records are.

### S6. Two parallel crossfade state machines — MEDIUM
`DetailRouterViewController` runs a cross-kind crossfade
(`fadingOutChild` + `commitChildTransition` + `finishFadeOut`,
`:96-104,336-361`) and `ChatSessionViewController` runs a *same-session*
transcript crossfade (`fadingOutTranscript` + `crossfadeTranscriptSwap` +
`finishTranscriptFadeOut`, `:113-122,476-506`). They share the same shape
(park outgoing, flush-on-next-swap guard, `expected` late-completion guard,
0.18s duration) but are two independent implementations with two duplicated
`childCrossfadeDuration` / `transcriptCrossfadeDuration` constants (`:104`
and `:122`). **Why it's debt:** the crossfade "park + flush + guarded-completion"
algorithm is non-trivial and now exists twice; a regression fix to one won't
propagate to the other. Note: extracting this is delicate — the transcript one
has the load-bearing `removeObserver` flush ordering (`:296-306`), so any shared
abstraction must preserve that exactly (see I6).

### S7. `composeOrBarHost` naming is stale — LOW
`ChatSessionViewController.composeOrBarHost` (`:94`,
`makeComposeOrBarStack:545`) is named for a capability it no longer has:
since compose moved to its own VC, this host *only* ever shows the chat
resting bar (or `EmptyView`). The class doc (`:13-28`) even says so. **Why it's
debt:** the name implies a morphing host that the architecture deliberately
deleted; a future reader may think the "compose" path still flows through here.
Rename to `barHost` / `restingBarHost`. Pure rename.

### S8. Scrim type name vs. property type mismatch in docs/usage — LOW
The base class is `TranscriptScrimView` (`TranscriptScrimView.swift:23`) but the
chat VC uses the subclasses `TranscriptTopScrimView` / `TranscriptBottomScrimView`
(`ChatSessionViewController.swift:92-93`). The Chat CLAUDE.md (and the VC's own
class doc at `:33`) still refer to the top scrim as `TranscriptScrimView`. Minor
doc drift; not a code bug. **Why it's debt:** the top scrim is the one node that
*breaks* the "scrim = passthrough" mental model (it intercepts mouse for title-bar
behavior, `:178-191`), so getting its name right in docs matters.

### S9. `ChatSessionViewController` is large and multi-concern — MEDIUM
At ~680 lines (`ChatSessionViewController.swift`) the VC owns: scrim geometry,
the bar host, the transcript attach pipeline, the same-session crossfade, the
sheet presenter lifecycle, focus, the running-observation task, turn-usage
plumbing, and telemetry logging. The transcript-swap machinery
(`attachSession` + `crossfadeTranscriptSwap` + `finishTranscriptFadeOut`,
`:281-506`) is ~225 lines and is the densest, most invariant-laden region.
**Why it's debt:** the single VC mixes "what to show" (selection-driven host)
with "how to swap a transcript" (a stateful animation/observer choreography).
Splitting the transcript-swap state machine into its own small owner
(e.g. `TranscriptSwapCoordinator`) would let the VC read top-to-bottom. INFERENCE:
this is the highest-value structural cleanup in the area, but also the riskiest
(it touches the §2.19 attach contract and the observer-flush ordering); it must
preserve every invariant in §6.

### S10. Compose card resolves the same `Session` twice with different sources — LOW
`ComposeSessionViewController.viewDidLoad` resolves the draft via
`sessionManager.prepareDraftSession(sid).draft` to seed cwd (`:140-141`), then
passes only the *id* to `ComposeSessionView`, which re-resolves via
`@Environment(SessionManager.self)` (`ComposeSessionView.body:168`). Two
resolution paths to the same instance. The doc explains why the id (not the
model field) is passed (`:73-80`) — that part is correct — but the double
resolve is incidental. INFERENCE: harmless (idempotent), listed for completeness.

---

## 6. Load-bearing invariants (a refactor MUST preserve)

### I1. Selection mutation is synchronous + single-observer (root CLAUDE.md runloop model)
`MainSelectionModel.select(_:)` MUST write `selection` then synchronously call
`selectionObserver?.selectionDidChange` in the same source phase
(`MainSelectionModel.swift:53-57`). The router is the **sole** structural
observer (`DetailRouterViewController.swift:156`); the chat VC must NOT observe
selection. Reverting to async `withObservationTracking` for structure
re-introduces the cross-tick fragmentation bug that #195 fixed
(`MainSelection.swift:6-17`). A refactor must keep "click → child swap →
transcript mount" in one runloop iteration.

### I2. §2.19 single-width attach contract (NativeTranscript2 CLAUDE.md §2.19 — perf, user-confirm to weaken)
`present` → `attachSession` MUST run, in order:
`factory.make` (unbound) → `addSubview` + constraints → `view.layoutSubtreeIfNeeded()`
→ `factory.bindData` → `controller.scrollToTail()`
(`ChatSessionViewController.swift:341-386`). The router MUST settle the child
frame (`layoutSubtreeIfNeeded`, `DetailRouterViewController.swift:486`) BEFORE
calling `present`. Reordering `bindData` before the layout pass, dropping the
layout pass, or inserting any extra `scrollToTail`/tile trigger before settle
causes multi-width typesetting. Guarded by `TranscriptReentryLayoutCacheTests`
+ `TranscriptHostReentryLayoutCacheTests` (the latter drives
`ChatSessionViewController.present` end-to-end).

### I3. Crossfade structural work stays synchronous; only opacity defers
The build→settle→bind→`scrollToTail` attach MUST run inside the
disabled-animation `CATransaction` / `NSAnimationContext` block
(`ChatSessionViewController.swift:335-339,458-459`) so it's atomic and
single-width; the alpha animation MUST run OUTSIDE that block
(`crossfadeTranscriptSwap`, `:476-492`; router's `commitChildTransition`,
`:336-347`). The disabled transaction must NOT wrap the fade or the opacity
animation is suppressed (`:332-334` comment). Same split applies to the router's
cross-kind crossfade.

### I4. Build-in-front-then-drop ordering (no blank-pane flash)
The incoming transcript MUST be built, mounted in front of the still-mounted
outgoing scroll, made live (typeset + bound + scrolled), and only THEN is the
outgoing one dismantled (`ChatSessionViewController.swift:320-321,452-456`).
Likewise the router mounts the incoming child ON TOP of the outgoing one
(`DetailRouterViewController.swift:303` comment + default z-order). Reordering to
teardown-then-build re-introduces the blank-pane flash this replaced.

### I5. Outgoing-scroll flush BEFORE bind on re-entry (A→B→A) — observer correctness
`attachSession` MUST call `finishTranscriptFadeOut()` synchronously at its head
(`ChatSessionViewController.swift:306`), BEFORE the new `bindData`, because
`TranscriptScrollViewFactory.dismantle` does a blanket
`removeObserver(coordinator)` — a parked outgoing scroll for the SAME session
shares the coordinator, so deferring its teardown would rip the freshly-bound
incoming scroll's frameDidChange/liveScroll observers off. Documented at length
`:296-306`. Any extracted swap coordinator (S6/S9) must preserve this exact
ordering.

### I6. `present` runs only on a mounted, framed VC
`attachSession` asserts `view.bounds.width/height > 0`
(`ChatSessionViewController.swift:286-289`); the router guarantees this by
deferring the very first `applySelection` to the first framed `viewDidLayout`
(`DetailRouterViewController.swift:112,180-189`) and settling the frame before
every subsequent `present`. A refactor must not call `present`/attach before the
host is framed.

### I7. Host sizing posture per pane (root CLAUDE.md "host sizing" — window-collapse risk)
The chat bar host MUST be `[.intrinsicContentSize]` + centerX/bottom-anchored
(component; content drives height) (`ChatSessionViewController.swift:169,202-207`).
The four full-pane hosts (compose, draft-landing, archive, permission-cards demo)
MUST be `sizingOptions = []` + 4-edge pinned (container drives size)
(`ComposeSessionViewController.swift:115-124`,
`DraftSessionLandingViewController.swift:136-145`,
`ArchiveViewController.swift:102-111`,
`DetailRouterViewController.swift:443`). Flipping either collapses the window
(the Archive `host.view.fittingSize ≈ 545×276` leak is documented at
`ArchiveViewController.swift:84-101`).

### I8. Scrim hitTest semantics (functional)
The bottom scrim + base scrim MUST return `nil` from `hitTest`
(`TranscriptScrimView.swift:61`) so the transcript below keeps clicks + cursor
rects. The top scrim MUST intercept its band and route to
`performDrag`/`performZoom` (`TranscriptScrimView.swift:178-191`). The bar host
MUST stay only as tall as the bar (`[.intrinsicContentSize]`) so it doesn't
shadow the transcript — this is what fixed the "input bar swallows transcript
clicks" bug (`ChatSessionViewController.swift:163-169`,
`ChatComposeStackRoutingTests`). `ChatComposeStack.content` MUST return `.none`
for everything except `.session(_)` (`ChatSessionViewController.swift:628-639`)
so no input chrome floats over archive/compose/demo pages
(`ChatComposeStackRoutingTests`, regression for #222).

### I9. Draft routing reads the durable status, not just the cache
`resolvedChildKind` MUST use `sessionManager.isDraftSession(sid)`
(`DetailRouterViewController.swift:258-263`), which falls back to the repository
status (`SessionManager.swift:199-202`), NOT the cache-only
`existingSession?.isDraft`. Otherwise a `.draft` row restored after a cold
restart falls through to the transcript VC. Guarded by
`DetailRouterDraftRoutingTests.test_uncachedDraftRow_afterRestart_mountsLandingVC`.

### I10. Draft promotion re-routes in place via `promote` (not `select`)
On first send of a draft that is ALREADY the current selection,
`submitSessionInput` MUST call `model.promote(to:)` (not `select`)
(`SessionInputSubmit.swift:60-66`) because the selection VALUE is unchanged
(`.session(id)` both before and after), so `select` would no-op and the live
transcript would never mount. `promote` fires the observer directly when the
value matches (`MainSelectionModel.swift:72-79`). Guarded by
`DetailRouterDraftRoutingTests.test_draftPromotion_swapsLandingForTranscript`
and `MainSelectionModelPromoteTests`.

### I11. Builtin-command ordering (create draft → archive source → select)
`runBuiltinSlashCommand` MUST create the seeded draft FIRST (while the source
session is still live), THEN archive the source (clear only), THEN select the
new draft (`BuiltinSlashCommandHandler.swift:21-37`). Reordering races the
source CLI teardown / worktree removal. Guarded by `BuiltinSlashCommandTests`.

### I12. Draft-clear is imperative in the input bar (teardown-proof)
`InputBarView2.handleSend` MUST clear the persisted draft directly
(`draftStore.clear(key)`) before calling `onSubmit`
(`InputBarView2.swift:467-473`) — the synchronous `model.promote` teardown
(I1/I10) prevents the reactive `.onChange → scheduleDraftSave` clear from
firing. If a refactor makes the send path reactive again, the draft survives
the send (reappears on next New Session).

### I13. Compose card captures the draft id by value, not reactively
`ComposeSessionViewController` MUST pass `draftSessionId` as a plain value
captured at `viewDidLoad`, NOT read `model.draftSessionId` reactively
(`ComposeSessionViewController.swift:73-80`) — on submit, `draftSessionId` is
niled in the same source phase, and a reactive read would blank the configurator
for one tick before the router swaps the VC out.

### I14. Deterministic teardown via `prepareForRemoval`
Cross-kind swaps MUST call `prepareForRemoval()` on outgoing
`DetailRouterChild`s before removal (`DetailRouterViewController.swift:323,358`)
so the transcript scroll / sheet presenter / running task release at swap time,
not at ARC's discretion. A refactor that drops the protocol call leaks the
per-attach resources (the leak this protocol was introduced to fix —
`DetailRouterViewController.swift:5-15`).

---

## Appendix: relationship to MainSelectionModel / router (quick map)

- `MainSelectionModel` is the one shared mutable state node; it has exactly one
  structural consumer (`selectionObserver` = router, set at
  `DetailRouterViewController.swift:156`) and N content consumers (SwiftUI bars,
  sidebar cells) that observe `selection` reactively.
- The router is the *only* type in this area that constructs child VCs and the
  *only* `MainSelectionObserver`. Every child VC is a leaf w.r.t. structure:
  it reacts to imperative `present(...)` calls and emits events through
  injected closures, never reads/writes the router and never observes selection
  for structure.
- The two free functions (`submitSessionInput`, `runBuiltinSlashCommand`) are
  the shared "write back to the model" sinks; centralizing them is what keeps
  the compose / draft-landing / chat send + builtin paths from drifting (their
  own doc comments state this explicitly).

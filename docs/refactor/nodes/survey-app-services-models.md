# Survey: App-scope services, models, and reusable components

Scope: `Services/` (app-scope services + config stores + logging), `Models/`,
`Components/` (incl. `Components/Markdown/`), `Extensions/`. Focus: which
services are app-scope vs feature-scope, how they are injected, the Markdown
parser→IR boundary, and any UI↔service back-channels. Session-runtime internals
(`Services/Session/Session/*`, `SessionRuntime*`, the transcript renderer) are
out of scope and covered by their own surveys; they appear here only where
app-scope services touch them.

FACT = verified in source. INFERENCE = my read. file:line cited throughout.

---

## 1. Component / type inventory

### 1a. AppState container (the app-scope hub)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `AppState` | `@Observable @MainActor final class` | Process-scope container; constructs + owns every app-scope service; wires `SessionManager` notices → `NotificationService`; kicks eager preloads | `App/AppState.swift:6` |
| `AppDelegate` | `@MainActor NSObject, NSApplicationDelegate` | Owns `AppState`, `searchBus`, `selectionModel`, main/Settings/About windows; app lifecycle | `App/AppKit/AppDelegate.swift:29` |

### 1b. App-scope services (constructed by / held on `AppState`)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `SessionManager` | `@Observable @MainActor final class` | Session registry; emits `onTurnEndedNotice` / `onPermissionPromptNotice` push callbacks (consumed by `AppState`→`NotificationService`) | `App/AppState.swift:7`, `Services/Session/SessionManager.swift:15` (out-of-scope internals) |
| `SyntaxHighlightEngine` | `actor` | JSCore/highlight.js tokenizer with LRU cache + same-tick coalescing batch; `EnvironmentKey` `\.syntaxEngine` | `Services/SyntaxHighlightEngine.swift:4` |
| `RecentProjectsStore` | `@Observable @MainActor final class` | UserDefaults-backed recent project folders + lastLaunched + per-project worktree pref; **lazy** load on first read | `Services/RecentProjectsStore.swift:30` |
| `InputDraftStore` | `@Observable @MainActor final class` | Per-session input-bar draft, file-backed, debounced off-main writes | `Services/Draft/InputDraftStore.swift:12` |
| `SidebarSessionGroupOrderStore` | `@MainActor final class` (NOT `@Observable`) | UserDefaults source of truth for sidebar folder-group ordering | `Sidebar/SidebarSessionGroupOrderStore.swift:21` |
| `AppActivationTracker` | `@Observable @MainActor final class` | Tracks `isAppActive` from `NSApplication.didBecome/ResignActive` | `Services/Notifications/AppActivationTracker.swift:15` |
| `NotificationService` | `@Observable @MainActor final class : NSObject, UNUserNotificationCenterDelegate` | Posts turn-end / permission banners; routes banner clicks back via `onActivateSession` push callback | `Services/Notifications/NotificationService.swift:23` |
| `OpenInAppService` | `@Observable @MainActor final class` | LaunchServices probe of "Open in …" target apps for sidebar context menu | `Services/OpenInAppService.swift:22` |

### 1c. Global singletons (`.shared`) — NOT on AppState

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `ModelStore` | `@Observable @MainActor final class`, `static let shared` | In-memory CLI model catalog (`[ModelInfo]`) + 1M extended-context extras; refreshed every launch | `Services/ModelStore.swift:12`, `.shared` at `:13` |
| `EffortDefaultStore` | `@MainActor final class`, `static let shared` | UserDefaults per-model effort memory | `Services/EffortDefaultStore.swift:24`, `.shared` at `:25` |
| `NewSessionDefaultsStore` | `@MainActor final class`, `static let shared` | UserDefaults last-used model + permission mode for a fresh New Session card | `Services/NewSessionDefaultsStore.swift:18`, `.shared` at `:19` |

### 1d. Feature-scope services (view-owned / not app-scope)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `GitProbe` | `@Observable final class` (no `@MainActor` annotation) | Lazily-loaded git info (branches / current / remote main / status) for one folder; cheap sync `refresh` + heavy async `loadHeavy` | `Services/GitProbe.swift:25` |
| `TranscriptSearchBus` | `@Observable @MainActor final class` | App-scope-ish ⌘F focus bump counter; owned by `AppDelegate`, not `AppState` | `App/TranscriptSearchBus.swift:21` |
| `ClaudeCodeStats` | `enum` (pure static functions) | Aggregates Claude Code on-disk session stats. **No production consumer** (tests only) | `Services/ClaudeCodeStats.swift:23` |

### 1e. Logging (stateless / process-global)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `appLog(_:_:_)` | free function | Thread-safe `os.Logger` wrapper; `LogLevel` enum | `Services/Logging/AppLogger.swift:24`, `LogLevel` at `:4` |
| `MainThreadWatchdog` | `enum` (static) | 50ms main-thread stall detector; `start()` once at launch | `Services/Logging/MainThreadWatchdog.swift:13` |
| `Transcript2PerfLog` | `enum` (static, `nonisolated(unsafe) var enabled`) | Toggleable hot-path trace; demo-only; `#if DEBUG`-fenced call sites | `Services/Logging/Transcript2PerfLog.swift:19` |

### 1f. Models (`Models/`) — plain value types / static helpers

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `SyntaxToken` | `struct` | `(text, scope?)` token from the highlighter | `Models/SyntaxToken.swift:1` |
| `SyntaxTheme` | `enum` (static) | hljs scope → SwiftUI `Color` (Xcode Default theme) | `Models/SyntaxTheme.swift:35` |
| `PermissionMode` | `enum: String, CaseIterable` | CLI permission mode + display titles + `toSDK()` | `Models/PermissionMode.swift:4` |
| `PermissionMode+Color` | `extension` (SwiftUI) | `triggerTint: Color` per mode | `Models/PermissionMode+Color.swift:4` |
| `Effort+Display` | `extension AgentSDK.Effort` | `.title` labels | `Models/Effort+Display.swift:4` |
| `SendKeyBehavior` | `enum: String, CaseIterable, Identifiable` | Enter vs ⌘Enter setting | `Models/SendKeyBehavior.swift:4` |
| `ANSIAttributedBuilder` | `enum` (static) | SGR → `NSAttributedString` (AppKit) | `Models/ANSIAttributedBuilder.swift:17` |
| `LanguageDetection` | `enum` (static) | file path → hljs language name | `Models/LanguageDetection.swift:1` |
| `StreamPacer` | (value/struct, math) | Critically-damped second-order servo for smooth streaming reveal | `Models/StreamPacer.swift` |
| `TurnTokenUsage` | `struct: Equatable, Sendable` | Per-turn token accounting + `compactLabel` | `Models/TurnTokenUsage.swift:13` |

NOTE (smell, see §5): `SyntaxTheme`, `PermissionMode+Color`, `Effort+Display`,
`ANSIAttributedBuilder` are **view-layer concerns** (Color / NSAttributedString)
living under `Models/`, which the project defines as "plain data, struct first."

### 1g. Markdown parser → IR (`Components/Markdown/`)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `MarkdownDocument` | `public struct: Hashable, Sendable` | Entry point: `init(parsing:)` → `[MarkdownSegment]` IR | `Components/Markdown/MarkdownDocument.swift:10` |
| `MarkdownSegment` / `MarkdownBlock` / `MarkdownInline` / `MarkdownList` / `MarkdownListItem` / `MarkdownCodeBlock` / `MarkdownTable` | `public enum/struct: Hashable, Sendable` | Internal IR (TextKit-renderable vs extractable split) | `Components/Markdown/MarkdownTypes.swift:3`–`:85` |
| `MarkdownConvert` | `nonisolated enum` (static) | swift-markdown AST → internal IR | `Components/Markdown/MarkdownConvert.swift:9` |
| `MarkdownMath` | `enum` (static) | `$$…$$` block + `$…$` inline math splitting | `Components/Markdown/MarkdownMath.swift:3` |
| `MarkdownAutolink` | `enum` (static, shared `NSDataDetector`) | bare http(s) URLs → `.link` inlines | `Components/Markdown/MarkdownAutolink.swift:10` |

### 1h. Reusable components (`Components/`)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `BarSurfaceModifier` | SwiftUI `ViewModifier` (+ `View` ext) | Shared bar background treatment | `Components/BarSurfaceModifier.swift:22` |
| `BoundedHeightScrollView<Content>` | SwiftUI `View` | Scroll view capped at a max height | `Components/BoundedHeightScrollView.swift:25` |
| `BranchPickerView` | SwiftUI `View` | Branch popover; **consumes `GitProbe`** (passed in) | `Components/BranchPickerView.swift:3` |
| `DiffEngine` / `DiffColors` | `enum` (static) | Pure line-diff algorithm + color palette | `Components/DiffCore.swift:9`, `:139` |
| `DiffView` | SwiftUI `View` + `DiffViewBridge: NSViewRepresentable` + `DiffNSView: NSView` | Self-drawn diff; **reads `@Environment(\.syntaxEngine)`** | `Components/DiffView.swift:22`, `:82`, `:115` |
| `DotGridBackground` | SwiftUI `View` | Decorative dotted background | `Components/DotGridBackground.swift:13` |
| `FadeScrim<S: ShapeStyle>` | SwiftUI `View` | Gradient fade (SwiftUI variant) | `Components/FadeScrim.swift:24` |
| `FolderFilterPickerView` | SwiftUI `View` | Folder-group filter picker | `Components/FolderFilterPickerView.swift:13` |
| `HoverCapsuleStyle` / `HoverCapsuleModifier` | `ButtonStyle` / `ViewModifier` | Hover capsule chrome | `Components/HoverCapsuleStyle.swift:3`, `:23` |
| `TextInputView` + `InputNSTextView` + `InputTextScrollView` | `NSViewRepresentable` + `NSTextView` + `NSScrollView` | The chat input editor (AppKit-backed) | `Components/InputTextView.swift:6`, `:216`, `:336` |
| `ProgressRingView` | SwiftUI `View` | Circular progress ring | `Components/ProgressRingView.swift:8` |
| `SearchField` | SwiftUI `View` | Generic search text field | `Components/SearchField.swift:3` |
| `SelectableText` | `NSViewRepresentable` | Selectable read-only text label | `Components/SelectableText.swift:13` |
| `TranscriptScrimView` / `TranscriptBottomScrimView` | `@MainActor NSView` | AppKit top/bottom fade scrims w/ hitTest passthrough | `Components/TranscriptScrimView.swift:23`, `:110` |
| `VisualEffectView` | `NSViewRepresentable` | `NSVisualEffectView` wrapper | `Components/VisualEffectView.swift:10` |

### 1i. Extensions (`Extensions/`)

| Type | Kind | Responsibility | file:line |
|---|---|---|---|
| `GitUtils` | `enum` (static) | Process-free `.git/HEAD` branch read + repo check | `Extensions/GitUtils.swift:3` |

---

## 2. Component tree (this area)

Hosting / nesting for app-scope services + how they reach UI. AppKit nodes
marked `[AppKit]`, SwiftUI `[SwiftUI]`. `NSHostingView`/`NSHostingController`
boundaries noted with `sizingOptions`.

```
AppDelegate [AppKit]  (App/AppKit/AppDelegate.swift:29)
├── appState: AppState [@Observable]                         (App/AppState.swift:6)
│   ├── sessionManager: SessionManager                       owns sessions (out of scope)
│   ├── syntaxEngine: SyntaxHighlightEngine  (actor)         eager .load() at init (:44)
│   ├── recentProjects: RecentProjectsStore  (lazy)
│   ├── inputDraftStore: InputDraftStore
│   ├── sidebarGroupOrder: SidebarSessionGroupOrderStore     (init-injected, not env)
│   ├── activationTracker: AppActivationTracker  ───────┐    (private dep of ↓; no other consumer)
│   ├── notificationService: NotificationService  ◀─────┘    (init(activation:))
│   └── openInService: OpenInAppService                      .refresh() at init (:51)
├── searchBus: TranscriptSearchBus  [@Observable]            (owned here, NOT on AppState)
├── selectionModel: MainSelectionModel
├── settingsWindowController / aboutWindowController         (lazy, AppKit)
└── mainWindowController: MainWindowController [AppKit]
    └── MainSplitViewController [AppKit]                     (App/AppKit/MainSplitViewController.swift:10)
        ├── SidebarViewController [AppKit, NSOutlineView]    init-injected:
        │     ├─ sessionManager   (appState.sessionManager)
        │     ├─ groupOrderStore  (appState.sidebarGroupOrder)   :26
        │     └─ openInService    (appState.openInService)        :27
        └── DetailRouterViewController [AppKit]              init-injected bag of 6 (:127):
            │   model, sessionManager, recentProjects, notifications,
            │   searchEngine(=syntaxEngine), searchBus, inputDraftStore
            │   ─ installs notifications.onActivateSession (:162)  ← back-channel
            │   ─ calls notifications.bootstrap() (:173)
            │   ─ installs sessionManager.onLaunchFailure (:168)
            ├── ChatSessionViewController [AppKit]  (.session/.none)
            │     ├─ session.controller.attachSyntaxEngine(searchEngine) (:392)   ← AppKit channel
            │     ├─ Transcript2ScrollView [AppKit-native]
            │     └─ NSHostingView<ChatRestingBar> [SwiftUI]  (bottom-anchored, intrinsic)
            │           └─ .environment(sessionManager / recentProjects /
            │              inputDraftStore / \.syntaxEngine / searchBus / notifications)  (:576–581)
            │                 └─ InputBarView2 [SwiftUI]  reads @Environment(InputDraftStore) (:154)
            ├── ComposeSessionViewController [AppKit]  (.newSession)
            │     └─ NSHostingController<ComposeSessionView> [SwiftUI]  sizingOptions = []
            │           └─ same 6-env block (:100–105)
            │                 └─ NewSessionConfigurator [SwiftUI]
            │                       ├─ @Environment(SessionManager) (:91)
            │                       ├─ @Environment(RecentProjectsStore) (:90)
            │                       └─ @State probe: GitProbe (:98, seeded :119) → BranchPickerView
            └── ArchiveViewController [AppKit]  (.archive)
                  └─ NSHostingController<ArchiveView> [SwiftUI]  sizingOptions = []
                        └─ same 6-env block (:75–80)

(Demo VCs in DEBUG repeat the same 6-env block — DetailRouterVC:430–435.)

Global singletons (no tree edge; reached via .shared from views/runtime):
  ModelStore.shared            ← CCTermApp.init (:74), InputBar pickers, SessionRuntime+Start
  EffortDefaultStore.shared    ← InputBar effort picker
  NewSessionDefaultsStore.shared ← InputBar pickers, draft backfill
```

---

## 3. Data flow

### Direction summary

State **enters** this area three ways and flows in three matching patterns:

1. **App-scope services → SwiftUI views via `.environment()`** (unidirectional read).
   `sessionManager`, `recentProjects`, `inputDraftStore`, `\.syntaxEngine` are
   injected at each detail VC's hosting boundary and read with `@Environment(...)`.
   FACT — the same six-line block is repeated in `DetailRouterViewController.swift:430-435`,
   `ChatSessionViewController.swift:576-581`, `ComposeSessionViewController.swift:100-105`,
   `Content/Archive/ArchiveViewController.swift:75-80`,
   `Content/Chat/DraftSessionLandingViewController.swift:123-128`.

2. **App-scope services → AppKit via init injection** (unidirectional, constructor).
   `sidebarGroupOrder` + `openInService` → `SidebarViewController`
   (`MainSplitViewController.swift:26-27`). `syntaxEngine` (under the alias
   `searchEngine`) → detail VCs by initializer, then imperatively wired into the
   transcript controller: `session.controller.attachSyntaxEngine(searchEngine)`
   (`ChatSessionViewController.swift:392`).

3. **Service → UI back-channels via push closures** (the only inbound-to-UI edges):
   - `NotificationService.onActivateSession` — installed once by
     `DetailRouterViewController.viewDidLoad` (`:162`); banner click →
     `model.select(.session(sid))`. Source of the closure callback:
     `NotificationService.swift:162`. **This is the one true "service reaches UI"
     edge, and it is deliberately a single-owner push** (doc comment at
     `NotificationService.swift:38-47` explains the prior leak it replaced).
   - `SessionManager.onTurnEndedNotice` / `onPermissionPromptNotice` — wired in
     `AppState.init` (`:28`, `:36`) to `NotificationService.handle*`. Service→service,
     not service→UI.
   - `SessionManager.onLaunchFailure` — installed by `DetailRouterViewController.viewDidLoad:168`.

### Mutations flowing OUT of UI (write-back to services)

- `RecentProjectsStore.markLaunched` ← `Content/Chat/SessionInputSubmit.swift:37`
  (on send). `.add` / `.remove` ← `NewSessionConfigurator.swift:679/690/714`
  (folder picker). Unidirectional: view → store → UserDefaults.
- `InputDraftStore.save` ← `InputBarView2.swift:221` (debounced on text change);
  `.clear` ← `InputBarView2.swift:471` (imperative clear before submit — see the
  teardown note in Chat/CLAUDE.md §Data flow).
- `EffortDefaultStore.remember`, `NewSessionDefaultsStore.setModel/setPermissionMode`
  ← InputBar pickers (`InputBarControls/*`).
- `SidebarSessionGroupOrderStore.replace/prependIfAbsent` ← sidebar drag-and-drop /
  new-project detection.

### Highlight engine flow (dual channel — by design)

The single `AppState.syntaxEngine` reaches two renderers via two channels:
- **AppKit transcript** — imperative `attachSyntaxEngine` →
  `Transcript2Coordinator(syntaxEngine:)` → `Transcript2HighlightStorage`
  (`Transcript2Controller.swift:190/224`, `Transcript2Coordinator.swift:149/173`).
- **SwiftUI `DiffView`** (tool blocks) — `@Environment(\.syntaxEngine)`
  (`DiffView.swift:35,474`).

This is two different rendering substrates, so the dual channel is consistent
with `Services/Session/CLAUDE.md`'s "pick one channel per renderer" rule, not a
violation. `engine?.load()` is idempotent so both eager (`AppState.init:45`) and
lazy (`DiffView.swift:489`) loads coexist.

### Hidden / bidirectional coupling — explicit callouts

- **DEAD SwiftUI-environment plumbing (back-channel masquerading as a dependency):**
  `.environment(notifications)` and `.environment(searchBus)` are injected into
  every detail VC's hosted SwiftUI tree, but **NO SwiftUI view ever reads them.**
  FACT: `grep "NotificationService.self"` → 0 hits; `grep "TranscriptSearchBus.self"`
  / `@Environment(TranscriptSearchBus` → 0 hits. Both are consumed exclusively
  through AppKit-side channels (`onActivateSession` push;
  `withObservationTracking` in the toolbar search bridge — see `CCTermApp.swift:134`).
  See §5 (high). This is the clearest unidirectional-cleanup opportunity in the area.

- **`activationTracker` is held by `AppState` only to keep it alive.** Its single
  consumer is `NotificationService` (constructor-injected, read at
  `NotificationService.swift:89,97`). No view, no other service reads it
  (`grep` confirms only AppState + NotificationService). INFERENCE: it could be a
  private sub-object of `NotificationService` instead of an `AppState` member.

---

## 4. Ownership & lifetime

| Object | Constructed by | Retained by | Torn down |
|---|---|---|---|
| `AppState` | `AppDelegate` (`let appState = AppState()`, `AppDelegate.swift:30`) | `AppDelegate` | App exit |
| `SyntaxHighlightEngine` | `AppState` (`:8`) | `AppState`; weak-ish reach into transcript coordinator (`Transcript2HighlightStorage.engine`) | App exit |
| `RecentProjectsStore` | `AppState` (`:9`) | `AppState`; SwiftUI `@Environment` (non-owning) | App exit. `nonisolated deinit` (`:74`) is the macOS-26 SDK workaround |
| `InputDraftStore` | `AppState` (`:10`) | `AppState` | App exit. `nonisolated deinit` (`:38`) |
| `SidebarSessionGroupOrderStore` | `AppState` (`:11`) | `AppState`; `SidebarViewController` (init-stored, `:38`) | App exit |
| `AppActivationTracker` | `AppState.init` (`:18`) | `AppState` + `NotificationService` (strong, by design — comment `AppState.swift:25-27`) | App exit |
| `NotificationService` | `AppState.init` (`:20`) | `AppState`; detail VCs (env, non-consuming) | App exit. `nonisolated deinit` (`:59`) |
| `OpenInAppService` | `AppState` (`:14`) | `AppState`; `SidebarViewController` (init-stored, `:39`) | App exit |
| `TranscriptSearchBus` | `AppDelegate` (`:31`) | `AppDelegate` + VCs (env, non-consuming) | App exit. `nonisolated deinit` (`:35`) |
| `ModelStore` / `EffortDefaultStore` / `NewSessionDefaultsStore` | lazy `static let shared` | process global | never (process lifetime) |
| `GitProbe` | `NewSessionConfigurator` `@State` (`:119`, seeded) | the SwiftUI view's `@State` storage | with the configurator view |
| `MainThreadWatchdog` timer | `MainThreadWatchdog.start()` (`CCTermApp.init:64`) | static `var timer` | never (intentional) |

INFERENCE: every app-scope service has app-lifetime; none is recreated per
session/selection. The repeated `nonisolated deinit {}` on `@Observable @MainActor`
classes is a uniform, deliberate macOS-26 SDK trap workaround (cross-referenced
in each file to `Session.deinit`), not accidental duplication — preserve it.

---

## 5. Smells / debt

**S1 — Dead SwiftUI-environment injections of `notifications` + `searchBus`.**
Severity: **high** (cleanliness/clarity, zero behavior). Every detail VC injects
`.environment(notifications)` and `.environment(searchBus)` into its hosted tree,
but no SwiftUI view reads either type. They are consumed only via AppKit channels
(`onActivateSession` push at `DetailRouterViewController.swift:162`;
`withObservationTracking` toolbar bridge per `CCTermApp.swift:134`). Evidence:
`grep NotificationService.self` → 0; `grep TranscriptSearchBus.self` → 0.
Locations: `App/AppKit/DetailRouterViewController.swift:434-435`,
`App/AppKit/ChatSessionViewController.swift:580-581`,
`Content/Chat/ComposeSessionViewController.swift:104-105`,
`Content/Archive/ArchiveViewController.swift:79-80`,
`Content/Chat/DraftSessionLandingViewController.swift:127-128`,
`App/AppKit/DetailRouterViewController.swift:435` (demo). Why: implies a
dependency that doesn't exist; an env-driven refactor would chase a phantom edge.

**S2 — The six-line `.environment(...)` block is copy-pasted across ≥5 VCs.**
Severity: **medium** (duplication / drift risk). Identical bag of injections
appears at `DetailRouterViewController.swift:430-435`,
`ChatSessionViewController.swift:576-581`, `ComposeSessionViewController.swift:100-105`,
`ArchiveViewController.swift:75-80`, `DraftSessionLandingViewController.swift:123-128`.
Why: adding/removing a service forces a 5-site edit; S1's dead entries already
demonstrate the drift. A single `View.injectAppEnvironment(_:)` helper (taking the
3-4 actually-consumed services) would make the real dependency set explicit and
unidirectional.

**S3 — `SyntaxHighlightEngine` is passed under the parameter name `searchEngine`.**
Severity: **medium** (naming / misleading abstraction). The type is the syntax
highlighter, but the init parameter and stored property are named `searchEngine`
in 5 VCs: `MainSplitViewController.swift:34`, `DetailRouterViewController.swift:75,119,127`,
`ChatSessionViewController.swift:69,129,137`, `ArchiveViewController.swift:25,36`,
`ComposeSessionViewController.swift:38,49`, `DraftSessionLandingViewController.swift:30,45`.
Then it is re-exposed as `\.syntaxEngine` and forwarded to demo VCs as
`syntaxEngine:` (`DetailRouterViewController.swift:416`). Why: a reader sees
`searchEngine` and reasonably expects transcript-search machinery; it is unrelated
to `TranscriptSearchBus`. Pure rename — no behavior.

**S4 — Three config stores are `.shared` singletons while five peers live on `AppState`.**
Severity: **medium** (inconsistent ownership pattern). `ModelStore.shared`
(`Services/ModelStore.swift:13`), `EffortDefaultStore.shared` (`:25`),
`NewSessionDefaultsStore.shared` (`:19`) are global singletons reached directly
from views and from `SessionRuntime+Start`, bypassing AppState/environment entirely.
Their siblings (`RecentProjectsStore`, `InputDraftStore`, `SidebarSessionGroupOrderStore`)
are AppState-owned + injected. Why: two competing dependency-acquisition styles
in the same layer; the singletons are also harder to fake in tests (each has a
`defaults:`/`init` seam, but call sites hardcode `.shared`). NOTE: not all are
equal — `EffortDefaultStore`/`NewSessionDefaultsStore` are stateless UserDefaults
wrappers (singleton is low-harm); `ModelStore` holds mutable observable catalog
state + spawns a CLI subprocess on `prefetchIfNeeded` (singleton here is the more
questionable one).

**S5 — `ClaudeCodeStats` has no production consumer.**
Severity: **low** (dead/unwired code, or pending feature). `grep` shows
`aggregate(...)` called only from `cctermTests/ClaudeCodeStatsTests.swift`. No
view, VC, or service references it (`Services/ClaudeCodeStats.swift:78`). Why: a
fully-built, fully-tested ~460-line service that nothing in the app calls; either
a stats panel is pending or it is dead. Verify intent before any restructure.

**S6 — View-layer concerns filed under `Models/`.**
Severity: **low** (layering / CLAUDE.md "Model = plain data" deviation).
`SyntaxTheme` (returns SwiftUI `Color`, `Models/SyntaxTheme.swift:35`),
`PermissionMode+Color` (`Models/PermissionMode+Color.swift:4`),
`Effort+Display` (UI labels, `Models/Effort+Display.swift:8`), and
`ANSIAttributedBuilder` (`NSAttributedString`, `Models/ANSIAttributedBuilder.swift:17`)
are presentation mappers, not data. Why: the root CLAUDE.md defines Model as
"plain data, struct first, Codable where it crosses a boundary"; these import
SwiftUI/AppKit and produce view types. Low priority — they are stateless and
correctly placed relative to each other; could move to `Components/` or a
`Presentation/` folder if tidying.

**S7 — `activationTracker` surfaced as an `AppState` member but only a private dep
of `NotificationService`.** Severity: **low**. `AppState.swift:12` holds it solely
so it outlives the app; the only reader is `NotificationService`
(`:89,97`). Why: widens AppState's public surface for an object no other consumer
needs; could be constructed inside `NotificationService`. (Counterpoint: keeping
it as a sibling makes the "service gates on activation" relationship visible — a
judgment call, hence low.)

**S8 — `GitProbe` is `@Observable` without `@MainActor` while every peer service
is `@MainActor`.** Severity: **low** (consistency). `Services/GitProbe.swift:25`
omits `@MainActor`; all of `RecentProjectsStore`/`InputDraftStore`/
`NotificationService`/`AppActivationTracker`/`OpenInAppService`/`ModelStore` carry
it. It works (constructed/used from a SwiftUI `@State` on the main actor; heavy
work hops to `Task.detached`), but the missing annotation is an isolation
inconsistency a reader has to reason about. Behavior-neutral if added.

---

## 6. Load-bearing invariants (a refactor MUST preserve)

**I1 — One `SyntaxHighlightEngine` instance, eagerly loaded, shared by both
renderers.** `AppState.init:44-45` kicks `engine.load()` on `.utility` so the
first highlight doesn't pay ~30ms JSCore init on the user path. The same instance
must reach (a) the transcript coordinator via `attachSyntaxEngine`
(`ChatSessionViewController.swift:392`) and (b) `DiffView` via `\.syntaxEngine`.
Do not split into per-view engines (the LRU cache + same-tick coalescing in
`SyntaxHighlightEngine.swift:70-163` depend on a single shared actor). The
`#Preview` at `DiffView.swift:565` constructing its own engine is preview-only and
fine.

**I2 — `RecentProjectsStore` load is lazy on first read; never eager from
`AppState.init`.** `RecentProjectsStore.swift:18-27,155` documents that the
`fileExists` walk triggers macOS TCC "external volume" prompts; eager-loading made
that prompt fire on every launch (and every XCTest fork). A refactor must not move
the load into `init` or call a public member from `AppState.init`.

**I3 — Notification → UI is a single-owner push closure, not per-VC observation.**
`NotificationService.onActivateSession` must have exactly one installer
(`DetailRouterViewController.viewDidLoad:162`). The doc comment
(`NotificationService.swift:38-47`) records that the prior `@Observable`-field +
re-arming `withObservationTracking` shape leaked every detail VC. Same constraint
for `SessionManager.onLaunchFailure` / the turn-end / permission notices: single
stable owner, no per-VC observation. Preserve the push-callback idiom.

**I4 — `SessionManager` notices → `NotificationService` are wired exactly once in
`AppState.init` with strong captures.** `AppState.swift:28,36`. The strong capture
is intentional and correct (both live for app lifetime); the service self-gates on
`activationTracker.isAppActive`. Don't make this conditional or move it behind a
view lifecycle.

**I5 — `nonisolated deinit {}` on `@Observable @MainActor` service classes is
required.** Present on `RecentProjectsStore:74`, `InputDraftStore:38`,
`NotificationService:59`, `AppActivationTracker:41`, `TranscriptSearchBus:35`,
`SessionManager`. Removing it reintroduces the macOS-26
`swift_task_deinitOnExecutorImpl` trap on teardown (hit by the host-aware reentry
test). Keep on any such class a refactor introduces.

**I6 — `ModelStore.prefetchIfNeeded()` in-flight dedupe (`guard !isLoading`).**
`ModelStore.swift:70-71`. Callers hit `.shared` twice per launch (compose mode +
popover open before first fetch lands); without the dedupe a second CLI subprocess
races. If `ModelStore` is de-singletoned, the single-instance + dedupe guarantee
must be retained.

**I7 — Markdown IR is a pure value boundary; the transcript bridge is its sole
app consumer.** `MarkdownDocument(parsing:)` is called only by
`Content/Chat/NativeTranscript2Bridge/MarkdownToBlocks.swift:13`; the IR types are
`public … Hashable, Sendable` value types with no UI/service dependency. The
bridge reshapes IR → transcript `Block` and derives stable per-segment IDs
(`MarkdownToBlocks.swift:15-17`) that the coordinator's incremental diff relies on.
A refactor must keep the parser pure/off-main-safe and must not change segment
ordering/ID derivation (it would break the diff fast path documented there).
`MarkdownConvert` is explicitly `nonisolated` (`MarkdownConvert.swift:9`) so it can
run off-main inside the backfill pipeline — preserve that.

**I8 — Highlight requests must stay coalesced/cached.** The same-tick
auto-coalesce (`SyntaxHighlightEngine.highlight` → `flushCoalesced`,
`SyntaxHighlightEngine.swift:70-163`) and 256-entry LRU
(`:14-18,239-246`) are the perf contract that keeps chat scrolling snappy and
makes collapse→expand a cache hit. Don't replace with per-call JS invocations.

---

## Appendix: facts that constrain the refactor narrative

- `searchBus` and `selectionModel` are owned by `AppDelegate`, **not** `AppState`
  (`AppDelegate.swift:31,34`), even though they are app-scope. Mild ownership
  split worth knowing when mapping "the app-scope container."
- The injected services that are *actually consumed* by SwiftUI are exactly:
  `SessionManager` (`@Environment(SessionManager.self)` in 6 sites),
  `RecentProjectsStore` (1 site), `InputDraftStore` (1 site), `\.syntaxEngine`
  (DiffView, 2 sites). Everything else in the 6-env block is either AppKit-channel
  (syntaxEngine via `attachSyntaxEngine`) or dead (notifications, searchBus).
- `GitProbe` and `ClaudeCodeStats` are the only two in-scope "services" that are
  not app-scope; `GitProbe` is view-`@State`, `ClaudeCodeStats` is unwired.

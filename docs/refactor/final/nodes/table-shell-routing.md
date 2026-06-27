# Ownership table — App shell, routing, DI

Scope: `App/` + `App/AppKit/` — the AppKit-rooted shell, the selection/routing
spine, DI fan-out, the auxiliary windows, the toolbar hosts, and the two
target-new DI/animation helpers. TARGET design per REFACTOR-PLAN §5/§8; as-is in
parentheticals. PR labels are stable mnemonics consistent with §9 phases
(A = mechanical, B = boundary/card, C = sidebar/runtime, D = transcript-swap);
the PRPlan phase finalizes numbers.

Host regimes cite BOUNDARY-SPEC §1 (A fill-pane `[]` / B centered component
`[.intrinsicContentSize]` / B′ toolbar-slot / B″ floating overlay / C
window-content / D modal sheet / E leaf-in-cell), "—" = not a hosting boundary.

Legend for "Reads state via": `@Observable pull` / `closure sink` / `ctor-injected` / `n/a`.
Legend for "Emits via": `Session method` / `injected closure` / `model.select` / `imperative controller call` / `@Observable write` / `none`.

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |
|---|---|---|---|---|---|---|---|---|---|
| `CCTermApp` | App-lifecycle | SU-View | Swift `@main` runtime | OS process | n/a (holds `@NSApplicationDelegateAdaptor`) | none (delegates to AppDelegate via `appDelegate.*`) | C (Settings placeholder scene = window-content, default sizing) | unchanged | ✓ |
| `AppCommands` | App-lifecycle | SU-View (`Commands`) | `CCTermApp.body` (attached to placeholder `Settings` scene) | scene lifetime | ctor-injected (`searchBus` + two closures from `appDelegate`) | injected closure (`openSettings`/`openAbout`); `@Observable write` (`searchBus.requestFocus()`) | — | unchanged | ✓ |
| `AppDelegate` | App-lifecycle | AK-NSObject (`NSApplicationDelegate`) | SwiftUI runtime via `@NSApplicationDelegateAdaptor` | OS process | n/a (root owner) | imperative controller call (creates `MainWindowController`; `show*Window`) | — | unchanged | ✓ |
| `AppState` | App-scope-state | @Observable-SVC | `AppDelegate` stored-prop init | process | n/a (it *is* the state container) | `@Observable write` (sub-services); closure wiring (`onTurnEndedNotice`) | — | PR-C11 (optional: `searchBus`/UserDefaults wrappers move in; `ModelStore` stays `.shared`) | ✓ |
| `MainSelectionModel` | App-scope-state | @Observable-SVC | `AppDelegate` stored-prop init | process / window | n/a (source of truth) | `@Observable write` (`selection=`) + synchronous `selectionObserver.selectionDidChange` (sole upward structural edge) | — | unchanged (stays on AppDelegate — window-level, §8.P11) | ✓ |
| `MainSelection` | Pure-value | value/MDL | inline (enum literal) | per-value | n/a | n/a | — | unchanged | ✓ |
| `DemoKind` (DEBUG) | Pure-value | value/MDL | inline (enum literal) | per-value | n/a | n/a | — | unchanged | ✓ |
| `MainSelectionObserver` (protocol) | DI-context | value/MDL (protocol) | n/a | n/a | n/a | n/a (defines the one upward structural edge) | — | unchanged | ✓ |
| `TranscriptSearchBus` | App-scope-service | @Observable-SVC | `AppDelegate` stored-prop init | process | n/a | `@Observable write` (`focusRequestCounter`) — pulled by AppKit `TranscriptSearchToolbarBridge` via `withObservationTracking` | — | PR-C11 (optional ★MOVED AppDelegate→AppState; doc currently says `.searchable` — stale, fix in PR-B8) | ✓ |
| `SettingsWindowController` | Window-shell | AK-VC (`NSWindowController`) | `AppDelegate.showSettingsWindow()` (lazy) | process (survives close→reopen; `isRestorable=false`) | n/a | imperative controller call (hosts `SettingsView`) | C — window-content host, default `sizingOptions` (BOUNDARY-SPEC §1 C; `:15`) | unchanged | ✓ |
| `AboutWindowController` | Window-shell | AK-VC (`NSWindowController`) | `AppDelegate.showAboutWindow()` (lazy) | process | n/a | imperative controller call (hosts `AboutView`) | C — window-content host, default `sizingOptions` (BOUNDARY-SPEC §1 C; `:23`) | unchanged | ✓ |
| `MainWindowController` | Window-shell | AK-VC (`NSWindowController`, `NSToolbarDelegate`) | `AppDelegate.applicationDidFinishLaunching` | window (= process; single window) | ctor-injected (`model`, `appState`, `searchBus`); `@Observable pull` (`model.selection` via `withObservationTracking` for chip/filter presence) | imperative controller call (builds split + toolbar items) | — (owns toolbar hosts below) | unchanged | ✓ |
| `TranscriptProjectChip` | SwiftUI-view | SU-View | `MainWindowController.toolbar(_:itemForItemIdentifier:)` via `NSHostingView` | toolbar-item lifetime | `@Observable pull` (`@Bindable model`, `sessionManager.existingSession`) | none (read-only chip) | B′ — toolbar-slot component, `[.intrinsicContentSize]` (BOUNDARY-SPEC §1 B′; `MainWindowController.swift:253`) | unchanged | ✓ |
| `ArchiveFilterToolbarButton` | SwiftUI-view | SU-View | `MainWindowController.toolbar(_:itemForItemIdentifier:)` via `NSHostingView` | toolbar-item lifetime | `@Observable pull` (`@Bindable model`, `sessionManager.archivedFolderOptions`) | `@Observable write` (`model.archiveSelectedFolderPath`) | B′ — toolbar-slot component, `[.intrinsicContentSize]` (BOUNDARY-SPEC §1 B′; `MainWindowController.swift:280`) | unchanged | ✓ |
| `TranscriptSearchToolbarBridge` | AppKit-coordinator | AK-NSObject (`NSSearchFieldDelegate`) | `MainWindowController.makeSearchBridgeIfNeeded` | window | `@Observable pull` (`searchBus.focusRequestCounter` via `withObservationTracking`); `controllerProvider` PULLs live `Transcript2Controller` per keystroke | imperative controller call (`controller.runSearch/nextSearchHit/previousSearchHit`) | — | unchanged | ✓ |
| `MainSplitViewController` | Window-shell | AK-VC (`NSSplitViewController`) | `MainWindowController.init` | window | ctor-injected (`model`, `appState`, `searchBus`) | imperative controller call (builds sidebar + router; **DI fan-out point**) | — | PR-B7 ★CHANGED-P2 (builds one `DetailContext` value + a `SidebarContext`; stops destructuring AppState into a 7-bag/4-bag) | ✓ |
| `DetailContext` ★NEW | DI-context | value/MDL (struct) | `MainSplitViewController.init` | window (passed by value through `makeChild`) | n/a (carries `model` + the 4 *consumed* services: `SessionManager`, `RecentProjectsStore`, `InputDraftStore`, `\.syntaxEngine`) | ctor-injected (handed to each detail child) | — | PR-B7 ★NEW-P2/Rule 7 (replaces the 7-arg bag; dead `notifications`/`searchBus` env edges removed in PR-A1) | ✓ |
| `DetailRouterViewController` | Detail-child-VC owner | AK-VC (`NSViewController`, `MainSelectionObserver`) | `MainSplitViewController.init` | window | ctor-injected (DI bag → `DetailContext`); reads `model.selection` only via the synchronous observer callback (never `withObservationTracking`) | `model.select` (forwards `notifications.onActivateSession`); imperative controller call (`makeChild`, child `present(sessionId:)`) | — (paints `NSVisualEffectView`; mounts children pinned 4-edge) | PR-B7 ★CHANGED-P2 (holds a `DetailContext`, threads it whole into `makeChild`); PR-A2 ★RENAMED (`searchEngine`→`syntaxEngine`) | ✓ |
| `DetailRouterChild` (protocol) | Detail-child-VC | value/MDL (protocol) | n/a | n/a | n/a | n/a (`prepareForRemoval()` deterministic teardown contract, Rule 5 wall) | — | unchanged | ✓ |
| `CrossfadeController` (proposed, P6) | AppKit-coordinator | AK-NSObject | `DetailRouterViewController` + `TranscriptSwapCoordinator` (if adopted) | window / per-attach | n/a (stateful animation helper) | imperative controller call (`NSAnimationContext.runAnimationGroup`) | — | PR-D13 ★OPTIONAL-P6 (**default NOT done** — only ~7 shared lines; must never own the chat-I5 `removeObserver` pre-flush; §8.P6/§11) | ✗ — does NOT place cleanly: ambiguous owner (router cross-kind vs chat same-session crossfades diverge in park-type / guarded-finish / I5 pre-flush). Plan downgrades it to optional/keep-two-copies. Listed as a design defect *of the abstraction*, not of the current code (current two state machines each place fine). |

## Notes on regime / channel verification

- **Toolbar hosts (chip / filter)** — BOUNDARY-SPEC §1 row B′: `NSHostingView`
  + `[.intrinsicContentSize]`, no constraints (toolbar auto-measures). Verified
  `MainWindowController.swift:253` and `:280`. By-design, no collapse failure
  mode → no backing test (BOUNDARY-SPEC §6).
- **Settings / About windows** — BOUNDARY-SPEC §1 row C: `NSHostingController`
  as `window.contentViewController`, **default** `sizingOptions` (you *want* the
  window to snap to content). Verified `SettingsWindowController.swift:15`,
  `AboutWindowController.swift:23`.
- **`MainSelectionModel.selectionObserver`** — the sole upward structural edge
  (REFACTOR-PLAN §3.2, Rule 4). Verified synchronous fire in `select(_:)`
  (`:53-57`) and `promote(to:)` (`:72-79`). Not generalizable to a bus.
- **Dead injections** — `notifications` + `searchBus` are threaded into the
  router and each detail child but read by **no SwiftUI view** (P1). They reach
  consumers via AppKit channels only (`notifications.onActivateSession` push in
  `DetailRouterViewController.viewDidLoad:162`; `searchBus` via the toolbar
  bridge). Their `.environment(...)` injections are deleted in PR-A1; the
  router still *holds* `notifications` (used by AppKit) but stops *injecting* it
  into SwiftUI. `searchBus` is held by router only for forwarding to children —
  after PR-A1 + PR-B7 it drops out of the `DetailContext` entirely.
- **`searchEngine` misnomer** — `SyntaxHighlightEngine` is threaded under the
  name `searchEngine` through `MainSplitViewController:34`,
  `DetailRouterViewController:75,119,127,416`. Pure rename to `syntaxEngine`
  (PR-A2, compiler-guarded). Not a search mechanism (unrelated to
  `TranscriptSearchBus`).

## Non-conformant / design defects

1. **`CrossfadeController` (proposed P6)** — ✗ **does not place cleanly.** It has
   no single owner (the router's cross-kind crossfade and the chat
   same-session transcript crossfade are different lifetimes with different
   park-state, idempotent-finish guards, and the load-bearing chat-I5
   `removeObserver` pre-flush). Forcing both behind one stateful coordinator
   either fabricates an ambiguous owner or leaks the I5 ordering out of
   `TranscriptSwapCoordinator.attach`. REFACTOR-PLAN §8.P6/§11 already downgrade
   it to optional/default-not-done and sanction keeping two copies ("repetition
   cheaper than risk"). **Recommendation: do not introduce the row.** The two
   existing crossfade state machines each place cleanly on their owning VC; the
   *abstraction over them* is the defect.

No other type in this scope is non-conformant. Every shell/routing/DI/window/
toolbar type has an unambiguous owner, a single clearly-typed state-in channel
(`@Observable pull` or `ctor-injected`), a single state-out channel
(`model.select` / `@Observable write` / injected closure / imperative controller
call), and a correct host regime (or "—"). The two genuine *current* smells in
this scope — the 7-arg DI bag and the dead `notifications`/`searchBus` env
injections — are not unplaceable types; they are wiring fixed in-place by PR-A1
(delete dead edges) and PR-B7 (`DetailContext`), and the affected types
(`MainSplitViewController`, `DetailRouterViewController`) remain conformant
before and after.

# CCTerm refactor — the component-tree / data-flow conformance spec

> **Purpose.** This is the single, self-contained **ruleset** that the final
> ownership table is checked against. Every class/module in the refactored
> architecture must be placeable in the fixed ownership-table schema **and**
> satisfy every rule below. A class that cannot be cleanly placed (ambiguous
> owner, unclear data-in/data-out channel, wrong/unknown host regime, or that
> straddles two layers) is a **design defect** — it is marked `✗ + issue`, not
> shoehorned into the table.
>
> Consolidated from REFACTOR-PLAN §3/§4 (ownership/layer model), §6 (the 7
> data-flow constitution rules), §7 (permission-card overlay), §10 (do-not-touch
> wall), §11 (explicitly-not-done), and BOUNDARY-SPEC (host regimes A/B/B′/B″/C/D/E).
> Where this spec and a source `CLAUDE.md` disagree, the source `CLAUDE.md` wins
> and this spec is the defect.

---

## 0. The ownership-table schema (the conformance target)

Every component MUST be expressible as exactly one row of:

| Component | Layer | Kind | Constructed by | Owner / lifetime | Reads state via | Emits via | Host regime | Target Δ (PR#) | Conformant |

Allowed cell vocabularies (closed sets):

- **Layer** ∈ {App-lifecycle, App-scope-state, App-scope-service, Window-shell,
  DI-context, Detail-child-VC, Per-attach, AppKit-coordinator, Session-core,
  Per-load, Pure-value, SwiftUI-view, View-scope-state, Renderer-internal}.
- **Kind** ∈ {AK-VC, AK-View, AK-NSObject, SU-View, @Observable-SVC, actor-SVC,
  value/MDL, translator}.
- **Reads state via** ∈ {@Observable pull, closure sink, ctor-injected, n/a}.
- **Emits via** ∈ {Session method, injected closure, model.select, imperative
  controller call, @Observable write, none}.
- **Host regime** ∈ {A, B, B′, B″, C, D, E} (BOUNDARY-SPEC) or "—" (not a hosting
  boundary).
- **Target Δ (PR#)** = the migration step number from §7 below, or "unchanged".
- **Conformant** = ✓, or ✗ + one-line issue.

---

## 1. The layer model (allowed layers + permitted dependency direction)

**Strictly downward.** A component may hold/depend on components in its own layer
or any layer **below** it. The **one and only allowed upward edge** is
`selectionObserver` (rule D-4). Anything else pointing up is a defect.

Layers, top (longest-lived / outermost) → bottom:

| Layer | What lives here | May depend on (downward) |
|---|---|---|
| **App-lifecycle** | `AppDelegate` | everything below |
| **App-scope-state** | `AppState`, `searchBus`, `selectionModel` | App-scope-service, Session-core, Pure-value |
| **App-scope-service** | the AppState services + `.shared` singletons | App-scope-service (peers), Session-core, Pure-value |
| **Window-shell** | `MainWindowController`, `MainSplitViewController`, `SidebarViewController`, `DetailRouterViewController`, toolbar bridges | DI-context, Detail-child-VC, App-scope-* (ctor-injected), Session-core |
| **DI-context** | `DetailContext`, `SidebarContext` (value bags of model + consumed services) | App-scope-service, App-scope-state (carries, does not own) |
| **Detail-child-VC** | `ChatSessionViewController`, `ComposeSessionViewController`, `DraftSessionLandingViewController`, `ArchiveViewController`, demo VCs | AppKit-coordinator, Per-attach, SwiftUI-view (hosted), Session-core (via context), DI-context |
| **Per-attach** | `transcriptScroll`, `transcriptSheetPresenter`, running-obs task | Session-core, Renderer-internal |
| **AppKit-coordinator** | `TranscriptSwapCoordinator`, `SidebarContextMenuController`, `SidebarTreeModel`, `Transcript2Coordinator`, toolbar bridges | Session-core, Per-attach, Pure-value, Renderer-internal |
| **Session-core** | `Session`, `SessionRuntime` (+ extracted trackers), `Transcript2Controller`, `Transcript2EntryBridge` | Session-core (composed sub-objects), Pure-value, Renderer-internal |
| **Per-load** | `TranscriptBackfillPipeline` | Session-core, Renderer-internal, Pure-value |
| **SwiftUI-view** | every `[SU]` view | reads `@Observable` down; emits up via closures/Session methods only |
| **View-scope-state** | `CompletionState` (`CompletionViewModel`), `GitProbe`, `BackgroundTaskOutputStream` | Pure-value, Session-core (read via `@Observable`) |
| **Pure-value** | `MarkdownDocument`, `StableBlockID`, `SedEditParser`, `SidebarItemNode`, enums/themes | nothing (pure) |
| **Renderer-internal** | `Transcript2TableView`, `BlockCellView`, layout/diff internals | Pure-value only; sealed (§5) |

**Conformance check L1.** A component whose declared Layer cannot reach all the
components it actually references **downward** is a defect (upward/lateral leak).
The single exemption is `selectionObserver`.

---

## 2. Construction & ownership rules

- **C-1 Single owner per object.** Every object has exactly one owner that
  controls its lifetime (the "Owner / lifetime" cell). No object is co-owned.
- **C-2 Services are constructed only by `AppState` / `AppDelegate`** (process
  scope) or by their documented owner (`SessionManager.makeSession` for
  Session-core; `DetailRouterViewController.makeChild` for Detail-child-VCs;
  `…attachSession` for Per-attach). **Views never construct services.**
- **C-3 The one narrow view-construction exception** is a *view-private
  interaction state machine* created via SwiftUI `@State`: `CompletionState`
  (rename of `CompletionViewModel`), `GitProbe`, `BackgroundTaskOutputStream`.
  These are not coordinating ViewModels for session/transcript state — that role
  is forbidden (rule §11 / D-mirror ban).
- **C-4 Lifetime classes** (the "Owner / lifetime" vocabulary): process /
  window / detail-child (one alive at a time, same-kind reuses) / per-attach /
  session (survives mount/dismount) / per-load / view-identity.
- **C-5 Dependencies thread as one value bag, not per-type.** App-scope deps
  reach Detail-child-VCs as a single `DetailContext` (model + *consumed*
  services) via `makeChild`; the sidebar as a single `SidebarContext`.
  Adding/removing one app-scope dependency is a one-site edit (this is rule D-7).
- **C-6 Deterministic teardown.** Every Detail-child-VC implements
  `DetailRouterChild.prepareForRemoval()` to release per-attach resources at swap
  time. Every `@MainActor @Observable` / VC type (including any new
  coordinator/tracker) carries `nonisolated deinit {}` (macOS-26 abort
  workaround). New types without these are defects.

---

## 3. Data-flow rules (the 7 constitution rules, condensed)

> Default is reactive (`@Observable` pull down, method/closure up). Imperative
> edges are the rare exception and must be annotated at the call site.

- **D-1 State lives at the lowest scope shared by all its readers.**
  process → `AppState`; window-selection → `MainSelectionModel`; single-session
  business+render → `Session`; transcript row model → `Transcript2Coordinator.blocks`;
  view-private interaction → SwiftUI `@State`. One reader ⇒ `@State`, never a
  model field.
- **D-2 Data flows DOWN by reading `@Observable`; never cached.** SwiftUI bodies
  read `session.X` / `model.X` directly. No view holds a shadow copy of a model
  field. (Corollary: an `@Observable` write does not reach a SwiftUI body in the
  same tick — bodies re-eval in `beforeWaiting`.)
- **D-3 Events flow UP via one of two channels, chosen by the renderer.**
  SwiftUI consumers → call a `Session` method or an injected closure
  (`onSubmit` / `onAttachRect` / `onBuiltinCommand`); **never** touch
  `session.runtime.X`. AppKit consumers (transcript) → a synchronous closure
  sink declared on `SessionRuntime`, multiplexed once in
  `Session.wireRuntimeMessagesSink`, consumed by the bridge. **One piece of state
  never travels both channels.**
- **D-4 Exactly one structural upward edge: `selectionObserver`.** It exists
  because the detail-side switch must land in the click's *same source phase*
  (`@Observable` re-eval is one tick late at `beforeWaiting`, which would tear a
  session switch across frames). Single-owner, weak; **may not** be generalized
  into a notification bus or a second observer slot. New "react structurally to
  selection" needs go through the router.
- **D-5 Views never construct services; the ViewModel exception is narrow** (=
  rule C-2 + C-3). No coordinating ViewModel for session/transcript state.
- **D-6 Imperative calls are allowed only when correctness depends on
  runloop-tick timing `@Observable` cannot express.** A push is legitimate only
  if one of these holds, and it MUST be noted at the call site:
  - **(a)** it must run in the click's source phase, before `beforeWaiting`
    (selection notification, transcript attach, `present(sessionId:)`);
  - **(b)** it hands the **exact delta** to an AppKit consumer instead of forcing
    a diff (`bridge.apply`, `setLoading`, `setTurnUsage`);
  - **(c)** it must run on a stack above a reactive `.onChange` teardown that
    would otherwise swallow it (send-time draft-clear).
- **D-7 Dependencies thread as one bag of consumed services, not re-declared
  per type.** (= C-5.) The DI surface is a single value type carrying model +
  the actually-consumed services.

**Per-edge verdicts (the table the rows are checked against).** Each row's "Emits
via" / "Reads state via" must match its edge verdict here:

| Edge | Direction | Channel | Verdict | Rule |
|---|---|---|---|---|
| `select(_:)` → router | structural down | sync delegate | keep (timing) | D-4, D-6a |
| `model.selection` → SwiftUI | down | `@Observable` | keep | D-2 |
| sidebar → selection | up | `model.select(_:)` | keep | D-3 |
| router → chat VC | down | imperative `present(sessionId:)` | keep (timing) | D-6a |
| `session.*` → SwiftUI | down | `@Observable` forwarder | keep | D-2 |
| bridge → transcript | down | sync closure → `apply` | keep (exact delta) | D-3, D-6b |
| `isRunning` → loading pill | down | imperative `setLoading` + obs task | keep; optional closure-sink | D-3, D-6b |
| `turnUsage` → pill | down | closure-sink `onTurnUsageChange` | keep | D-3, D-6b |
| chrome rects → scrim | up | injected closure | keep (single reader, sync) | D-1, D-3, D-6b |
| send-time draft-clear | side effect | imperative `draftStore.clear` | keep (teardown-proof) | D-6c |
| card decision | up | `session.respond(...)` | keep (exemplar) | D-3 |
| `pendingPermissions` → card | down | `@Observable` forward | keep (exemplar) | D-2 |
| completion confirm → text | up | State→View→NSTextView | keep (inherent) | D-5 |
| `BackgroundTaskButton` → `runtime.x` | up | **pierces façade** | **FIX → `Session.stopBackgroundTask`** | D-3 |
| 7-arg DI + 2 dead injects | down | re-declared by type | **FIX → `DetailContext` + helper; delete dead** | D-7 |
| `searchEngine` naming | — | misleading | **FIX → `syntaxEngine`** | clarity |
| `searchBus` ownership | ownership | split | move to `AppState`; `selectionModel` stays (window) | D-1 |

---

## 4. Host-regime rules (BOUNDARY-SPEC)

> One rule above all: **decide who owns the size.** `sizingOptions` + the
> constraint pattern follow mechanically. Picking wrong collapses the window.

Each hosting boundary MUST declare exactly one regime, and its `sizingOptions` +
constraints MUST match:

| Regime | When | `sizingOptions` | Constraints |
|---|---|---|---|
| **A** Fill-a-pane | host *is* the detail pane's content | `[]` | pin all 4 edges |
| **B** Centered component | bar over a transcript that already fills the pane | `[.intrinsicContentSize]` | centerX + width≤cap(req) + width==cap(@high) + leading≥inset + bottom== |
| **B′** Toolbar-slot | `NSToolbar` item | `[.intrinsicContentSize]` | none (toolbar auto-measures) |
| **B″** Floating overlay | corner/bottom-center; DEBUG demos | default (benign) | position-only — **never 4-edge** |
| **C** Window-content | `NSWindow.contentViewController` | default (intended) | window sizes to content |
| **D** Modal-sheet | `beginSheet` | default (intended) | sheet sizes to content |
| **E** Leaf-in-cell | SwiftUI leaf in an AppKit row | `[.intrinsicContentSize]` | pin to cell insets; feeds `heightOfRow` (no production instance) |

- **H-1 No default `sizingOptions` on a fill-a-pane host.** Default options
  publish the body's `fittingSize` up the split → window collapse. Regime A is
  always `[]`. (BOUNDARY-SPEC §2.2 — the archive collapse was the *regime*, not
  the binding.)
- **H-2 The chat resting bar is regime B and stays asymmetric.** Its
  `[.intrinsicContentSize]` + five-constraint center/cap recipe is confirmed
  optimal (BOUNDARY-SPEC §3); the `composeOrBarHost → restingBarHost` change is a
  **pure rename** — constraints/regime unchanged.
- **H-3 Two-way `Binding`/`@Bindable` across the boundary is allowed and is never
  the collapse cause.** Use `[weak self]` in both closures. Under regime A `[]`
  it is height-neutral.
- **H-4 The permission-card overlay is "regime-A sizing + passthrough
  hit-testing"** — NOT regime B″. It uses `sizingOptions = []` + 4-edge pin (so
  it publishes no `fittingSize`), layered with a `PassthroughHostingView`
  (`hitTest → nil` off-card **and** suppressed cursor/tracking rects, §7 M2/M4),
  z-ordered above the bar host but transcript re-inserts `.below topScrim` (§7
  M5). This is what makes it neither collapse the window nor mask the transcript.
- **H-5 Un-erase `AnyView` at pane hosts.** The 5 pane hosts use a concrete
  generic body so the compiler enforces environment injection (a missed inject
  becomes a compile error). Mount fill-pane hosts through one `mountFillPaneHost`
  helper.

**Backing gates (CI merge gates; must not be `XCTSkip`'d or loosened):**
`AppKitSwiftUIBoundaryTests` (fill-pane `fittingSize.height ≈ 0`, binding
height-neutral, regime A/B teeth, large-window split probe),
`HostedComponentCenteringTests` (bar caps+centers / shrinks-to-fit),
hardened `DetailRouterLayoutDiagnosticsTests` (`fittingSize.height <= 1`).

---

## 5. The do-not-touch contracts (hard constraints)

Every refactor step is designed to **route around** these. If a step seems to
need one loosened, that step is wrong — stop and redesign.

- **DNT-1 Transcript §2 performance contract (all items).** Sync `heightOfRow`,
  `wantsLayer + .onSetNeedsDisplay` cell layer policy, scroll/clip `.never` +
  responsive, no LRU layout cache, `nonisolated static makeLayout` off-main
  purity, off-main-build-then-sync-apply backfill, in-tick forced tile,
  live-resize visible-rows-only, negative-width clamp, granular insert/remove
  (**never `reloadData()`**), status/search/highlight bypass via `Change.update`,
  `cacheLayouts` poison-guard, per-scope generation guard, shimmer subpixel/image
  cache. **No step enters the renderer internals.**
- **DNT-2 §2.19 single-width attach contract.** `factory.make` (unbound) →
  `addSubview` + constraints → host `layoutSubtreeIfNeeded()` →
  `factory.bindData` → `scrollToTail()`; the router settles the child frame
  before `present`. Guarded by the two reentry-layout merge gates.
- **DNT-3 Runloop-tick orderings.** Selection mutation is synchronous +
  single-observer in the click's source phase (never async
  `withObservationTracking` for structure, #195); crossfade structure is
  synchronous, only opacity is deferred (chat-I3); build-in-front-then-drop
  (chat-I4); **on A→B→A reentry the outgoing-scroll flush runs before bind
  (chat-I5 — the most fragile ordering in the app)**; send-time draft-clear is
  imperative (chat-I12).
- **DNT-4 Session→UI data rules.** One channel per state (AppKit sync-closure
  push / SwiftUI `@Observable` pull); `Session` holds controller+bridge for its
  whole lifetime; the bridge is wired once at init/promotion; history bypasses
  the bridge via the off-main backfill pipeline.
- **DNT-5 Deterministic teardown + macOS-26 deinit workaround** (= C-6).
- **DNT-6 Host-sizing discipline** (= §4): fill-pane `[]` + 4-edge; component
  `[.intrinsicContentSize]` + position-pin; the chat-bar asymmetry is preserved,
  not folded into a fill-pane helper. BOUNDARY-SPEC decision table is
  authoritative; its gates are merge gates.
- **DNT-7 Sidebar invariants 6.1–6.12** and **bridge/builder parity** (history
  off the bridge; no `.update` on load; cross-page withhold + doc-order parse).
- **DNT-8 Explicitly-not-done (anti-over-engineering).** Do NOT: merge
  `Transcript2Controller` + `Transcript2Coordinator`; make the router observe
  selection via `withObservationTracking`; introduce a global store / Redux /
  chat-area ViewModel; inject `AppState` as a whole; collapse `Session`'s ~40
  phase forwarders behind a protocol (P9); extract `TurnUsageMeter` (P8 max);
  build a stateful `CrossfadeController` (P6); SwiftUI-ify any spine node; turn
  `ModelStore`/completion stores into injected services; replace sidebar
  `reloadData()` with fine-grained diff; merge Compose + DraftLanding VCs.

---

## 6. The conformance test

**Every class MUST be placeable in the §0 ownership-table schema, with every cell
drawn from its closed vocabulary, and MUST satisfy §1–§5.** A class is
**conformant (✓)** iff all of:

1. **Placeable** — exactly one Layer, one Kind, one Owner/lifetime; not
   straddling two layers.
2. **Single owner** (C-1) and a legal constructor (C-2/C-3).
3. **Known data-in channel** ("Reads state via" ∈ the closed set) and **known
   data-out channel** ("Emits via" ∈ the closed set), each matching its §3 edge
   verdict.
4. **No illegal dependency direction** (L1): downward-only except the single
   `selectionObserver` edge.
5. **Correct host regime** (§4) if it is a hosting boundary, or "—".
6. **Violates no do-not-touch contract** (§5).

**An unplaceable class is a design defect, not a table defect.** If a class has
an ambiguous owner, an unclear/dual data-in or data-out channel, a wrong/unknown
host regime, or straddles two layers, mark it **`✗ + one-line issue`**. The
remedy is to fix the design (split it, give it one owner, pick its channel/regime)
— never to widen a vocabulary or invent a hybrid cell to make it "fit."

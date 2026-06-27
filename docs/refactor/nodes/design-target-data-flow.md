# Design: Target data-flow & state-ownership model (the data-flow constitution)

Status: design proposal. Read-only investigation produced it; no production code
was changed. Source root abbreviated `…` = `macos/ccterm`. FACT = read in code
(cited file:line). INFERENCE = my read / recommendation.

This document defines the **canonical** data-flow and ownership model the whole
app should follow, then resolves each specific bidirectional / back-channel debt
the cross-cutting analyses found, with a concrete recommended pattern and a
before→after for each. It is deliberately *descriptive first* — the existing
architecture is already ~90% of the target model (see
[analysis-component-tree.md](analysis-component-tree.md) §"Executive summary"),
so most of the work is **naming the rules that already hold**, deleting the few
real violations, and refusing the over-engineering that would damage the working
parts.

---

## 0. The one-paragraph thesis

CCTerm is an **AppKit-rooted shell with SwiftUI leaves**. There are exactly
**two** data-flow spines, and both are already unidirectional:

1. **Selection spine** — `MainSelectionModel.select(_:)` writes the `@Observable`
   `selection` AND synchronously notifies its *one* structural observer (the
   router). Down = `@Observable` read; structural-down = one synchronous
   delegate call; nothing flows back up. (FACT: `…/App/AppKit/MainSelectionModel.swift:53-57`)
2. **Session/render spine** — `Session` (façade) owns `Transcript2Controller` +
   `Transcript2EntryBridge` for its whole lifetime; runtime state reaches SwiftUI
   via `@Observable` *pull* and reaches the AppKit transcript via synchronous
   closure *push*. One channel per piece of state. (FACT: `…/Services/Session/CLAUDE.md`
   "Talking to the renderer")

The target model is: **keep both spines exactly as they are, write down the rule
that makes them unidirectional, and bring every stray edge into conformance with
that rule.** No global store. No ViewModel layer for session state. The
imperative calls that survive are the ones whose *correctness depends on a
runloop-tick ordering that `@Observable` cannot express* — those are not debt,
they are the reason the AppKit exceptions exist, and each is cited below.

---

## 1. The data-flow constitution (the crisp rule set)

These seven rules are the whole model. Everything in §3 is just "apply rule N to
debt M."

### Rule 1 — State lives at the lowest scope that all its readers share.

| State kind | Canonical home | Read by | Channel |
|---|---|---|---|
| Process-scope services | `AppState` (constructor-owned by `AppDelegate`) | router + child VCs + SwiftUI leaves | constructor injection (AppKit) / `.environment` (SwiftUI) |
| Window-scope selection / draft / archive-filter | `MainSelectionModel` | router (structural) + SwiftUI content | `@Observable` + the one `selectionObserver` |
| One session's business + render state | `Session` (façade over `.draft`/`.active`) | input bar, chrome, transcript host | `@Observable` forwarders (SwiftUI) / closure sinks (AppKit) |
| Transcript row model | `Transcript2Coordinator.blocks` | the table only | `Controller.apply` (the §3.4 contract) |
| View-private interaction state | SwiftUI `@State` (incl. `CompletionViewModel`, `GitProbe`) | that one view subtree | n/a — never escapes the view |

The test for "where does state X live": find every reader. The home is the
narrowest scope that contains all of them. A piece of state with exactly one
reader is `@State` (or a stored VC `var`), never a model field.

### Rule 2 — Data flows DOWN by reading `@Observable`; never by caching.

SwiftUI views read `session.X` / `model.X` directly in `body`. **No view holds
its own copy of a model field.** (FACT: this rule is already written at
`…/Services/Session/CLAUDE.md` "Rules" and `…/Content/Chat/CLAUDE.md` "Rules";
the design just elevates it to constitution status.) The pull model is what makes
the down-direction trivially unidirectional: there is nothing to keep in sync.

### Rule 3 — Events flow UP through exactly one of two channels, chosen by renderer.

- **SwiftUI consumer** → the view calls a **`Session` method** (`session.send`,
  `session.respond`, `session.setPermissionMode`, …) or an **injected closure**
  (`onSubmit`, `onAttachRect`, `onBuiltinCommand`). The view never reaches
  `session.runtime.X` and never writes a model `@Observable` field that has a
  mutator method.
- **AppKit consumer** (the transcript) → a **synchronous closure sink** declared
  on `SessionRuntime`, multiplexed once in `Session.wireRuntimeMessagesSink`,
  consumed by the bridge. (FACT: `…/Services/Session/CLAUDE.md` "Talking to the
  renderer".)

**Never emit one piece of state on both channels.** (Existing rule;
`…/Services/Session/CLAUDE.md`.)

### Rule 4 — There is exactly one structural back-edge: `selectionObserver`.

`MainSelectionModel` carries a single `@ObservationIgnored weak var
selectionObserver` (FACT: `MainSelectionModel.swift:45`). It exists because the
detail-side transition must land **in the same source phase as the click** —
`@Observable` re-eval happens a tick later at `beforeWaiting`, which fragments the
session switch across frames (FACT: doc comment `MainSelectionModel.swift:4-17`;
runloop model in root CLAUDE.md). This is the *only* upward structural edge in the
graph, it is single-owner, and it is **not** to be generalized into a notification
bus or a second observer slot. Any new "react structurally to selection" need is
the router's job, reached through the router, not a new observer registration.

### Rule 5 — Views never construct services; the ViewModel exception is narrow.

Services are constructed by `AppState`/`AppDelegate` and injected. The *only*
legitimate view-constructed `@Observable` objects are **view-private interaction
state machines** — today `CompletionViewModel` (input-method state),
`GitProbe` (branch list for one configurator), `BackgroundTaskOutputStream` (one
sheet's stream). These are `@State`, scoped to a view identity, and never escape
to coordinate model state. The chat-area "no ViewModel" rule
(`…/Content/Chat/CLAUDE.md:3,61`) is about **session/transcript state** — it
forbids a coordinating mirror of `Session`, not a self-contained popup controller.

### Rule 6 — An imperative call is allowed ONLY when its correctness depends on runloop-tick ordering that `@Observable` cannot give.

The default is reactive (`@Observable` down, method/closure up). An imperative
push (`controller.setLoading`, `router.present`, `select`'s synchronous notify) is
justified **only** when one of these holds, and the justification must be cited at
the call site:

- (a) it must run in the click's **source phase**, before `beforeWaiting`
  (selection notify, transcript attach);
- (b) it hands the AppKit consumer the **exact increment** instead of forcing a
  diff (`bridge.apply`, `setLoading`, `setTurnUsage`);
- (c) it must run on a stack that **survives a teardown** that would swallow a
  reactive `.onChange` (the draft-clear-on-send).

If none of (a)/(b)/(c) applies, use the reactive channel. §3 tags every retained
imperative call with which of these justifies it.

### Rule 7 — Dependencies are threaded as ONE bag of the CONSUMED services, not re-declared per type.

The DI surface is a single value type carrying the model + the *actually-consumed*
services. Adding/removing an app-scope dependency is a one-site edit. (Resolves
P1/P2; see §3.7.)

---

## 2. The target ownership tree (unchanged spine, cleaned edges)

This is the as-is tree from [analysis-component-tree.md](analysis-component-tree.md)
§1 with the **target** annotations: which edges are kept, which are deleted, and
which channel each carries. `[AK]`/`[SU]`/`[SVC]` as in that file.

```
AppDelegate [AK]  ── owns app-scope state, constructor-injects downward
├── appState: AppState [SVC]            (8 services; the DI source of truth)
├── searchBus: TranscriptSearchBus [SVC]   ⚠ move INTO AppState (Rule 1 — see §3.8)
├── selectionModel: MainSelectionModel [SVC]  (window-scope; stays on AppDelegate — see §3.8)
└── mainWindowController [AK]
    └── MainSplitViewController [AK]   ── builds ONE DetailContext bag (§3.7)
        ├── SidebarViewController [AK]     writes model.select(_:)   ↑ via the model method (Rule 3)
        └── DetailRouterViewController [AK, MainSelectionObserver]
            │     ▲ the ONE structural back-edge (Rule 4): model.selectionObserver = self
            │     owns: notifications.onActivateSession, sessionManager.onLaunchFailure  (single-owner push)
            ├── .transcript → ChatSessionViewController [AK]
            │     ── driven DOWN imperatively by router.present(sessionId:)  (Rule 6a)
            │     ── reads session.* via @Observable; pushes increments to controller (Rule 6b)
            │     └── «HV» ChatComposeStack [SU]   reads model.selection; events up via closures
            │           └── ChatRestingBar/InputBarChrome/InputBarView2 [SU]
            │                 ── reads session.* ; writes via Session methods + injected closures
            ├── .compose / .draftLanding / .archive → fill-pane VCs [AK]
            │     └── «HC» SwiftUI body, same injection set
            └── .demo(_) (DEBUG)
```

**The only change to the tree shape** is mechanical: collapse the 7-arg DI bag to
one `DetailContext`, drop two dead injections, and move `searchBus` onto
`AppState`. The spine, the hosting boundaries, the per-attach lifetimes, and the
single structural observer are **untouched**.

---

## 3. Per-debt fixes (the data-flow analysis's specific back-channels)

Each subsection: the debt, the rule that governs it, the recommended pattern, a
before→after, and an explicit parity note. Ordered to match the task brief.

### 3.1 Selection / router — the one structural back-channel. KEEP, document.

**Debt framing.** This is the deliberate upward edge (`selectionObserver`). The
"refactor toward unidirectional" instinct is to delete it and have the router
`withObservationTracking` on `model.selection` instead. **Reject that.**

**Rule:** Rule 4 + Rule 6(a).

**Why it must stay imperative (FACT, tick-ordering).** `select(_:)` runs in the
click's source phase. If the router observed `selection` reactively, its body
would re-arm at `beforeWaiting` — one tick later than the SwiftUI input bar's own
`@Observable` re-eval — and the transcript mount + the bar swap would land in
different frames, visibly fragmenting the switch. The doc comment at
`MainSelectionModel.swift:4-17` and `DetailRouterViewController.swift:42-57`
already spell this out; the merge gate is `DetailRouterContainmentTests`.

**Recommended pattern (no code change, only a constitutional promotion):** keep
`select(_:)` as the *sole* production mutator (direct `selection =` reserved for
pre-mount seeding + tests, FACT: `MainSelectionModel.swift:30-32`). Keep
`promote(to:)` as the re-fire for the unchanged-value draft→active case (FACT:
`:72-79`). Keep the router as the single observer. **Do not** add a second
observer slot; new structural reactions go through the router.

**Before→after:** unchanged. This debt is resolved by *documenting it as correct*
in the constitution (Rule 4/6a) so a future refactor doesn't "clean" it away.

**Parity:** identical behavior; the merge gate already pins it.

### 3.2 Rect-reporting (`onAttachRect` / `onPillRect`). KEEP as closures.

**Debt framing.** The chat bar reports the attach-button + pill rects up to
`ChatSessionViewController`, which converts them into bottom-scrim cutouts (FACT:
`ChatSessionViewController.swift:557-566` → `applyScrimCutouts` `:231-234`). A
"cleaner" instinct is to route these through a model `@Observable` field.

**Rule:** Rule 1 (lowest shared scope) + Rule 3 (closure-up for SwiftUI→AppKit).

**Why closures are already the right shape (FACT).** The rects have **exactly one
consumer** — the bottom scrim owned by this same VC. The doc comment at
`ChatSessionViewController.swift:96-101` says so: "Local to this VC — there's no
cross-VC consumer." By Rule 1, single-reader state does not belong on a
window-scope model; promoting it would be the opposite of clean (it would imply a
cross-VC dependency that doesn't exist). The closure delivers the geometry
**synchronously** to the AppKit scrim, with no `@Observable` re-eval hop in between
(Rule 6b: hand the consumer the exact value). Routing through `MainSelectionModel`
would add a tick of latency and a phantom dependency edge.

**Recommended pattern:** keep the two closures exactly. Optionally collapse the
two callbacks + two stored rects + `applyScrimCutouts` into one
`onChromeGeometry(attach:pill:)` callback firing both rects together — a pure
ergonomic tidy (one call site instead of two), **not** a channel change. (LOW
priority; do it only if touching this file anyway.)

**Before→after:** structurally unchanged; at most 2 closures → 1.

**Parity:** identical scrim cutouts; same synchronous timing.

### 3.3 Draft-clear-on-send. KEEP imperative — teardown-proof.

**Debt framing.** `InputBarView2.handleSend` clears the persisted draft with a
**direct** `draftStore.clear(key)` *before* `onSubmit` (FACT:
`InputBarView2.swift:467-473`), instead of relying on the reactive
`.onChange(of: text) → scheduleDraftSave` clear (`:206`). This looks like an
imperative shortcut that "should" be reactive.

**Rule:** Rule 6(c) — survives a teardown that swallows the reactive path.

**Why it must stay imperative (FACT, tick-ordering).** In compose mode `onSubmit`
promotes the draft and calls `model.select(.session(_))`, which swaps the routed
child VC **synchronously in the same source phase** (Rule 4). That tears down
`ComposeSessionViewController` and its hosted `InputBarView2` *before* SwiftUI
re-evaluates the body — so `.onChange(of: text)` never fires and a reactive clear
would be swallowed, leaving a stale new-session draft that reappears next time.
The comment at `:458-466` documents exactly this. The clear runs on the call
stack regardless of teardown.

**Recommended pattern:** keep the imperative clear. The constitution's Rule 6(c)
is written specifically to bless this one shape so it isn't "fixed" into
reactivity. (If desired, factor `text = ""; attachments = []; completion.dismiss();
draftStore.clear(key)` into a private `resetForSend()` for readability — same
stack, same order.)

**Before→after:** unchanged.

**Parity:** identical; the send-then-teardown ordering is preserved.

### 3.4 `setLoading` (and the `isRunning` observation task). KEEP imperative push.

**Debt framing.** `session.isRunning` reaches the input bar reactively
(`@Observable`), but reaches the transcript's trailing loading-pill row via an
**imperative** `controller.setLoading(_:)` driven by a `withObservationTracking`
task in the VC (FACT: `ChatSessionViewController.swift:525-541`, initial sync at
`:428`). Same state, two channels — which looks like a Rule-3 violation ("never
both channels").

**Rule:** Rule 3 + Rule 6(b). This is NOT a both-channels violation: the input
bar's send/stop button and the transcript's pill are **two different renderers**
of the same source field, each using its own correct channel. The rule forbids
emitting the *same render target* on both channels; here the targets are disjoint
(a SwiftUI button vs. an AppKit table row).

**Why the transcript side must stay imperative (FACT).** The loading pill is an
AppKit table row owned by `Transcript2Controller` (the pill row is the
controller's responsibility, not the bridge's — `…/Content/Chat/CLAUDE.md`
"Running-state rendering"). Driving it via `@Observable updateNSView` would be a
pull/diff model (Rule 6b: hand it the exact flip). `setLoading` also carries a
debounce + `reconcileLoadingPill` that is Controller-side logic
(`NativeTranscript2/CLAUDE.md` §1.1), not a dumb mirror.

**Recommended pattern:** keep `setLoading` imperative. The one *clarity* nit
worth fixing: the bespoke `withObservationTracking` while-loop task
(`:527-540`) is the same shape as `turnUsage`'s closure sink (`:438-442`). For
**consistency** (not correctness), `isRunning` could be delivered by the same
**closure-sink** pattern the rest of the AppKit channel uses — declare
`onIsRunningChange` on `SessionRuntime`, forward through `Session`, fire it
synchronously at the mutation site, and have the VC's sink call `setLoading`.
That removes the lone `withObservationTracking` re-arm task from the chat VC and
makes *every* AppKit-bound runtime signal use one channel shape (sinks), matching
`…/Services/Session/CLAUDE.md` "Adding new runtime state" step 4.

- **This is OPTIONAL and MEDIUM-risk.** The observation task already works and is
  `nonisolated`-deinit-safe. Adopt it only as part of the P8 runtime-sink cleanup,
  with the existing reentry tests green. If not adopting, keep the task and cite
  Rule 6(b) at the call site.

**Before→after (optional):**

```
// before — chat VC owns a withObservationTracking re-arm loop
runningObservationTask = Task { while … withObservationTracking { _ = session.isRunning } … setLoading }
// after — same closure-sink shape as onTurnUsageChange
session.onIsRunningChange = { [weak self, weak session] running in
    guard let self, let session, self.currentSession === session else { return }
    session.controller.setLoading(running)   // exact flip, synchronous (Rule 6b)
}
```

**Parity:** the pill flips on the same `isRunning` transitions; the initial
`setLoading(session.isRunning)` on attach (`:428`) is preserved. The SwiftUI
send/stop button is untouched (still reactive).

### 3.5 `pendingPermissions`. KEEP read-only `@Observable` forward.

**Debt framing.** The permission card reads `session.pendingPermissions.first`
reactively and writes the decision via `session.respond(...)` (FACT:
`InputBarChrome.swift:143-155`). The survey
([survey-permission-cards.md](survey-permission-cards.md) §3) confirms **both
directions are already clean and unidirectional**. The *only* real coupling is
geometric (card size → host intrinsic height), which the survey scopes **out** of
the data-flow model (it's a layout problem, §5/§6 there).

**Rule:** Rule 2 (read `@Observable`, never cache) + Rule 3 (write via `Session`
method).

**Why it's already correct (FACT).** Read path: `SessionRuntime.pendingPermissions`
(`@Observable internal(set)`) → `Session.pendingPermissions` read-only forward →
card. Write path: card closure → `Session.respond(to:decision:)` → `runtime.respond`
→ `pending.respond`. The card holds no copy. Pinned by `PermissionCardWiringTests`.

**Recommended pattern:** **no data-flow change.** This is the textbook application
of Rules 2+3 and should be cited as the *exemplar* in the constitution. The
geometric coupling is a separate design (the card-over-bar work in
survey-permission-cards §7); it does not touch the data-flow model and is out of
scope here. Explicitly: **do not** try to "fix" the card by moving
`pendingPermissions` to a model field or adding a presentation flag — that would
*introduce* a back-channel where none exists.

**Before→after:** unchanged.

**Parity:** identical; merge gate already pins it.

### 3.6 Completion's `CompletionViewModel`. KEEP; clarify it's not a violation; optional rename.

**Debt framing.** `CompletionViewModel` is the lone `…ViewModel` in a "no
ViewModel" area, which reads as a rule violation
([survey-completion.md](survey-completion.md) Smell #3). Its one true
back-channel is confirm→text-mutation (VM → View → NSTextView), which is intrinsic
to a completion UI (survey invariant #7).

**Rule:** Rule 5 — view-private interaction state machine is a legitimate
`@State` `@Observable`, distinct from the forbidden session-mirror ViewModel.

**Why it's not a violation (FACT + INFERENCE).** It is `@State` in `InputBarView2`
(one per session input bar, FACT: `CompletionViewModel.swift` via
`InputBarView2.swift:167`), holds only popup-private state (selected index,
debounce, transient query), and **never escapes** to coordinate `Session` state.
The chat "no ViewModel" rule targets a coordinating mirror of session/transcript
state; this is an input-method state machine SwiftUI's own idiom (`@Observable`
object too big for scattered `@State`) is built for.

**Recommended pattern:**
1. **Rename to `CompletionState` (or `CompletionController`)** so it stops reading
   as a rule breach at a glance. Pure rename; LOW priority, cosmetic.
2. **Delete the dead directory-completion path** (survey Smell #1:
   `DirectoryCompletionItem`, `DirectoryCompletionProvider`,
   `validateAndConfirmFromInput`/`tryConfirmFromInput`/`hasInputValidation`,
   `onDeleteRecent`, the "recent" pill). This shrinks the `CompletionSession`
   surface from 7 closures to the 4 that slash + @ actually need — the single
   biggest *unidirectional-clarity* win in this subsystem, with **zero** behavior
   change (nothing constructs those items). This is the real fix; the rename is
   garnish.
3. **Keep** the confirm→text back-channel (invariant #7) — it is intrinsic and
   correct.

**Before→after:** type renamed; ~3 of 7 `CompletionSession` closures + 2 types +
2 UI branches deleted. The inbound flow (config → context → rule → session →
provider → items) is already cleanly unidirectional and stays.

**Parity:** dead code deletion is behavior-preserving by construction; the rename
is mechanical. Slash + @ completion, the generation guard, the prewarm, and the
builtin dispatch are all untouched (survey invariants #1, #4–#10).

### 3.7 DI bag — collapse the 7-arg fan-out to one `DetailContext`; drop 2 dead injections.

**Debt framing (the highest-value, lowest-risk structural win).** The same 7
services are re-declared as stored props + an identical 7-arg `init` + identical
`@available init?(coder:)` across the router and all 5 child VCs, and the 6-line
`.environment(...)` block is copy-pasted 5× (FACT: P1/P2 in
[analysis-component-tree.md](analysis-component-tree.md) §4;
`MainSplitViewController.swift:29-37`, `DetailRouterViewController.swift:71-131,363-410`,
`ChatSessionViewController.swift:124-141,576-581`, the three other child VCs).
**Two of the injected services are dead:** `NotificationService` and
`TranscriptSearchBus` have **zero `@Environment` consumers** in any SwiftUI view
(VERIFIED by grep this session: `@Environment(NotificationService` → 0,
`@Environment(TranscriptSearchBus` → 0; the actually-consumed env set is exactly
`SessionManager`, `RecentProjectsStore`, `InputDraftStore`, `\.syntaxEngine`).

**Rule:** Rule 7.

**Recommended pattern.** Two small, independent pieces:

1. **`DetailContext` value bag** — a `struct` carrying the model + the services
   the children actually need at the AppKit layer:
   ```swift
   @MainActor struct DetailContext {
       let model: MainSelectionModel
       let sessionManager: SessionManager
       let recentProjects: RecentProjectsStore
       let inputDraftStore: InputDraftStore
       let syntaxEngine: SyntaxHighlightEngine   // renamed from `searchEngine` (P10b)
       let searchBus: TranscriptSearchBus        // consumed by the toolbar bridge path, not SwiftUI env
   }
   ```
   `MainSplitViewController` builds one `DetailContext` from `appState`; the router
   stores it and forwards it whole into `makeChild`. Each child VC takes
   `init(context: DetailContext)`. Adding/removing an app-scope dep is now a
   one-site edit on the struct.

2. **`View.injectChatEnvironment(_:)` helper** — one extension method that applies
   the **consumed** env set in one place, replacing the 5 copy-pasted blocks:
   ```swift
   extension View {
       func injectChatEnvironment(_ ctx: DetailContext) -> some View {
           self.environment(ctx.sessionManager)
               .environment(ctx.recentProjects)
               .environment(ctx.inputDraftStore)
               .environment(\.syntaxEngine, ctx.syntaxEngine)
       }
   }
   ```
   **Drop `.environment(notifications)` and `.environment(searchBus)` entirely** —
   no SwiftUI view reads them. `searchBus` reaches its consumer (the toolbar search
   field bridge) through the AppKit `controllerProvider` pull, not the SwiftUI
   environment (FACT: `MainWindowController` toolbar bridge); `notifications`
   reaches its consumer through `notifications.onActivateSession` push owned by the
   router (`DetailRouterViewController.swift:162`). Neither needs an env edge.

**Scope note.** `searchBus` stays in `DetailContext` because the router/VC layer
still threads it (for the AppKit toolbar path), but it is no longer pushed into the
SwiftUI environment. If a later audit confirms the toolbar bridge reads it
straight off `AppState` (it can, once `searchBus` moves there — §3.8), the field
can leave `DetailContext` too. Don't over-reach in one step.

**Why not inject `AppState` whole?** Because the model (`MainSelectionModel`) is
**not** part of `AppState` (it's window-scope, owned by `AppDelegate`), so an
`AppState`-only injection couldn't carry it; and injecting the whole container
would re-import the dead services into every view's reachable surface — the
opposite of the clarity goal. `DetailContext` carries *exactly* the consumed set.
(This also corrects the root-CLAUDE.md drift that says `AppState` is "injected
through `.environment()`" — it never is; FACT P11.)

**Before→after:**
```
// before: 7 stored props + 7-arg init + init?(coder) + 6-line .environment block,
//         repeated across router + 5 child VCs; makeChild repeats the 7-arg call 4×.
// after:  one `let context: DetailContext` per VC; init(context:); one
//         `.injectChatEnvironment(context)`; makeChild passes `context` whole.
```

**Parity:** the consumed environment set is **identical** to today's effective set
(the two dropped injections have no readers, so removing them is a no-op by
construction). No behavior change; this is pure boilerplate collapse. Tests that
construct child VCs update to the one-arg init.

### 3.8 Ownership-pattern reconciliation — `searchBus` onto `AppState`; document the rest.

**Debt framing.** Ownership is inconsistent (FACT P11): 8 services on `AppState`,
`searchBus` + `selectionModel` on `AppDelegate`, 3 `.shared` singletons
(`ModelStore`/`EffortDefaultStore`/`NewSessionDefaultsStore`), 2 completion stores
also singletons. The root CLAUDE.md claims `AppState` is `.environment`-injected
(it isn't).

**Rule:** Rule 1 (lowest shared scope) + Rule 5 (services are injected).

**Recommended pattern (judgment, balanced against "no over-engineering"):**

- **Move `searchBus` onto `AppState`.** It's process-scope state with the same
  lifetime as the other 8 services; living on `AppDelegate` is an accident of
  history. One field move; `MainSplitViewController` reads `appState.searchBus`.
  (LOW risk, improves consistency.)
- **Keep `selectionModel` on `AppDelegate`.** It is **window-scope**, not
  process-scope: it models *this window's* selection. Conceptually it belongs to
  the window shell, not the app-services container. Leaving it on `AppDelegate`
  (which here == the single window owner) is correct under Rule 1. Document the
  distinction rather than forcing it onto `AppState`.
- **Leave the 3 UserDefaults-backed singletons** (`ModelStore`,
  `EffortDefaultStore`, `NewSessionDefaultsStore`) **as `.shared`.** They are
  process-wide caches of process-wide defaults; a single instance is genuinely
  correct and injecting them buys nothing but ceremony. (This is a deliberate
  *do-not-over-engineer* call. `ModelStore` — which spawns a CLI subprocess — is
  the most arguable; flag it for a *separate* future decision, don't fold it into
  this refactor.)
- **Leave the 2 completion stores** (`FileCompletionStore`, `SlashCommandStore`)
  **as `.shared`** for the same reason — a per-cwd cache wants one process-wide
  instance (survey-completion Smell #4 weighs this and lands "balanced by the fact
  that a per-directory cache genuinely wants a single process-wide instance").
- **Fix the doc drift:** root CLAUDE.md should say app-scope services are
  **constructor-injected** (AppKit) and **`.environment`-injected** (SwiftUI
  leaves), and that `AppState` is destructured into a `DetailContext`, never
  injected whole.

**Before→after:** `searchBus` field moves AppDelegate→AppState; doc corrected;
everything else documented-as-is.

**Parity:** `searchBus` has the same lifetime and the same single reader path; the
move is a no-op at runtime. Singletons unchanged.

---

## 4. Summary table — every edge, its channel, and the verdict

| Edge | Direction | Channel today | Verdict | Rule |
|---|---|---|---|---|
| `select(_:)` → router | structural down | synchronous delegate | **KEEP** (tick-order) | 4, 6a |
| `model.selection` → SwiftUI content | down | `@Observable` | KEEP | 2 |
| sidebar → selection | up | `model.select(_:)` method | KEEP | 3 |
| router → chat VC | down | imperative `present(sessionId:)` | KEEP (tick-order) | 6a |
| `session.*` → SwiftUI | down | `@Observable` forwarders | KEEP | 2 |
| bridge → transcript | down | synchronous closure → `apply` | KEEP (exact increment) | 3, 6b |
| `isRunning` → loading pill | down | imperative `setLoading` + obs task | KEEP; OPTIONAL: closure-sink for consistency | 3, 6b |
| `turnUsage` → pill | down | closure sink `onTurnUsageChange` | KEEP | 3, 6b |
| chrome rects → scrim | up | injected closures | KEEP (single reader, sync) | 1, 3, 6b |
| draft-clear on send | side effect | imperative `draftStore.clear` | KEEP (teardown-proof) | 6c |
| card decision | up | `session.respond(...)` | KEEP (exemplar) | 3 |
| `pendingPermissions` → card | down | `@Observable` forward | KEEP (exemplar) | 2 |
| completion confirm → text | up | VM → View → NSTextView | KEEP (intrinsic) | 5 |
| `BackgroundTaskButton` → `runtime.markTaskStoppedLocally` | up | **pierces façade** | **FIX** → `Session.stopBackgroundTask` | 3 |
| 7-arg DI bag, 2 dead env injections | down | per-type re-declare | **FIX** → `DetailContext` + helper; drop dead | 7 |
| `searchEngine` param name (is the highlighter) | — | mis-named | **FIX** → rename `syntaxEngine` | (clarity) |
| `searchBus` / `selectionModel` on AppDelegate | ownership | split | `searchBus`→AppState; `selectionModel` stays (window-scope) | 1 |

### 4.1 The one genuine violation to FIX: `BackgroundTaskButton` (P4)

This is the single unidirectional-flow violation in production UI: a SwiftUI view
reaches `session.runtime.markTaskStoppedLocally(taskId:)` directly (FACT:
`…/Content/Chat/InputBarControls/BackgroundTaskButton.swift:81-83`), bypassing the
`Session` façade — violating Rule 3 ("the view never reaches `session.runtime.X`").

**Fix (one-line forwarder, strengthens the invariant):** add a phase-aware
`Session.stopBackgroundTask(taskId:)` that routes to `runtime?.markTaskStoppedLocally`
(no-op on `.draft`), mirroring the existing `requestContextUsage` forwarder. The
button then calls `session.stopBackgroundTask(taskId:)`. The fix is in the product
(adding the missing forwarder), never in a test — per the engineering principles.

**Before→after:**
```
// before
guard let runtime = session.runtime else { return nil }
return { taskId in runtime.markTaskStoppedLocally(taskId: taskId) }
// after
return { taskId in session.stopBackgroundTask(taskId: taskId) }   // façade forwarder
```

**Parity:** identical behavior on active sessions; safe no-op on drafts (the button
can't appear on a draft today, so this only hardens the boundary).

---

## 5. Rejected alternatives (and why)

1. **A global app store / Redux-style single source of truth.** Rejected. The two
   spines already give a clean unidirectional flow at the *right* scopes
   (process / window / session). A global store would flatten three correct scope
   boundaries into one and force every transcript increment through a reducer —
   destroying the synchronous closure push the §2 perf contract and the
   `bridge.apply` exact-increment model depend on (Rule 6b). It is clean-for-its-
   own-sake complexity that the task explicitly forbids.

2. **A coordinating ViewModel for the chat pane.** Rejected. The chat area's
   "no ViewModel" rule (`…/Content/Chat/CLAUDE.md:3,61`) is load-bearing: session
   state lives on `Session` and views read `@Observable` directly. A ViewModel
   would reintroduce the shadow-copy / sync problem the pull model eliminates.
   (`CompletionViewModel` is the *allowed* narrow exception — view-private state,
   not a session mirror; Rule 5.)

3. **Make the router observe `selection` reactively (delete `selectionObserver`).**
   Rejected — would fragment the session switch across runloop ticks (§3.1, Rule
   6a). The synchronous delegate is the whole point of the design.

4. **Promote rect-reporting / draft-clear / `pendingPermissions` to model fields
   for "uniformity."** Rejected. Each would *add* a back-channel or a phantom
   cross-VC dependency where none exists (single-reader rects), break a teardown-
   proof path (draft-clear), or convert a clean read-only forward into a
   round-tripped flag (permissions). Uniformity is not the goal; correct scope is.

5. **Inject `AppState` whole via `.environment`.** Rejected. Can't carry the
   window-scope `MainSelectionModel`, and re-imports the dead services into every
   view's reachable surface. `DetailContext` carries exactly the consumed set
   (§3.7).

6. **Convert the completion stores / `ModelStore` to injected services.**
   Rejected (for this refactor). A per-cwd / per-process cache genuinely wants one
   instance; injecting buys ceremony, not clarity. Flagged as a *separate* future
   decision so it doesn't bloat the data-flow cleanup (no-over-engineering).

7. **Merge `Transcript2Controller` + `Transcript2Coordinator`** (tempting while
   "cleaning" the render spine). Rejected — explicitly load-bearing
   (`NativeTranscript2/CLAUDE.md` §1.1: conformance constraints, file size,
   real-logic-not-forwarding). Out of scope for data flow.

---

## 6. Risks

- **R1 — `DetailContext` migration touches the init of 5 VCs + the router + tests.**
  Mechanical but wide. Mitigation: it's the lowest-*risk* structural change
  (pure DI plumbing, no behavior); land it first, behind a green build + the
  existing containment / reentry tests. The two dropped injections are provably
  dead (grep = 0 consumers), so removing them cannot change behavior.

- **R2 — Renaming `searchEngine` → `syntaxEngine`** touches ~6 files. Pure rename,
  no behavior; risk is only mechanical (miss a site → compile error, caught by the
  build). Pairs with R1.

- **R3 — Optional `isRunning` closure-sink (§3.4)** is the only data-flow change
  that touches the runtime sink wiring. MEDIUM risk: a new synchronous sink on
  `SessionRuntime` must fire at the right mutation site and survive promotion
  (`wireRuntimeMessagesSink` pattern). Mitigation: it's **optional** — skip it
  unless doing the P8 runtime cleanup, and keep the existing observation task
  otherwise (it works). Drive it through the public surface; do not add a test
  hook.

- **R4 — `searchBus` move to `AppState`** could break the toolbar bridge if it
  reads via the old `AppDelegate` path. Mitigation: update the single read site;
  it's a field relocation with one reader.

- **R5 — Deleting the dead completion path (§3.6)** could in theory remove a path
  something still calls. Mitigation: the survey proves zero callers/constructors by
  grep; the `BuiltinSlashCommandTests` + completion tests are the gate. Land it as
  a separate behavior-preserving deletion commit.

- **R6 — Constitutional drift.** The biggest risk is that a *future* refactor reads
  "unidirectional" and deletes one of the deliberately-imperative edges (§3.1/3.3/
  3.4/3.5). Mitigation: Rule 6 names the three runloop-tick justifications and §3
  cites each call site, so the constitution itself defends them.

---

## 7. Do-not-touch (load-bearing things this design preserves)

- **The §2 transcript performance contract** (`NativeTranscript2/CLAUDE.md` §2,
  all items) and the **§2.19 single-width attach contract** + its two merge gates.
  Nothing in this design touches the transcript renderer, `layoutCache`,
  `apply`/`Change`, or the attach choreography.
- **The synchronous single-observer selection spine** (`select(_:)` source-phase
  notify; router as sole structural owner; chat VC does not observe selection;
  `promote(to:)` re-fire). (§3.1.)
- **`Session` owns `controller` + `bridge` for its whole lifetime**; bridge wired
  once; live events flow with no view mounted; O(1) warm re-entry.
- **The two disjoint render channels** (`@Observable` pull for SwiftUI; synchronous
  closure push for the transcript) and "one channel per render target."
- **Handle-free `InputBarView2`** (no `Session`; inputs by value; mutations via
  closures; `.id(sid)` reset; teardown-proof draft-clear).
- **Deterministic teardown** (`DetailRouterChild.prepareForRemoval`) and the
  `nonisolated deinit {}` macOS-26 workaround on every `@MainActor @Observable`/VC.
- **Host-sizing discipline** (`[]` fill-pane vs `[.intrinsicContentSize]`
  component) — unchanged.
- **The crossfade ordering invariants** in `attachSession` (build-in-front,
  disabled-CATransaction scoping, flush-before-bind `removeObserver` ordering) and
  the router's cross-kind crossfade. This design does not refactor either state
  machine (that is P5/P6, out of scope here).
- **The completion load-bearing invariants** (generation guard, derived `isActive`,
  fresh-per-call trigger context, builtin shadow + order, confirm side-effect
  order) — the §3.6 deletion only removes provably-dead members.

---

## 8. Parity guarantee (explicit)

Every change in this design is one of three behavior-preserving kinds:

1. **Documentation-only** (§3.1, §3.2-keep, §3.5, §8 do-not-touch): the code does
   not change; the constitution names why the existing edge is correct.
2. **Provably-dead-code deletion** (the two env injections in §3.7; the directory-
   completion path in §3.6): grep-verified zero consumers/constructors, so removal
   cannot alter runtime behavior.
3. **Behavior-preserving plumbing** (`DetailContext` collapse, `searchEngine`→
   `syntaxEngine` rename, `searchBus`→`AppState` move, the `Session.stopBackgroundTask`
   forwarder): same values reach the same consumers through a tidier surface; the
   `BackgroundTaskButton` fix routes the *identical* call through the façade.

The single optional change (§3.4 `isRunning` closure-sink) is explicitly gated on
the P8 runtime cleanup and the green reentry tests, and delivers the *same* pill
flips on the *same* `isRunning` transitions.

No feature is removed or degraded. The transcript performance/attach contracts,
the selection spine, the render channels, and every cited runloop-tick invariant
survive unchanged. Existing merge gates (`DetailRouterContainmentTests`,
`TranscriptReentryLayoutCacheTests`, `TranscriptHostReentryLayoutCacheTests`,
`ChatComposeStackRoutingTests`, `PermissionCardWiringTests`,
`BuiltinSlashCommandTests`, the façade/promotion tests) remain the regression net;
the DI-plumbing changes update only VC-construction call sites in tests, not
assertions.

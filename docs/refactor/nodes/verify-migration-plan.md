# Adversarial verification — design-migration-plan.md

Read-only review of `docs/refactor/nodes/design-migration-plan.md` against the
actual source at `macos/ccterm`. Verdict per the rubric: perf-contract safety,
functional parity, over-engineering, premise correctness, feasibility.

## Verdict: **sound-with-fixes**

The plan is well-grounded. Its central premises about the load-bearing
invariants are accurate (verified at file:line below), it touches the
transcript choreography last and as a *verbatim move* behind the two real merge
gates, and it explicitly subordinates the dedup prizes (P6/P9) so they can't
sacrifice the I5 ordering. **No step weakens a §2 / §2.19 / runloop invariant** —
the one step that gets near (Step 11) is correctly fenced. The fixes below are
accuracy/scoping corrections and two feasibility caveats the plan understates;
none is a blocker.

---

## Perf-contract safety: PASS (no blockers)

- **§2 renderer interior is never entered.** Confirmed: no step proposes touching
  `Transcript2Coordinator`/`BlockCellView`/cache/highlight internals. The closest
  is Step 11, which is a host-side relocation.
- **§2.19 attach contract is preserved verbatim.** I read the real sequence at
  `App/AppKit/ChatSessionViewController.swift:341-392`: `factory.make` (unbound,
  :341) → `addSubview(positioned:.below)` + 4-edge constraints (:353-359) →
  `view.layoutSubtreeIfNeeded()` (:366) → `factory.bindData` (:367) →
  `scrollToTail()` (:386). The plan's §1.2 description matches byte-for-byte. Step
  11 is specified as a move with both gates (`TranscriptReentryLayoutCacheTests`,
  `TranscriptHostReentryLayoutCacheTests` — both exist on disk) green before and
  after, and a "read the offender report, never widen tolerance / XCTSkip" rule.
  This is the correct guard.
- **chat-I5 outgoing-flush-before-bind is honored.** `finishTranscriptFadeOut()`
  is at the head of `attachSession` (`ChatSessionViewController.swift:306`), before
  `bindData` (:367), exactly as §1.3 claims, with the `dismantle` →
  `removeObserver(coordinator)` shared-coordinator rationale spelled out in the
  source comment (:296-305). The plan flags this as "the single most fragile
  ordering" and mandates a verbatim move — appropriate.
- **chat-I3 disabled-CATransaction scoping** (structural inside the
  `setDisableActions(true)` block :338-339, opacity outside) is real and the plan
  preserves it.
- **Host-sizing discipline** is respected. Step 6 correctly keeps the chat bar
  host at `[.intrinsicContentSize]` (`ChatSessionViewController.swift:169`) OUT of
  the fill-pane helper, and keeps fill-pane hosts at `[]` (verified at
  `ArchiveViewController.swift:102`, `ComposeSessionViewController.swift:115`,
  `DraftSessionLandingViewController.swift:136`, `DetailRouterViewController.swift:443`).
  The window-collapse failure mode is documented in source (`ArchiveViewController.swift:84-101`,
  the `545×276` fitting-size leak) exactly as the plan cites.

No perf-contract weakening anywhere. The `breaksPerfContract` flag is **false**.

---

## Functional parity: PASS with one omission to track

Every step is a deletion-of-dead, a compiler-enforced rename, additive plumbing,
or a verbatim move. I found no step that silently drops a user-facing feature.
The §9 parity checklist maps features to protecting tests competently.

One omission (Minor, below): the plan does not sequence its interaction with the
**permission-card overlay** fix that lives in the sibling doc
`design-painpoint-fixes.md` (§0). That proposal adds a *new sibling overlay* to
`ChatSessionViewController` — the exact VC Step 11 is restructuring. The migration
plan scopes card-coupling out (defensible — it's a behavior fix, not a tree
refactor), but it never states the ordering dependency, so a naive execution
could land Step 11 and the overlay fix in conflicting PRs on the same file.

---

## Premise correctness: mostly accurate; three undercounts

Verified true:
- P1 dead env injections — `grep` for `@Environment(NotificationService` /
  `Environment(... TranscriptSearchBus` returns **0 SwiftUI readers** (confirmed);
  `notifications` is used only imperatively at `DetailRouterViewController.swift:162,173`.
  All 5 injection sites + the demo at `:434-435` exist as cited.
- P4 — `BackgroundTaskButton.swift:80-83` is `guard let runtime = session.runtime`
  then `runtime.markTaskStoppedLocally(taskId:)` inside the `stopAction` closure.
  There is no `Session.stopBackgroundTask` forwarder. Confirmed.
- P10(b) rename — 30 `searchEngine` references across the 6 cited types. Notably
  the *demo* VCs already take a param named `syntaxEngine`
  (`DetailRouterViewController.swift:416-422`) and the `\.syntaxEngine` env key
  already exists — so the rename target name is already in use in adjacent code,
  which confirms the inconsistency is real and the rename has no collision.
- Sizes: `SidebarViewController` = 770 lines, `SessionRuntime*` = 3249 total,
  `ChatSessionViewController` = 679. All match.
- P7 — two grouping engines (`SessionRuntime+Receive.swift:274` forward,
  `ReverseEntryBuilder.swift:63` reverse) sharing only `isGroupableAssistant`
  (`SessionRuntime+Receive.swift:701`, whose comment literally says it is
  module-internal "so `ReverseEntryBuilder` applies the same grouping rule"). Real.
- Ownership: `selectionModel` + `searchBus` are on `AppDelegate` (`AppDelegate.swift:31,34`),
  NOT on `AppState` (`AppState.swift:7-14`). Step 5's "don't inject AppState"
  rationale is therefore correct.

Undercounts / inaccuracies (all Minor):
1. **Step 7 `RootView2` references** — the plan says "in `InputBarView2`/
   `NewSessionConfigurator`." Actually `RootView2` is referenced (in doc comments)
   across **8 files** including `MainSplitViewController`, `MainSelectionModel`,
   `ChatSessionViewController`, `FadeScrim`, `SessionRuntime`. Doc-only, so the
   undercount only makes the cleanup incomplete, not unsafe.
2. **Step 6 fill-pane host count** — plan says "Three full-pane VCs ... + the demo
   cards." There are actually **5** fill-pane `[]` sites (compose, draft-landing,
   archive, router demo `:443`, and `PermissionSessionDemoViewController.swift:134`).
   The plan mentions the demo but the "three" undercounts; the helper should cover
   all of them or explicitly exclude the demo VC.
3. **Step 3 "pure removal"** — `DirectoryCompletionItem` is referenced (as failed
   `as?` downcasts and `onDeleteRecent` plumbing) in `InputBarView2.swift:254-258`
   and `CompletionListView.swift:185,192`, not just its own file. "Never
   constructed" is correct (the downcasts can never match), but deleting it edits
   **live files**, so the rollback note "pure removal — no migration" understates
   the edit surface. `ClaudeCodeStats` is genuinely consumer-less (only its own
   file + test). Fine.

---

## Over-engineering: mostly disciplined; one borderline

The plan is generally good about this — it explicitly *rejects* P9 (façade
forwarder protocol), *defers* P11 (singleton reconciliation), and folds P14/P15
opportunistically. That matches the user's "no clean-for-its-own-sake" stance.

Borderline:
- **Step 11's shared crossfade helper (P6).** The two crossfade bodies
  (`ChatSessionViewController.swift:476-506` vs `DetailRouterViewController.swift:336-361`)
  share a *shape* but differ in the animated object (`Transcript2ScrollView.alphaValue`
  vs `NSViewController.view.alphaValue`) and the teardown (`dismantle` scroll +
  `removeFromSuperview` vs `prepareForRemoval` + `removeFromSuperview` +
  `removeFromParent`). The animation body is ~6 lines each. A generic helper
  parameterized over "thing to fade" + "teardown closure" earns little and risks
  obscuring I5. The plan *already hedges* ("keep the two implementations separate
  if the shared helper can't express I5 cleanly; P6 is the lower prize") — so this
  is acknowledged, but the hedge should be promoted to the **default**: do the P5
  cohesion extraction, and only attempt the P6 helper if it reads cleaner than two
  6-line methods. As written, Step 11 lists the helper as in-scope, which invites
  ceremony on the single most fragile file.

No other step adds an abstraction that fails to earn its keep. `injectAppEnvironment`
+ `DetailChildDependencies` (Step 5) genuinely collapse a 5×-copied env block and a
7-arg bundle re-declared 6 times — that earns its keep.

---

## Feasibility: implementable, with two caveats

- **Step 5 (DI struct)** is feasible; the missed-env-injection-is-a-runtime-fatal
  risk is real but the plan's "centralize into one helper removes the class going
  forward" is the correct mitigation.
- **Step 11** is feasible as a pure move (the bodies relocate intact). The merge
  gates exist and the plan's de-risking protocol is sound.
- **CAVEAT — Step 12 observation graph (Major).** The plan frames
  `TodoTracker`/`TaskTracker`/`TurnUsageMeter`/`ContextUsageCache` uniformly as
  "value or sub-objects." But the actual fields split two ways on `SessionRuntime`:
  `turnUsage` / `turnStartedAt` are `@ObservationIgnored` (AppKit-pushed via
  `onTurnUsageChange`, `SessionRuntime.swift:258-262`), while `tasks` / `todos` /
  `contextUsage` are **`@Observable`** (`:339,347,310`) and SwiftUI views read them
  through `Session` forwarders. Extracting the value ones (`turnUsage`,
  `contextUsage` cache) into plain structs is trivial. Extracting the *observed
  collections* (`tasks`, `todos`) into a sub-object means the sub-object must be
  `@Observable` AND held by an `@Observable`-tracked property so nested mutation
  still propagates to `session.todos` readers — doable with `@Observable` nesting,
  but it is NOT the trivial "value type" extraction the plan implies, and a
  careless move (e.g. a non-observable holder, or reading the snapshot by value)
  silently breaks the todo/task button live updates. The plan must call this out
  and the `SessionRuntimeTodosTests`/`…TasksTests` must assert live re-render, not
  just final value. (The plan does list those tests; it just doesn't flag the
  observation-nesting subtlety.)
- **CAVEAT — Step 4 forwarder style (Minor).** The plan's proposed
  `stopBackgroundTask` uses `guard case .active(let runtime) = phase else { return }`,
  but its cited mirror `requestContextUsage` (`Session.swift:393-402`) actually
  uses `guard let runtime` (the computed accessor at `:280`). Functionally
  identical; use `guard let runtime` to match the established forwarder idiom.

---

## What I endorse

- The four-phase ordering (mechanical → DI collapse → god-object split →
  choreography last) is the right risk gradient.
- Treating Step 11 as a **verbatim move behind both merge gates**, with an
  explicit "read the offender report, never XCTSkip / widen tolerance" rule.
- The "don't inject AppState as a whole" granularity for Step 5 (correct: the
  model is owned by AppDelegate, not AppState — verified).
- Rejecting P9 (façade protocol) and the Controller/Coordinator merge; deferring
  P11. These match the no-over-engineering constraint.
- Keeping the chat bar host's `[.intrinsicContentSize]` asymmetry OUT of the
  fill-pane helper (Step 6) — the window-collapse-sensitive distinction is real.
- Step 4 strengthening the façade invariant (fix in product, not test).
- The §9 parity checklist's feature→test mapping.

## Required fixes before execution (none blocking, all addressable in-plan)

1. Step 12: add the observation-nesting caveat for `tasks`/`todos`/`contextUsage`;
   require live-re-render assertions.
2. Step 11: demote the P6 shared crossfade helper to optional/default-off; do P5
   cohesion first, attempt P6 only if it reads cleaner than two 6-line methods.
3. Step 6: cover all 5 fill-pane sites (incl. `PermissionSessionDemoViewController`)
   or explicitly exclude the demo.
4. Step 7: widen the `RootView2` doc-cleanup to all 8 referencing files.
5. Step 3: correct the rollback note — deletion edits live files
   (`InputBarView2`, `CompletionListView`), not a pure file removal.
6. Step 4: use `guard let runtime` to match the `requestContextUsage` idiom.
7. Cross-doc: state the sequencing dependency with the permission-card overlay fix
   in `design-painpoint-fixes.md` (both restructure `ChatSessionViewController`).

# Clean-context review — lens: Architecture & data-flow soundness

**Verdict: sound-with-fixes.**

The plan's as-is tree (§2), data-flow constitution (§6), and edge-verdict table (§6.1) are
unusually accurate against the real code. I spot-checked every load-bearing claim that drives a
structural decision and found the plan's facts correct, its one true unidirectional violation (P4)
correctly identified and fixed in the product, and its DI consolidation (P2) genuinely a 1-site win.
The "keep these imperative edges" verdicts are grounded in real runloop ordering, not rationalized
debt. The fixes below are gaps/underspecifications, not falsified premises.

## Blocker check result

**No blockers.** No proposed structural change breaks the transcript §2 performance contract, regresses
functionality, or pivots on a false premise. The plan explicitly routes around §2 / §2.19 (§10) and
the highest-risk item (P5 `TranscriptSwapCoordinator`) is verbatim-move + merge-gate-guarded.

---

## What I verified (FACT, with citations)

**As-is tree (§2) + host table (§2.1) — accurate.**
- `composeOrBarHost` is `NSHostingView(rootView: AnyView(makeComposeOrBarStack()))`,
  `sizingOptions = [.intrinsicContentSize]`, bottom-anchored, centerX, width-capped, **no height
  constraint** — exactly as §2.1 row 5 + §7.1 claim. `ChatSessionViewController.swift:161,169,202-207`.
  The "this is the one bare `«HV»`+`[.intrinsicContentSize]` production pane host" asymmetry is real;
  the 4 full-pane VCs use `«HC»`+`[]`.
- The host roots `ChatComposeStack` (routes `.session(_)` → bar, else `EmptyView`) →
  `ChatRestingBar .id(sid)`. `ChatSessionViewController.swift:546,605,628-639`. Confirms the
  `composeOrBarHost → restingBarHost` rename motivation (it never morphs to compose).
- `ChatSessionViewController` lives in `App/AppKit/`, not `Content/Chat/` (the §2 annotation is right).
- Line counts: `ChatSessionViewController` = 679 (plan ~680), `SidebarViewController` = 770 (plan ~770),
  `SessionRuntime` = ~3249 across 11 files (plan "~3000 / 9 files" — slightly understated file count,
  immaterial).

**Permission-card defect diagnosis (§7.1) — accurate, including both adversarial corrections.**
- `ZStack(alignment: .bottom)` is at `InputBarChrome.swift:126`; card child at `:143-162`;
  body-level `.animation(.smooth(duration:0.25), value: session.pendingPermissions.first?.id)` at `:166`.
  The doc-comment at `InputBarChrome.swift:84-110` independently confirms the union-height-grows-host
  mechanism and the deliberate ZStack-over-`.overlay` choice (§7.2).
- **M1 (constant 36, not 100) is FACT-correct.** `chatBottomInset = 36`, `bottomFadeScrimHeight = 100`
  (`ChatSessionViewController.swift:59,61`). The whole ZStack gets `.padding(.bottom, chatBottomInset)`
  (`InputBarChrome.swift:164`) and the card is `alignment: .bottom`, so card bottom = bar bottom = 36
  from host bottom. The overlay must use `.padding(.bottom, 36)` to preserve geometry. Correct.
- **M3 is FACT.** `PermissionSessionDemoViewController` renders `ChatRestingBar` directly
  (`:106`) via GeometryReader+PreferenceKey+height-constraint (`:11,124-143`), expressly to demo the
  card→host coupling. Moving the card out genuinely breaks the demo; the plan honestly flags this as
  non-trivial rework rather than a free smell-kill. Good self-adversarial catch.

**P1 dead injections — FACT.** `@Environment(NotificationService …)` and
`@Environment(TranscriptSearchBus …)` have **zero** SwiftUI readers anywhere in the tree. By contrast
`@Environment(\.syntaxEngine)` is read by `DiffView.swift:35,474`, and SessionManager/RecentProjects/
InputDraftStore have real readers. The consumed set `{SessionManager, RecentProjectsStore,
InputDraftStore, syntaxEngine}` is exactly right. Deleting the two injections is a true no-op.

**P2 DI fan-out + 1-site win — FACT.** The 7-arg init is re-passed at all 4 production `makeChild` arms
(`DetailRouterViewController.swift:366-404`); each child re-declares all 7 stored props + re-applies
the same 6 `.environment` calls (router `:430-435`, chat `:576-581`, compose `:100-105`, archive
`:75-80`, draftLanding `:123-128`). Five duplicated injection blocks. A `DetailContext` value +
`injectDetailEnvironment` helper collapses add/remove-a-dependency to one site. **"Don't inject AppState
whole" is correctly justified:** `MainSelectionModel` is on `AppDelegate` (`:34`), `searchBus` on
`AppDelegate` (`:31`), neither on `AppState` (`AppState.swift:7-14` holds 8 services, no `model`).

**P4 — the ONE real violation — FACT, fixed in product.** `BackgroundTaskButton.stopAction`
(`BackgroundTaskButton.swift:80-85`) does `guard let runtime = session.runtime` then
`runtime.markTaskStoppedLocally(taskId:)`, reaching past the façade. The plan adds
`Session.stopBackgroundTask(taskId:)` mirroring the existing `requestContextUsage` forwarder, which
indeed uses `guard let runtime` (`Session.swift:393,397`) — the m1 correction (`guard let runtime`, not
`guard case .active`) is FACT-correct. This strengthens the unidirectional invariant rather than hacking
a test. The m1 note about implicit nullability gating is also real (`stopAction` returns `nil` when
`runtime == nil`).

**P8 scope — FACT, including the two adversarial subtleties.**
- `turnUsage` (`SessionRuntime.swift:258`) and `turnStartedAt` (`:270`) ARE `@ObservationIgnored`, sitting
  on the imperative `publishTurnUsage`/`onTurnUsageChange` sink (`:253-262`). Excluding `TurnUsageMeter`
  is correctly justified — it would fail the plan's own "don't touch fire/ordering" rule.
- `tasks` (`:339`) and `todos` (`:347`) are plain observed `internal(set) var` (no `@ObservationIgnored`),
  read reactively via `Session` forwarders. The "observation-nesting trap" MAJOR is real: extracting them
  into reference trackers requires `@Observable` sub-objects held by tracked properties. Correctly flagged.
- `contextUsage` (`:310`) is also observed and read reactively (`ContextRingButton.swift:66` via
  `Session.swift:378`). The plan's distinction — todos/tasks become `@Observable` trackers, contextUsage can
  be a plain value — is internally consistent: a value reassigned wholesale into an observed enclosing
  property propagates fine; only the in-place-mutated reference trackers need `@Observable`. Sound.

**P10b rename — FACT.** The param `searchEngine: SyntaxHighlightEngine` is the highlighter
(`DetailRouterViewController.swift:75`, passed to `\.syntaxEngine` env key at `:433`). Demo VCs already
name it `syntaxEngine` (`:416-422`), so the rename aligns production with existing usage — well-motivated.

**C14 dead-wiring — FACT.** `DirectoryCompletionItem` has zero constructors, but its wiring is in LIVE
view files: `onDeleteRecent` (`InputBarView2.swift:254`), the `isRecent` branch
(`CompletionListView.swift:185-192`). The reworded framing ("behavior-preserving removal of never-firing
wiring", touches live files) is accurate, not "structural dead code". `ClaudeCodeStats` has no consumer
outside its own file. Correct.

**§6.1 imperative-edge verdicts — grounded, not rationalized.** `MainSelectionModel.select`
(`MainSelectionModel.swift:53-56`) sets the `@Observable` value AND synchronously notifies the single
weak `selectionObserver` (`:45`) — the one upward structural edge, exactly as Rule 4 / §3.2 state. The
imperative draft-clear is real (`InputBarView2.swift:471` with the teardown-swallow comment at `:463`),
matching Rule 6c. These are load-bearing runloop-tick edges, not debt.

---

## Majors

1. **`PermissionCardOverlay` selection-routing is underspecified (§7.3).** The new `permissionCardHost`
   is always-mounted at VC level (like the scrims), but the card must only surface for `.session(_)`.
   `ChatComposeStack` handles this today via the pure `content(for:)` router
   (`ChatSessionViewController.swift:628`). §7.3 says only "read path stays `session.pendingPermissions.first`"
   and never states the overlay routes on `model.selection` / which session it resolves. In practice it is
   *probably* benign (non-session selections have no active runtime → empty `pendingPermissions`, and the
   chat VC is only mounted for `.session(_)`/`.none`), but the plan should specify that
   `PermissionCardOverlay` resolves its session the same way `ChatRestingBar` does
   (`manager.prepareDraftSession(model-driven sid)`) and gates on the same routing predicate — otherwise a
   stale/wrong-session card can render over the new transcript across a fast switch. INFERENCE.
   *Fix: add one line to §7.3 stating the overlay reuses `ChatComposeStack.content(for:)` routing (or an
   equivalent `.id(sid)`-keyed session resolution) so the card host is empty whenever the bar host is.*

2. **Z-order + the always-mounted full-pane passthrough host's blast radius needs an explicit invariant,
   not just M2.** The plan adds a *fill-pane, four-edges-pinned* host on top of `restingBarHost`
   (§7.3 tree lists it last = topmost). M2 correctly mandates `PassthroughHostingView` with explicit
   `hitTest → nil`. But the existing scrims are deliberately **plain `NSView`** ("so they don't register
   cursor rects to mask the transcript's I-beam" — quoted in §7.2 from the real VC). An `NSHostingView`
   subclass over the *entire pane*, even with `hitTest → nil`, still registers tracking/cursor rects for
   its bounds unless those are also suppressed — `hitTest → nil` blocks clicks but does not by itself stop
   `NSHostingView` from installing cursor rects across the whole transcript. The plan should state that
   `PassthroughHostingView` must also defeat cursor/tracking-rect registration over the non-card region
   (or the card host must be sized to the card, not the pane), matching the *reason* the scrims avoid
   `NSHostingView` entirely — not merely match the click-passthrough half. INFERENCE; this is the same
   class of bug §7.2 cites as the motivation for plain-NSView scrims.

## Minors

- §2 line 220 / P8 says `SessionRuntime` is "~3000 / 9 文件"; actual is ~3249 across 11 files. Immaterial
  but the file count is off. FACT.
- `markTaskStoppedLocally` returns `Bool` (`SessionRuntime+Tasks.swift:124`); the P4 forwarder design
  (`Session.stopBackgroundTask`) doesn't say whether it preserves/discards the return. The current caller
  ignores it, so dropping it is fine — but worth one word in §8.P4. FACT.
- §5 target tree keeps demo VCs taking only `syntaxEngine` while production VCs move to `DetailContext`.
  This is correct (demos don't need the bag) but means `DetailContext` and the demo's narrow init coexist;
  the plan never calls this out. Harmless. FACT.

---

## What I ENDORSE

- The core diagnosis (architecture is already ~90% unidirectional; this is surgery, not rewrite) is
  borne out by the code. The two spines and the single upward structural edge are exactly as described.
- P1/P2 (DI consolidation + dead-injection removal) is the right highest-value/lowest-risk move and the
  facts are exact. The `DetailContext` is a genuine coupling reduction (1-site dependency changes), not
  clean-for-its-own-sake.
- P4 fixes the lone real violation in the product by closing the façade — the correct direction.
- The §6 constitution rules and §6.1 edge verdicts faithfully describe what the code already does; the
  "keep imperative edge X because of runloop-tick reason Y" entries are each backed by real ordering
  constraints, not debt-rationalization.
- The plan's *own* adversarial humility is well-calibrated: P6 (crossfade helper) downgraded to optional,
  P7 (grouping) shrunk after finding the predicate already shared, P8 excluding `TurnUsageMeter`, M3 demo
  rework flagged as non-free, C14 reworded. These match the code.
- §11 (explicitly-not-doing) correctly refuses the over-engineering traps: global store / Redux /
  chat-area ViewModel, whole-AppState injection, Session-façade protocol collapse, Controller+Coordinator
  merge. Each refusal is backed by a real invariant.

---

## Did the plan break the perf contract / regress functionality / over-engineer?

- **Perf contract:** No. No step enters the renderer; §2.19 is preserved as verbatim-move under merge
  gates (`TranscriptReentryLayoutCacheTests` + `TranscriptHostReentryLayoutCacheTests`, both confirmed to
  exist). The permission-card fix touches only the bottom-bar host geometry, not the transcript inset
  (which is fixed 112 — the §7.1 "inset doesn't jump" claim is consistent with the scrim/host code).
- **Functionality:** No regression by design — all card kinds/decisions/routing preserved (§7.7), P4 is a
  pure forwarder. The two majors are *risks of under-specification* in the card-host fix, not designed
  regressions.
- **Over-engineering:** No. The plan actively resists it (§11) and the verify-pass already trimmed the
  speculative items (P6/P7/P8). `DetailContext` earns its keep; nothing is clean-for-clean's-sake.

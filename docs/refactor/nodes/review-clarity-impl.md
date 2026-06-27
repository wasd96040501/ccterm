# Clean-context review — Clarity, completeness & implementability

**Reviewer stance:** adversarial / skeptical. Fresh engineer who must implement this next week.
**Scope reviewed:** `docs/refactor/REFACTOR-PLAN.md` only, verified against real source under
`macos/ccterm` and the four invariant docs. No `nodes/*` deliberation read.

---

## Verdict: **sound-with-fixes**

The plan is unusually well-grounded. Nearly every load-bearing factual claim I spot-checked is
**correct against the real code** (file paths, line numbers, symbol names, test names, the headline
permission-card mechanism, the dead-injection set, the dead-code inventory, the P7/P8 scope
corrections). It does **not** break the transcript §2 performance contract, does **not** regress
functionality, and is **not** over-engineered — it actively de-scopes P6/P7/P8 and explicitly
refuses a Redux/global-store/ViewModel rewrite. The defects I found are sequencing/clarity issues,
not correctness or feasibility blockers.

### Blocker check result: **NO BLOCKERS.**
No step is unimplementable, no step requires relaxing a §2 contract item, no step regresses a
shipped feature, and §9 is structured as independent compilable PRs. The issues below are one real
internal contradiction (MAJOR) and a set of clarity/minor gaps.

### Explicit contract / regression / over-engineering line:
- **Breaks perf contract?** No. §10 walls off all of §2 + §2.19 + the runloop-tick ordering; the
  only AppKit-internal step (13, `TranscriptSwapCoordinator`) is verbatim-move, gated by the two
  real merge-gate tests (`TranscriptReentryLayoutCacheTests`, `TranscriptHostReentryLayoutCacheTests`
  — both exist, FACT).
- **Regresses functionality?** No. Every fix is parity-preserving; the headline change (§7) keeps
  all card kinds, all four decision closures, the `.id(sid)` reset, and the read path verbatim.
- **Over-engineered?** No — the opposite. P6 downgraded to optional, P7 shrunk/abandoned, P8 scoped
  to exclude `TurnUsageMeter`, P9/P11 deferred. §11 is a credible anti-gold-plating ledger.

---

## MAJOR

### M-1 — §8 and §9 contradict each other on the un-erase ↔ DetailContext ordering
**FACT.** §8 P2 (plan line 453) states the `DetailContext` step's safety net depends on un-erasing
`AnyView` *first*: "需先做 P1（helper 不带死边）+ un-erase（漏注变编译错）" — i.e. only after the
host bodies are concrete generics does a *missing* `.environment()` injection become a compile error,
which is the stated mechanism that makes collapsing 5 `.environment` copies into one
`injectDetailEnvironment` helper safe.

But the §9 migration table (plan lines 495–496) orders **step 6 = `DetailContext` BEFORE step 7 =
`mountFillPaneHost` + un-erase `AnyView`**. So at the close of step 6's PR, `injectDetailEnvironment`
ships **without** its compile-time guard: a forgotten injection on any of the 5 hosts silently type-
checks (the bodies are still `NSHostingController<AnyView>` / `NSHostingView<AnyView>` —
verified: `ComposeSessionViewController.swift:42`, `DraftSessionLandingViewController.swift:38`,
`ArchiveViewController.swift:29`, `ChatSessionViewController.swift:94`, all `AnyView`). This is
exactly the failure mode P2 claims its sequencing prevents.

This is not merely cosmetic: the whole *argument* for why P2 is "low-risk" rests on the compiler
catching mis-injection, and §9 schedules P2 a full PR before that guarantee exists.
**Fix:** swap steps 6 and 7 (un-erase first, then DetailContext), or fold them into one PR, or
explicitly state in step 6 that the helper lands unguarded for one PR and is back-stopped only by
`DetailRouterContainmentTests` until step 7. The plan should pick one and make §8 and §9 agree.
*Location:* plan lines 453 vs 495–496.

---

## MINORS

### m-1 — `ChatRestingBar` / `ChatComposeStack` are real symbols but the reader can't tell where they live
**FACT.** The plan leans hard on `ChatRestingBar` (the struct holding the card ZStack) and
`ChatComposeStack` throughout §2/§5/§7/§8, but never states their file. A fresh implementer will
grep and be briefly confused: `ChatComposeStack` is defined in
`App/AppKit/ChatSessionViewController.swift:605`, while `ChatRestingBar` (with the ZStack at
`:126` and the body-level `.animation` at `:166`) lives in **`Content/Chat/InputBarChrome.swift`**,
not in a file named for either symbol. The §7.1 citations (`InputBarChrome.swift:126`, `:166`) are
**correct** — but the prose elsewhere ("卡片从 `ChatRestingBar` 里移走") never anchors the file.
*Fix:* add the file path to the §2 tree entries for `ChatRestingBar` / `ChatComposeStack`.

### m-2 — Stale upstream doc gives the wrong scrim class name; plan is right but should flag it
**FACT.** The plan's §2 tree and §7.3 correctly name the top scrim `TranscriptTopScrimView`
(`ChatSessionViewController.swift:92,153`; class at `Components/TranscriptScrimView.swift:171`).
But `Content/Chat/CLAUDE.md` (the invariant doc) still calls it `TranscriptScrimView` (the base
class). Since step 8 is "doc drift cleanup," the plan should explicitly list this scrim-name drift
in Content/Chat/CLAUDE.md as one of the doc fixes — it currently only enumerates `RootView2` (×8,
verified FACT) and the AppState `.environment` drift.

### m-3 — `isGroupableAssistant` line citation off by one
**FACT, trivial.** §8 P7 cites "`+Receive.swift:700` 的注释"; the actual declaration is
`SessionRuntime+Receive.swift:701`. The substantive claim is correct: the predicate is already
shared by `ReverseEntryBuilder.swift:84` and `JSONLReversePageSource.swift:135` (both verified), and
`EntryGrouping` is correctly identified as a non-existent symbol (0 hits) — so the "bridge uses
EntryGrouping" annotation the plan corrects is genuinely phantom.

### m-4 — §7.4 M2 says "ship a 6-line `PassthroughHostingView` subclass" without noting one was deleted
**FACT.** `PassthroughHostingView` exists today only as a tombstone comment in
`DetailRouterViewController.swift:27` ("the now-deleted `PassthroughHostingView`…"). The plan treats
it as net-new (correct outcome) but an implementer reading M2 may waste time hunting for the
existing class or, worse, assume it's reusable. One sentence — "(a prior `PassthroughHostingView`
was deleted; re-introduce it next to the card host)" — removes the ambiguity.

### m-5 — "7-arg DI bag" vs the actual init surface is asserted, not shown
**INFERENCE.** §1.3 / P2 / Rule 7 repeatedly cite a "7-arg DI bag" and "4-bag" for sidebar. I
verified the *consumed* services and the 5 injection sites (`.environment(searchBus)` /
`.environment(notifications)` across `DetailRouterViewController`, `ChatSessionViewController`,
`ComposeSessionViewController`, `ArchiveViewController`, `DraftSessionLandingViewController` — FACT,
exactly 5 files), and the `ChatSessionViewController` stored-property list is 7
(`model, sessionManager, recentProjects, notifications, searchEngine, searchBus, inputDraftStore` —
`ChatSessionViewController.swift:65-71`, FACT). The "7" is right, but the plan never shows a single
real `init(...)` signature. For an implementer, one quoted current init would make the "1 place to
add a dependency" payoff concrete.

---

## What I ENDORSE (verified sound)

- **§7 headline diagnosis is exactly right (FACT).** The card ZStack
  (`InputBarChrome.swift:126`), the body-level `.animation(.smooth(duration:0.25), value:
  session.pendingPermissions.first?.id)` (`:166`), the `[.intrinsicContentSize]` bottom-anchored
  host with no height constraint (`ChatSessionViewController.swift:169,202-207`), and the
  union-height-feedback root cause all check out. The "transcript inset jumps" myth is correctly
  rebutted: `contentInsets.bottom = 112` is a compile-time constant
  (`TranscriptScrollViewFactory.swift:40`, FACT) and never moves.
- **§7.4 M1 (FACT).** Card bottom aligns at `chatBottomInset = 36` (`InputBarChrome.swift:164`;
  constant at `ChatSessionViewController.swift:61`), and `bottomFadeScrimHeight = 100` (`:59`) is the
  scrim band — unrelated to the card offset. Using 100 would genuinely break visual parity.
- **§7.4 M2 (FACT).** Scrim is a pure `NSView` with `hitTest → nil`
  (`TranscriptScrimView.swift:61`); the demand to ship an explicit `PassthroughHostingView` over a
  pane-filling host (rather than trust `Color.clear`) is well-justified — a passthrough leak on a
  full-pane host shadows the *entire* transcript I-beam.
- **§7.4 M3 (FACT).** `PermissionSessionDemoViewController` renders `ChatRestingBar` directly via a
  `PreferenceKey` + height-constraint loop (`:11,106`); the warning that demo migration is non-trivial
  is correct.
- **P1 (FACT).** `@Environment(NotificationService.self)` and `@Environment(TranscriptSearchBus.self)`
  have **zero** SwiftUI readers; the 5 dead `.environment` sites are real. Pure no-op deletion.
- **P4 (FACT).** `BackgroundTaskButton.swift:81-84` reaches `session.runtime.markTaskStoppedLocally`
  — the lone real façade violation. `requestContextUsage` uses `guard let runtime`
  (`Session.swift:397`), so the M1 note to mirror that idiom (not `guard case .active`) is precise,
  as is the nullability-contract caveat (`stopAction` returns nil when `runtime == nil`).
- **P13 / C14 (FACT).** `DirectoryCompletionItem` has **0 construction sites** yet is cast in live
  views (`InputBarView2.swift:255`, `CompletionListView.swift:185`); `ClaudeCodeStats` has **0**
  consumers outside its own file; `FileCompletionStore.invalidate(directory:)` / `invalidateAll()`
  (`:145,152`) have **0** callers. The revised wording ("behavior-preserving deletion of
  never-firing wiring") is honest and correct.
- **P3 (FACT).** `SidebarViewController.swift` is exactly **770** lines; `SidebarItemNode` is a
  `final class` (`SidebarItemModel.swift:12`) — the reference-identity invariant the split must
  preserve is real.
- **P8 (FACT).** `turnUsage` / `turnStartedAt` are `@ObservationIgnored` riding
  `publishTurnUsage`→`onTurnUsageChange` (`SessionRuntime.swift:258,262,270`); excluding
  `TurnUsageMeter` from extraction is correctly motivated. `tasks` / `todos` are *observed*
  (`:339,347`), so the "nested-observation trap" note (child must be `@Observable` held by a tracked
  property, tests must assert live re-render) is exactly the right caution.
- **P7 (FACT).** Predicate already shared across the three sites; `ReverseEntryBuilder` is at
  `Services/Session/Session/`, not a bridge dir. Shrinking/abandoning P7 is the right call.
- **Test inventory (FACT).** Every named merge-gate / parity test exists except `SidebarTreeModelTests`,
  which is correctly a *new* test step 9 creates. `RootView2` doc drift is exactly 8 files.
- **§9 shippability.** With M-1 fixed, every step compiles, passes `make test-unit`, and is an
  independent PR with no cross-merge half-migrated state. The card host (step 5) being VC-level (like
  the scrims), not per-attach, makes it genuinely independent of the step-13 swap extraction —
  verified: scrims/host are added once in `loadView` and persist (`ChatSessionViewController.swift`
  mounts them in `loadView`, lifetime = VC), so a 4th sibling host slots in cleanly.

---

## Single biggest risk the plan UNDERSTATES

**Step 13 (`TranscriptSwapCoordinator`) is rated "high" but its true exposure is the *split line
through `attachSession`*, which the plan acknowledges yet still underplays as "verbatim move."**
§8 P5 itself lists three cross-boundary seams — z-order anchor (`addSubview(positioned:.below,
relativeTo: topScrim)`, scrim stays on VC), the `currentSession === session` identity guard shared by
the turn-usage sink *and* the running-observation task, and first-screen logging/focus staying on the
VC. The most fragile invariant in the entire app by the plan's own §10.3 wording — the I5
"outgoing-scroll `removeObserver` flush *before* bind on A→B→A re-entry" — has to be carried across
that new class boundary **without** the two merge-gate tests necessarily exercising the same-session
re-entry crossfade path (they drive `present(sessionId:)`→`attachSession`, i.e. the *attach* tile
contract; the `fadingOutTranscript` same-session crossfade at `ChatSessionViewController.swift:113`
is a *different* path). The plan's §9.1 mitigation leans on the two gates + manual A→B→A→A smoke,
but the automated coverage for the same-session-swap crossfade ordering is the weakest part of the
net. If anything in this plan ships a regression, it will be a one-frame tear or stale-scroller flash
on same-session crossfade that neither merge gate catches. The plan should either name a test that
covers the `fadingOutTranscript` finish-before-new-attach ordering, or state plainly that this path
is manual-smoke-only and accept the residual risk.

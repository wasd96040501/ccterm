# Clean-context review — Functional parity, permission-card fix correctness, over-engineering

**Reviewer stance:** adversarial / skeptical. Sources: `docs/refactor/REFACTOR-PLAN.md` + the real codebase + the four invariant docs. No `nodes/` deliberation files were read.

## Verdict: **sound-with-fixes**

The plan's §7 root-cause analysis is **correct end-to-end against the real code**, the headline-fix geometry constants are right, the dead-code claims check out, and the over-engineering demotions (P6/P7/P8-TurnUsage exclusion/P9) are well-justified. The defects I found are gaps in the *parity-test protection narrative* and a couple of under-specified mechanics in the card fix — none of them break the §2 performance contract or regress a feature if the implementer reads the cited code. No blockers.

## Blocker check

- **Breaks the transcript §2 performance contract?** NO. No step enters the renderer. The card fix lives entirely in `ChatSessionViewController.loadView` + a new SwiftUI overlay; `contentInsets` stay fixed (verified below). FACT.
- **Regresses user-facing functionality?** NO (with the fixes below applied). The card move is a verbatim relocation of an existing view + 4 closures; all decisions/kinds preserved structurally.
- **Over-engineered?** NO. The plan actively cuts ceremony and the cuts are justified by the real code.
- **Internally inconsistent?** NO material inconsistency found.

---

## §7 card fix — verified end-to-end

**§7.1 root cause is FACT, every clause confirmed:**
- `ZStack(alignment:.bottom)` carrying the card is at `InputBarChrome.swift:126` (plan cites `:126`). FACT.
- `composeOrBarHost` is `NSHostingView<AnyView>`, `sizingOptions = [.intrinsicContentSize]` (`ChatSessionViewController.swift:169`), bottom-anchored (`:203`), centerX (`:202`), width-capped (`:204`), **no height constraint**. FACT (plan cites `:169,202-207`).
- `ZStack` reports the union of children → host re-reads intrinsic height → bottom-anchored host's top edge rises. The view's own doc comment (`InputBarChrome.swift:96-101`) literally states the ZStack "reports the union of its children, so the card's footprint correctly grows the host." FACT — the plan's mechanism is the code's own stated design.
- Body-level `.animation(.smooth(duration:0.25), value: session.pendingPermissions.first?.id)` at `InputBarChrome.swift:166` (plan cites `:166`) drives both the card `.transition` and the host-geometry change. FACT.
- **transcript `contentInsets` are FIXED, not dynamic:** `TranscriptScrollViewFactory.swift:40` → `NSEdgeInsets(top: 56, left: 0, bottom: 112, right: 0)`. The "inset jump" theory is correctly debunked; only the bar host moves. FACT.

**§7.4 M1 — card position constant is correct.** The card's bottom padding is `.padding(.bottom, ChatSessionViewController.chatBottomInset)` = **36** (`InputBarChrome.swift:164`; `chatBottomInset = 36` at `ChatSessionViewController.swift:61`). `bottomFadeScrimHeight = 100` (`:59`) is the scrim band height, derived from `36 + 22 + 10 + 32`, and is unrelated to the card offset. The plan's insistence on reproducing the position with **36, not 100**, is correct — using 100 would float the card a full bar-height too high. FACT. This is a genuine catch; a naive "use the scrim height" implementation would break parity.

**§7.2 / M2 — passthrough rationale is correct.** Scrims are pure `NSView` with explicit `hitTest(_:) -> nil` (`TranscriptScrimView.swift:60-61`) precisely so they don't register cursor/tracking rects that shadow the transcript I-beam (file-header comment `:16-21`). The plan's M2 — ship `PassthroughHostingView` with an explicit `hitTest`, don't bet on `Color.clear` — is well-grounded. The blast-radius argument (a full-pane host leaking hit-test shadows the *entire* transcript) is correct: the new host is pinned four-edges full-pane (`sizingOptions = []`), unlike the bottom-anchored bar host.

**§7.3 — "fade in place, nothing else moves" holds.** With the card removed from `ChatRestingBar`, the bar host's intrinsic height becomes a pure function of bar content (multi-line input still grows it; the card never does). The new `permissionCardHost` is `[]` full-pane → publishes no intrinsic size → cannot leak into the window solver (root CLAUDE.md's documented antidote). The card's appearance only mutates the card subtree inside an already-full-size container, so there is **no union-height feedback path**. INFERENCE (well-supported): no residual path by which the bar host or transcript moves. The one geometry that "moves" is the card's own opacity+scale `.transition`, which is the intended effect.

**Decision wiring preserved — verified.** `PermissionCardView` takes all four closures (`PermissionCardView.swift:35-37,43`) and dispatches body across ~14 kinds (`:97-122`). The production wiring site (`InputBarChrome.swift:144-156`) passes all four (`onAllowOnce`/`onAllowAlways`/`onDeny`/`onAllowWithInput`). A verbatim relocation of this call + its closures into `PermissionCardOverlay` preserves all decisions and all kinds. FACT (structure); the move itself is implementer discipline.

---

## Parity — gaps found

### MAJOR-1 — §7.7 overstates the test protection for the card move

§7.7 says "`PermissionCardWiringTests`(直接驱动 `session.respond`,非 SwiftUI 点击)原样通过." That is *true but irrelevant as a guard for the move*: `PermissionCardWiringTests` (verified: `cctermTests/PermissionCardWiringTests.swift:24,40,55,71`) drives `session.respond(to:decision:)` **directly at the Session boundary** — it never instantiates `ChatRestingBar`, `InputBarChrome`, or `PermissionCardView`, and never clicks a button. It passes identically *whether or not the card is correctly rewired*, because the host it exercises (`session.respond`) is unchanged by the refactor.

**Consequence:** there is **no automated test that exercises the card-button → closure → `session.respond` path**. The verbatim move of the four closures into `PermissionCardOverlay` is protected only by human review + a pixel snapshot. If the implementer mis-wires (e.g. swaps `allowOnce`/`allowAlways`, or drops `onAllowWithInput`'s `updatedInput` payload), every cited test stays green. `PermissionCardSnapshotTests` checks pixels, not closure routing.

**Fix:** add a lightweight test that constructs `PermissionCardOverlay` with a spy `Session` and asserts each of the four card actions reaches `session.respond` with the right decision — i.e. drive the overlay's closures, not just the Session boundary. (`DetailPaneTranscriptHitTestTests` covers the *hit-test passthrough* concern of M2 but not the decision routing.) Without this, the plan's "逐字保留" claim is unenforced.

### MAJOR-2 — M3 demo migration is real work and the plan's risk table under-budgets it

Verified: `PermissionSessionDemoViewController.swift:105-146` renders `ChatRestingBar` directly via `GeometryReader` + `DemoBarHeightKey` (PreferenceKey) + `inputBarHeightConstraint` (`:11-16,121-131,137-143`), and its `showCurrent()`/`hideAll()` (`:174-192`) drive the card *through `ChatRestingBar`'s ZStack*. Once the card leaves `ChatRestingBar`, **this demo loses its card display entirely** unless it also gets a `permissionCardHost`. The plan flags this in M3 (good — this is an honest catch the adversarial verifier earned), but step 5 in the §9 migration table is rated risk "中/MED" with guard tests that are all production-path; the demo rewrite is neither in the guard list nor reflected in the effort line. It is DEBUG-only so it cannot regress shipping behavior, but it *can* leave the demo silently broken (a card that never appears) and waste a debugging session. Treat the demo overlay as an explicit sub-task of step 5, not a footnote.

### MINOR — `markTaskStoppedLocally` return value (P4)

`SessionRuntime.markTaskStoppedLocally(taskId:)` returns `Bool` (`SessionRuntime+Tasks.swift:124`); the current `BackgroundTaskButton.stopAction` discards it (`BackgroundTaskButton.swift:80-85`). The plan's proposed `Session.stopBackgroundTask(taskId:)` forwarder, modeled on `requestContextUsage`'s `guard let runtime else { return }` shape (verified `Session.swift:393-402`), should decide whether to surface or discard the `Bool`. Discarding is fine (matches today), but the forwarder signature should be `Void`-returning to keep call sites clean — note it so it isn't accidentally typed `-> Bool` and re-leak a runtime detail. The plan's m1 note (nullability gate via `stopAction == nil` when `runtime == nil`) is accurate (`:81`).

---

## Dead-code deletion (Step 3 / §8 C14) — verified, claim wording is honest

- `DirectoryCompletionItem(` has **zero constructor call sites** in the codebase (only `as?` casts and the struct/init definition). FACT.
- The surrounding wiring is **live but never-triggered**: `InputBarView2.swift:254` (`onDeleteRecent` closure), `CompletionListView.swift:185-192` (the `isRecent` pill + swipe-delete), `CompletionListView.swift:7` (`onDeleteRecent` field). These are referenced by **active views**; they only never fire because the data source is permanently empty. FACT.

The plan's C14 correction — "behavior-preserving removal of never-triggered wiring (verified: no `DirectoryCompletionItem` constructor; recent-branch data source永空)" rather than "structural dead code" — is **accurate and the right framing**. This is the one deletion that touches live files, and the plan correctly assigns `CompletionListSnapshotTests` + `CustomCommandTests` as guards (both exist). I endorse the cautious wording; this is exactly the kind of "looks dead, is wired" trap that a sloppy plan would mislabel.

---

## P1 dead injections — verified no-op

Zero `@Environment(NotificationService.self)` and zero `@Environment(TranscriptSearchBus.self)` readers exist anywhere (FACT). The `.environment(searchBus)` / `.environment(notifications)` pairs appear at **5 host sites** (`DetailRouterViewController.swift:434-435`, `ChatSessionViewController.swift:580-581`, `ArchiveViewController.swift:79-80`, `ComposeSessionViewController.swift:104-105`, `DraftSessionLandingViewController.swift:127-128`) — the plan said "5 处." FACT. Deletion is a genuine no-op; both services reach their real consumers through AppKit channels, not `@Environment`. Endorsed.

---

## Over-engineering assessment — the plan is right, and I found nothing it should have cut but didn't

- **P6 (shared `CrossfadeController`) demoted to optional/default-off:** justified. The two crossfades share ~7 lines of `NSAnimationContext.runAnimationGroup` (real: `crossfadeTranscriptSwap`, `ChatSessionViewController.swift:483-492`); the rest (`fadingOutTranscript` parking, `expected`-guarded idempotent `finishTranscriptFadeOut` at `:499-506`, the load-bearing pre-`bindData` flush at `:306`) genuinely differs and must stay per-call. A stateful controller for 7 shared lines is ceremony. The §10/§11 rule that the helper must **never** own the I5 `removeObserver` pre-flush is correct — that flush is documented load-bearing (`attachSession` `:296-306`). Endorsed.
- **P8 excludes `TurnUsageMeter`:** justified. `turnUsage`/`turnStartedAt` ride the imperative sink (`onTurnUsageChange`, `ChatSessionViewController.swift:436-442`) with ordering-sensitive `setTurnUsage`+`setTurnStartedAt` pairs; extracting it would violate the plan's own "don't touch fire/ordering" rule. Correct exclusion.
- **P8 observation-nesting caveat is the right call:** the plan correctly notes `tasks`/`todos` must stay `@Observable` sub-objects held by `@Observable`-tracked properties for nested change propagation, and demands "实时重渲染" assertions in `SessionRuntimeTodosTests`/`…TasksTests` (both exist). This is the trap that a "just extract a value type" plan would fall into. Endorsed.
- **P9 (collapse ~40 `Session` forwarders behind a protocol) left undone:** correct. Draft vs runtime read surfaces genuinely diverge (the Session/CLAUDE.md phase model confirms it), so a protocol would fabricate runtime-only fields on `.draft`. Pure mechanical boilerplate, not tangled flow. Endorsed.
- **P7 (grouping dedup) shrunk/dropped:** the plan's correction that `isGroupableAssistant` is already shared and the live-grouping lives in `SessionRuntime+Receive`, not the bridge, is the kind of fact-check that downgrades an over-scoped item correctly. I did not re-verify the `:700` line cite, but the structural claim (two fold directions are intentionally separate) is consistent with Session/CLAUDE.md's reverse-builder split.

I did **not** find any retained item that is clean-for-its-own-sake. The plan's §11 "明确不做" table is the strongest part of the document.

---

## What I ENDORSE

1. §7.1 root-cause analysis — fully correct against the real code; the union-height-grows-bottom-anchored-host mechanism is the code's own documented design.
2. §7.4 M1 — card position must be **36 (`chatBottomInset`), not 100 (`bottomFadeScrimHeight`)**. Real catch; prevents a position regression.
3. §7.4 M2 — unconditional `PassthroughHostingView` over `Color.clear`, grounded in the established pure-NSView scrim pattern and the full-pane blast radius.
4. §7.3 — `[]` full-pane host as the documented antidote to window-collapse; correct host-sizing discipline.
5. C14 dead-code wording — "never-triggered live wiring," not "structural dead code." Honest and verified.
6. P1 dead-injection deletion — verified zero readers; true no-op.
7. The over-engineering demotions (P6/P7/P8-TurnUsage/P9) and the §11 refusal table.

## Explicit answer to the charge

- **Does the plan break the perf contract?** No. No step touches the renderer; insets are fixed; the card fix is host-level.
- **Does it regress functionality?** Not if implemented as written. The one real exposure is MAJOR-1: the card-decision rewiring has no test that would catch a mis-wire — add one. MAJOR-2 (demo) is DEBUG-only.
- **Does it over-engineer?** No. It cuts ceremony aggressively and the cuts are justified.

# Adversarial verification — design-target-component-tree.md

Verified against the live source (worktree `epic-nightingale-1d6c6f`) and the four
CLAUDE.md invariant docs. Each finding cites `file:line`. FACT = read in the code;
INFERENCE = my read.

## Verdict: **sound-with-fixes**

No item in the design weakens the §2 transcript perf contract, the §2.19 attach
contract, or a runloop-tick ordering invariant. The two true splits (C5 sidebar,
C6 transcript swap) are scoped honestly and gated by tests that exist. The premises
are *mostly* accurate. But there are a handful of real defects: one premise the
tree gets factually wrong (where live grouping lives), one change that is borderline
ceremony (C7), one dead-code deletion that is wider than the one-liner implies (C14),
and one boundary subtlety the "thin forwarder" framing of C6 glosses (the
`topScrim` z-anchor + closure-captured `self.currentSession` coupling). None are
blockers; all are fixable by tightening the design text and the C6/C7 seams.

---

## Perf-contract safety (the BLOCKER check) — PASS

I opened NativeTranscript2 §2 + §2.19 and the root runloop model and checked every
change against them.

- **§2.19 single-width attach.** C6 moves `attachSession`'s choreography into a
  coordinator but the design pins the exact ordering it must preserve (`factory.make`
  unbound → `addSubview` → `view.layoutSubtreeIfNeeded()` → `factory.bindData` →
  `scrollToTail`), §5/C6 lines 343-349. The live code at
  `ChatSessionViewController.swift:341-367` matches that ordering; the design does
  not reorder it. **FACT: no weakening.**
- **I5 blanket `removeObserver` pre-flush.** The design (C7 §6, lines 388-398; Risk
  table line 484) explicitly refuses to fold the `finishTranscriptFadeOut()`
  pre-flush into the shared helper, keeping it at the head of `attach`. The live
  code's load-bearing comment is at `ChatSessionViewController.swift:296-306` and
  the flush call at `:306`. The design quotes this correctly. **FACT: preserved.**
- **Router synchronous source-phase swap (I1, bug #195/#198).** The design rejects
  converting the structural notification to `withObservationTracking` (Rejected #3,
  line 454; NOT-done list line 51). Matches `DetailRouterViewController.swift:454-507`
  (`selectionDidChange` → `applySelection` synchronous). **FACT: preserved.**
- **Don't-merge Controller/Coordinator.** Rejected #2 honors NativeTranscript2 §1.1.
- **CATransaction/allowsImplicitAnimation suppression around the structural swap.**
  Untouched by any change; the design keeps the alpha fade *outside* it (C6 I3).
  Matches `ChatSessionViewController.swift:335-339,458-468`.

No change requires a §2 item to be relaxed. **No blocker.**

---

## Premise correctness — one real error, rest accurate

### MAJOR — the tree misplaces where live grouping lives (C10)
The tree (§1, lines 84-86) draws:
```
bridge: Transcript2EntryBridge → uses EntryGrouping ★NEW-C10
```
implying the *live* grouping rule lives in the bridge. **FACT: it does not.** The
live grouping (`appendToTimeline` / `attachToolResult` / `isGroupableAssistant`)
lives in `SessionRuntime+Receive.swift:274,310,701`. `Transcript2EntryBridge.apply`
(`Transcript2EntryBridge.swift:90`) only *translates already-grouped* `MessageEntry`
→ `Block` (status pushes, first-user suppression) — it does no run-grouping.
The cold path's `ReverseEntryBuilder` is at `Services/Session/Session/ReverseEntryBuilder.swift`,
**not** under `NativeTranscript2Bridge/` as the tree's data-feed footnote (line 186)
suggests.

Consequence for C10: the dedup target is `SessionRuntime+Receive ↔ ReverseEntryBuilder`,
both already in `Services/Session/Session/`. And the core predicate is **already shared** —
`SessionRuntime+Receive.swift:700` has the comment *"Module-internal so
`ReverseEntryBuilder` applies the same grouping rule as `appendToTimeline`"* and
`ReverseEntryBuilder.swift:84` calls the same `isGroupableAssistant`. So C10's
premise ("grouping-rule change = 1-site edit" is impossible today; line 204) is
**overstated** — the *predicate* is already 1-site. What genuinely diverges is the
traversal-side growth/tool-pairing (forward fold off `messages.last` vs reverse
fold), which the design itself says it will keep per-direction (line 405). Net: C10
extracts less than the tree implies, and the tree's placement is wrong. Fix the
tree annotation and rescope C10 to "the residual non-predicate rules," or drop it as
low-value (the highest-value part is already done).

### Verified-correct premises (FACT)
- **5× copy-pasted 6-line `.environment` block, 2 dead injections.** Confirmed at
  `ArchiveViewController.swift:75-80`, `DraftSessionLandingViewController.swift:123-128`,
  `ComposeSessionViewController.swift:100-105`, `ChatSessionViewController.swift:576-581`,
  plus the demo at `DetailRouterViewController.swift:428-436`. **Zero** `@Environment`
  readers of `NotificationService` or `TranscriptSearchBus` exist anywhere (grep over
  all `*.swift`). So C1/C2 + the dead-edge deletion are correctly grounded. (P1 ✓)
- **5 `AnyView` pane hosts.** `NSHostingController<AnyView>` at Archive:29, DraftLanding:38,
  Compose:42; `NSHostingView<AnyView>` at Chat:94; demo AnyView at Router:428. C3 ✓.
- **C4 façade pierce.** `BackgroundTaskButton.swift:83` calls
  `runtime.markTaskStoppedLocally(taskId:)` after unwrapping `session.runtime`
  (`:81`). The proposed `session.stopBackgroundTask(taskId:)` forwarder mirrors the
  existing `session.requestContextUsage` (`Session.swift:393-401` → `runtime.requestContextUsage`).
  This is a correct, in-product fix (not a test hack). **Strongly endorse C4.**
- **C5 sidebar god-VC.** `SidebarViewController.swift` is 770 lines; `lastSeenGroups`
  (`:69,123,425`), `buildRootChildren` (`:275`), `groupedRecords` (`:304`) all present.
  Premise accurate.
- **C6 chat VC.** `ChatSessionViewController.swift` is 680 lines; the invariant-dense
  `attachSession` spans `:281-469`. Premise accurate.
- **C13 renames.** `composeOrBarHost` (`ChatSessionViewController.swift:94`) only ever
  hosts `ChatComposeStack` (`:161`) which routes to the bar or `EmptyView` (`:643-668`)
  — never compose. `CompletionViewModel` exists (`Completion/CompletionViewModel.swift`).
  Both renames are accurate.
- **C8/C9 — `DraftSessionLandingViewController` ALREADY EXISTS** and already has a
  `present(sessionId:animated:)` method the router calls (`DetailRouterViewController.swift:385-394,499-501`).
  See the MINOR below — the design over-flags this as new.

---

## Functional parity — PASS (no regression found)

- **Permission card.** The task brief warned about a "permission-card overlay
  proposal." **This design contains none** — the card is explicitly marked
  "UNCHANGED — card geometry out of scope" (line 158) and stays inside
  `ChatRestingBar`'s `ZStack(alignment:.bottom)` (live: `InputBarChrome.swift:126-163`),
  hosted via the bottom-anchored `[.intrinsicContentSize]` host. The ZStack-not-overlay
  rationale (`InputBarChrome.swift:93-101`: a `.overlay` would clip the card and put
  its upper half outside the host's hit-test bounds) is left intact. **No bar/inset
  move, no host re-size — the parity risk the brief flagged does not exist in this
  doc.** (If a permission-card overlay lives in a sibling doc, it's not this one.)
- **Selection spine, host sizing (I7/I8), sheets, builtins, draft→active promotion,
  scrims, focus** — all marked UNCHANGED and verified against the live code paths.
  C3 un-erasure changes the host's generic parameter, not its `sizingOptions` or
  regime (table §3 keeps every host's kind/options/regime identical).
- **Merge gates exist and drive the production path.**
  `cctermTests/TranscriptHostReentryLayoutCacheTests.swift:152,201` constructs a real
  `ChatSessionViewController` and calls `present(sessionId:)` directly, exactly the
  surface C6 must preserve. The design's "C6 doesn't land until both stay green"
  (line 361, Risk line 483) is enforceable as written.

---

## Over-engineering — one borderline change (C7), one watch-item (C11)

### MAJOR (over-engineering) — C7 `CrossfadeController` barely earns its keep
I diffed the two crossfade machines side by side:
- Router `commitChildTransition` + `finishFadeOut` (`DetailRouterViewController.swift:336-361`).
- Chat `crossfadeTranscriptSwap` + `finishTranscriptFadeOut` (`ChatSessionViewController.swift:476-506`).

The **only** genuinely identical fragment is the ~7-line `NSAnimationContext.runAnimationGroup`
block (duration + ease + `incoming.alpha=1`/`outgoing.alpha=0` + completion). Everything
else differs and the design admits it must stay per-owner:
- parked-state type (`NSViewController` vs `(Transcript2ScrollView, Session)`),
- the `expected`-guarded idempotent `finishX` (different teardown: `prepareForRemoval`+
  `removeFromParent` vs `TranscriptScrollViewFactory.dismantle(controller:)`),
- the I5 pre-flush (transcript-only).

So C7 extracts ~7 lines and leaves each call site holding its own parking field, its
own guard, and its own teardown — plus a new type and a closure hop. That is close
to the "clean-for-its-own-sake" the user explicitly rejected. **Recommendation:
drop C7, or downgrade it to sharing a tiny free function** `crossfade(incoming:outgoing:duration:completion:)`
**with no ownership** — not a stateful `CrossfadeController`. Note C7 is also
sequenced as a prerequisite for C6 (line 546); if C7 is dropped, C6 loses nothing
(it keeps its own animation block, which already works).

### MINOR (watch-item) — C11 runtime projections are lower-value than billed
The runtime is **already** decomposed into 10 focused extension files
(`SessionRuntime+Todos/+Tasks/+Streaming/+ContextUsage/+Receive/…`), which already
addresses most of the "god object readability" concern C11 targets. The proposed
`TurnUsageMeter` extraction is the riskiest of the four: `turnUsage`/`turnStartedAt`
are `@ObservationIgnored` (`SessionRuntime.swift:258,270`) and ride the imperative
`publishTurnUsage` sink that fires `onTurnUsageChange` (`SessionRuntime+Streaming.swift:66-69`),
with `turnStartedAt` mutated from `resetStreamingTurn` (`+Streaming.swift:51`) and
`+Start.swift:270` in a specific order relative to the streaming reset. The design's
guard ("extract only projections that don't touch `receive` ordering; if a tracker
can't be lifted without it, it stays," line 417) is the right rule — but applied
honestly, `TurnUsageMeter` probably *fails* that test and should stay. `TodoTracker`/
`TaskTracker` (self-contained sparse state) are the safe ones. **Recommendation:
scope C11 down to the two clearly-self-contained trackers and explicitly exclude
turn-usage** — the design already leaves itself this out; make it a default, not an
escape hatch.

---

## Feasibility — mostly fine; one C6 seam under-specified

### MINOR — C6's "thin forwarder" understates the boundary surface
The design says `present` becomes "a thin forwarder that hands the coordinator the
resolved `Session` + the settled host view" (line 341). But `attachSession` is
coupled to the VC in ways beyond "the host view":
- **z-order anchor:** `view.addSubview(scroll, positioned: .below, relativeTo: topScrim)`
  (`ChatSessionViewController.swift:353`). The scrims stay on the VC (tree lines
  144-145), so the coordinator needs `topScrim` (or an insert closure) to preserve
  the band ordering — not just `view`.
- **identity-guarded closures:** the turn-usage sink (`:438-442`) and running-obs
  (`:537`) capture and compare `self.currentSession === session`. If `currentSession`
  moves to the coordinator, those guards move with it; if it stays on the VC, the
  coordinator must call back. Either is fine, but it's not "thin."
- **first-screen logging + focus** (`:384-426,270-277`) are VC concerns the design
  keeps on the VC — so the split line runs *through* `attachSession`, not around it.

This is **feasible** (pass the scrim/insert-closure + decide where `currentSession`
lives), but the design should name the exact crossing surface so the implementer
doesn't discover it mid-extraction. It does not threaten §2.19 — the ordering is
unchanged — but it raises C6's real cost above "thin forwarder."

### MINOR — C14 deletion is wider than the one-liner
"Delete vestigial paths (directory-completion…)" (line 45). The dead path is real
(`DirectoryCompletionItem` is **never constructed** — survey-completion Smell #1,
confirmed: only `as?` cast consumers exist) but it spans **4 files**, including live
*consumer* code that must be deleted too: `InputBarView2.swift:255-258` (the
swipe-delete-recent handler) and `CompletionListView.swift:185` (the `isRecent` pill),
plus `DirectoryCompletionItem.swift` and `DirectoryCompletionProvider.swift`. As
worded the change reads like a single-file delete. Not a correctness risk (the casts
always fail today), but call out the consumer-side removals so C14 isn't half-done.

### MINOR — C8 `SessionPresentingChild` is partly already there
`DraftSessionLandingViewController` already exists with `present(sessionId:animated:)`
and the router already downcasts to both it and `ChatSessionViewController`
(`DetailRouterViewController.swift:489-501`). The protocol collapses **two** existing
downcasts into one polymorphic call — a fine small cleanup, but the design's framing
(`★C8` "Add … so the router calls `present` polymorphically", tree line 168 flags
DraftLanding `★C8`) reads as if DraftLanding is new. It isn't. Trim the novelty
claim; the change is a 2-branch → 1-branch simplification, nothing structural.

---

## What I ENDORSE (verified safe + worth doing)

- **C1/C2 `DetailContext` + `injectDetailEnvironment` + drop 2 dead edges.** Highest
  value, lowest risk; the 5× duplication and 2 dead injections are real. The
  value-bag-not-AppState reasoning (§6.C1) is correct — `MainSelectionModel` is owned
  by `AppDelegate`, not `AppState` (`MainSplitViewController.swift:18-37` threads them
  separately), so injecting `AppState` whole wouldn't suffice.
- **C3 un-erasure + C13 renames.** Mechanical, compiler-enforced, and they make C2
  safe (a missing env becomes a compile error). `composeOrBarHost`/`CompletionViewModel`
  are genuinely stale names.
- **C4 `stopBackgroundTask` forwarder.** Closes the one production façade pierce,
  mirrors the existing `requestContextUsage` forwarder. Clean, in-product.
- **C5 sidebar split into a pure `SidebarTreeModel` + menu controller.** The 770-line
  VC genuinely mixes pure tree-building with outline/DnD/menu plumbing; making
  `build(records:groupOrder:previouslySeenGroups:)` pure + testable (and turning the
  hidden `lastSeenGroups` cache into an explicit input, preserving invariant 6.10) is
  a real, well-bounded win. Keeping `SidebarItemNode` a reference type (6.1) and DnD
  on the VC is the correct line.
- **C9 `mountFillPaneHost`.** Three identical `«HC» + sizingOptions=[] + 4-edge-pin`
  recipes (Archive/Compose/DraftLanding) collapse to one helper. Pure dedup, no
  regime change. Safe.
- **C6 in principle, with the seam named.** The extraction is legitimate and the
  test gate is real; my only ask is that the design enumerate the crossing surface
  (topScrim z-anchor, `currentSession` ownership) before implementation, and that it
  remain the LAST step behind green gates (which the sequencing already says).
- **C12 judgment call (keep `ModelStore.shared`, fold the thin UserDefaults stores,
  reconcile the doc).** This is the right *don't-over-engineer* line, consistent with
  the user's stance.
- **The whole "Explicitly NOT done" list** (P9 forwarders, Controller/Coordinator
  merge, withObservationTracking router, SwiftUI-ifying spine nodes). Each rejection
  is correct and well-reasoned against the live invariants.

---

## Summary of required fixes before this design is implementation-ready

1. **(MAJOR, premise)** Fix the tree: live grouping is in `SessionRuntime+Receive.swift`,
   not the bridge; `ReverseEntryBuilder` is in `Services/Session/Session/`, not the
   bridge dir. Rescope C10 — the `isGroupableAssistant` predicate is already shared;
   only the residual traversal-side rules remain, which the design keeps per-direction.
   Consider dropping C10 as low-value.
2. **(MAJOR, over-engineering)** Drop C7 `CrossfadeController` or reduce it to a
   stateless 7-line helper; do not introduce a stateful coordinator for ~7 shared lines.
3. **(MINOR)** Scope C11 to `TodoTracker`/`TaskTracker` only; exclude turn-usage
   (it fails the design's own "don't touch the fire/ordering" rule).
4. **(MINOR)** Name C6's full crossing surface (topScrim z-anchor + `currentSession`
   ownership), not just "the host view."
5. **(MINOR)** Expand C14 to list the dead *consumer* sites in `InputBarView2.swift`
   and `CompletionListView.swift`, not just the provider/item files.
6. **(MINOR)** Trim the `★NEW`/`★C8` novelty flags on `DraftSessionLandingViewController` —
   it already exists with `present`; C8 only collapses two existing downcasts.

# Clean-context review — Performance-contract & runloop-tick safety

**Lens:** the hard gate — does any step weaken a load-bearing §2 item, the §2.19
single-width attach contract, or a runloop-tick ordering invariant?

**Verdict: sound-with-fixes.**

The plan does **not** break the transcript performance contract, does **not**
regress functionality on the paths I checked, and is **not** over-engineered (it
actively de-scopes the over-engineered ideas: P6 crossfade helper → optional,
P7 grouping → shrunk/dropped, P8 → excludes `TurnUsageMeter`). Its factual
claims about the real code are accurate where I spot-checked them. The blocker
check is **clean** — no proposed step crosses into the renderer interior, and the
two highest-risk steps (5 and 13) are both fenced by tests that actually exist
and actually assert the relevant invariant.

The fixes below are scoping/seam clarifications, not contract violations.

---

## Blocker check (the gate)

**Result: PASS — no blocker found.**

I went item-by-item through NativeTranscript2/CLAUDE.md §2 (2.1–2.19), §2.19's
single-width attach contract, and root CLAUDE.md's runloop-tick model, against
every step in the plan (§8 P1–P15, §9 steps 1–13, §7 overlay). No step mutates
`Transcript2Coordinator`, `Transcript2Controller`, `TranscriptScrollViewFactory`,
`BlockCellView`, the layout files, or the `apply` / `cacheLayouts` / `makeLayout`
machinery. The renderer interior is untouched.

- **§2.19 attach contract** — Step 13 (`TranscriptSwapCoordinator`) is a
  *verbatim move* of `attachSession`'s body, fenced by the two real merge gates.
  Both gates exist and are not snapshot-skipped (no `Snapshot` suffix):
  `cctermTests/TranscriptReentryLayoutCacheTests.swift` (factory contract) and
  `cctermTests/TranscriptHostReentryLayoutCacheTests.swift` (production
  `present → attachSession` path). FACT.
- **chat-I5 flush-before-bind** — The load-bearing `finishTranscriptFadeOut()`
  flush sits at the *head* of `attachSession`
  ([ChatSessionViewController.swift:306](../../macos/ccterm/App/AppKit/ChatSessionViewController.swift),
  comment :296-305) — before `factory.make` (:341), before
  `layoutSubtreeIfNeeded` (:366), before `bindData` (:367). The plan (§8 P5,
  §10 item 3) explicitly keeps this ordering inside the new coordinator's
  `attach` head and never lets the optional P6 helper own it. FACT-verified the
  real ordering matches what the plan claims to preserve.
- **The full attach sequence** the plan cites
  (factory.make → addSubview → layoutSubtreeIfNeeded → bindData → scrollToTail →
  drop outgoing last) is **exactly** the real code: make :341, `addSubview(...,
  positioned:.below, relativeTo: topScrim)` :353, constraints :354-359,
  `layoutSubtreeIfNeeded()` :366, `bindData` :367, `scrollToTail()` :386,
  synchronous outgoing dismantle *last* :452-456 inside the disabled-animation
  transaction (:338-339, commit :458). FACT.

"Verbatim move behind both merge gates" is a sufficient guard **provided** the
move does not reorder the cross-VC seam — see Major 1. The merge gates catch a
reordered `bindData`/`layoutSubtreeIfNeeded` or an extra attach-time tile
(`TranscriptHostReentryLayoutCacheTests` is documented and verified to fail
against exactly those three regression shapes — NativeTranscript2/CLAUDE.md
§2.19 table). What the gates do **not** catch is the z-order / scrim-cutout /
identity-guard wiring that lives *around* the typeset sequence; those are
runtime-correctness, not single-width, and the plan must carry them by hand.

---

## What I ENDORSE

1. **§7 permission-card overlay diagnosis is forensically correct.** The card
   ZStack is at
   [InputBarChrome.swift:126](../../macos/ccterm/Content/Chat/InputBarChrome.swift)
   inside `ChatRestingBar` (struct at :111), the card is placed at
   `.padding(.bottom, chatBottomInset)` :164, and the body-level
   `.animation(.smooth(duration:0.25), value: session.pendingPermissions.first?.id)`
   is at :166 — driving both the card's `.transition` and the host's intrinsic
   height. The host is `composeOrBarHost: NSHostingView<AnyView>`,
   `sizingOptions = [.intrinsicContentSize]`, bottom-anchored with **no height
   constraint** ([ChatSessionViewController.swift:169, :202-204](../../macos/ccterm/App/AppKit/ChatSessionViewController.swift)).
   The "transcript inset is fixed 112, does not jump" claim is consistent with
   the bottom scrim being a fixed `bottomFadeScrimHeight` constraint (:200) — the
   inset is not data-driven. The root cause "card size → bar-host intrinsic
   height → animated band growth" is FACT-accurate. All §7 claims FACT.

2. **§7.4 M1 (constant must be `chatBottomInset` 36, not `bottomFadeScrimHeight`
   100) is correct.** The card's offset in the real code is `chatBottomInset`
   (:164). `bottomFadeScrimHeight = 100` (:59) and `chatBottomInset = 36` (:61)
   are independent constants; the scrim height is unrelated to card offset. M1
   prevents a real parity break. FACT.

3. **§7.4 M2 (unconditional `PassthroughHostingView`, do not bet on
   `Color.clear`) is correct and well-justified.** The scrim's pure-NSView
   `hitTest → nil` is real
   ([TranscriptScrimView.swift:61](../../macos/ccterm/Components/TranscriptScrimView.swift)),
   and the production comment states the scrims are deliberately *not*
   `NSHostingView` "so they don't register cursor rects that would shadow the
   transcript's I-beam"
   ([ChatSessionViewController.swift:89-91](../../macos/ccterm/App/AppKit/ChatSessionViewController.swift)).
   A plain `NSHostingView` "claims every point in its bounds for hit-testing"
   (production comment :163-164). A 4-edge-pinned full-pane hosting view over the
   transcript therefore **does** risk shadowing the I-beam cursor and clicks over
   the *entire* transcript — blast radius far larger than today's bottom-only
   ZStack. M2's mitigation (explicit `hitTest` returning `nil` outside the card,
   mirroring the verified scrim pattern) is correct and necessary, not
   optional. FACT + endorsed INFERENCE.

4. **§7's existing gate `DetailPaneTranscriptHitTestTests` is the right guard
   and it exists.** It drives `.leftMouseDown` through the real `view.hitTest`
   path and asserts the transcript stays selectable across session switches —
   its header explicitly "refutes the 'a full-bleed overlay covers the
   transcript' hypothesis"
   ([DetailPaneTranscriptHitTestTests.swift:25, :47, :244](../../macos/cctermTests/DetailPaneTranscriptHitTestTests.swift)).
   This is exactly the regression a mis-built `permissionCardHost` would cause.
   FACT.

5. **§8 P8 exclusion of `TurnUsageMeter` is the right call.** `turnUsage` (:258)
   and `turnStartedAt` (:270) are `@ObservationIgnored` and ride the imperative
   `onTurnUsageChange` sink (:262) via `publishTurnUsage`
   ([SessionRuntime.swift:253-270](../../macos/ccterm/Services/Session/Session/SessionRuntime.swift)),
   wired at attach with a `currentSession === session` identity guard
   ([ChatSessionViewController.swift:436-442](../../macos/ccterm/App/AppKit/ChatSessionViewController.swift)).
   Extracting it would either break the synchronous fire site or the
   `turnStartedAt`-relative-to-streaming-reset ordering — it genuinely fails the
   plan's own "don't touch fire/ordering" rule. FACT. Correctly excluded.

6. **§8 P8 "observation nesting trap" (MAJOR self-flag) is real.** `tasks`
   (:339) and `todos` (:347) are *tracked* `@Observable` fields (the runtime is
   `@Observable` at :16 and these are not `@ObservationIgnored`); SwiftUI reads
   them via `session.tasks` / `session.todos` (e.g.
   [BackgroundTaskButton.swift:30](../../macos/ccterm/Content/Chat/InputBarControls/BackgroundTaskButton.swift)).
   Extracting them into sub-objects requires the sub-object be `@Observable` and
   held by an `@Observable`-tracked property, or live re-render breaks. The plan
   names this and demands the tests assert live re-render, not terminal value.
   FACT — the trap is real and correctly flagged.

7. **§8 P4 m1 nullability note is accurate.** `requestContextUsage` uses the
   computed `guard let runtime`
   ([Session.swift:393-401](../../macos/ccterm/Services/Session/Session/Session.swift)),
   and `BackgroundTaskButton.stopAction` returns `nil` when `runtime == nil`
   ([BackgroundTaskButton.swift:80-83](../../macos/ccterm/Content/Chat/InputBarControls/BackgroundTaskButton.swift)).
   The plan's "mirror `requestContextUsage`'s `guard let runtime`, `.draft`
   no-op, note the nullability change in the commit" is correct. FACT.

8. **§8 M3 (demo VC migration is non-trivial) is correct.**
   `PermissionSessionDemoViewController` renders `ChatRestingBar` through a
   `GeometryReader` + `DemoBarHeightKey` PreferenceKey + height-constraint loop
   ([PermissionSessionDemoViewController.swift:11, :106, :124-133](../../macos/ccterm/Content/PermissionSessionDemo/PermissionSessionDemoViewController.swift)).
   Removing the card from `ChatRestingBar` forces a real demo rewrite. FACT.

9. **§10 item 5 (`nonisolated deinit` on new types) matches convention** — 32
   files already carry it, including every VC the plan touches. FACT.

---

## Majors (must fix before Step 13 / Step 5 land — none are contract violations)

### Major 1 — "verbatim move" is necessary but the cross-VC seam needs an explicit contract, and the merge gates do NOT cover it.

The plan (§8 P5 "验证修正(接缝)") already names three seam points: z-order anchor
(`addSubview(scroll, positioned:.below, relativeTo: topScrim)`), the
`currentSession === session` identity guard shared by the turn-usage and
running-obs sinks, and first-screen logging/focus staying on the VC. I confirm
all three are real:

- z-order anchor at [ChatSessionViewController.swift:353](../../macos/ccterm/App/AppKit/ChatSessionViewController.swift)
  references `topScrim`, which stays on the VC — so the coordinator must be
  handed `topScrim` (or an insert closure). FACT.
- `currentSession === session` guards both the turn-usage sink (:439) and
  `startRunningObservation` (:537). The plan says "decide who owns
  `currentSession`" but does **not** decide it. This is load-bearing: if the
  coordinator owns the incoming-scroll lifecycle but the VC owns
  `currentSession`, the two can desync across a crossfade and a stale sink can
  call `setTurnUsage` / `setLoading` on the wrong controller. INFERENCE: pick
  one owner and route the other's reads through it; do not duplicate the
  `currentSession` field across both objects.
- `applyScrimCutouts()` converts rects *from* `composeOrBarHost` into
  `bottomScrim`'s coord space (:231-233) and is called from the rect sinks
  (:560, :565). If `transcriptScroll` moves to the coordinator but the scrims
  and `composeOrBarHost` stay on the VC, the cutout path must keep working. The
  plan does not mention this seam. FACT that it exists; INFERENCE that it's an
  uncovered seam.

**Neither merge gate exercises these** — `TranscriptHostReentryLayoutCacheTests`
asserts single-width typeset, not cursor cutouts or sink identity. So "verbatim
move behind both gates" is sufficient for the §2.19 contract but **insufficient
for runtime correctness of the swap**. Fix: add the seam ownership decision to
Step 13's spec, and lean on `DetailPaneTranscriptHitTestTests` (which *does* run
through the real swap) as the cutout/hit-test guard.

### Major 2 — `permissionCardHost` z-order vs. the per-attach transcript insert is unspecified, and it interacts with Step 13.

Subview order at `loadView`: `topScrim` (:155), `bottomScrim` (:159),
`composeOrBarHost` (:170). On every attach the transcript scroll is inserted
`.below topScrim` (:353) — i.e. *behind* both scrims and the bar host. §7.3 adds
`permissionCardHost` "as a sibling," but the plan never pins where in the
sibling order it goes relative to (a) the scrims and (b) the per-attach
transcript insert. If `permissionCardHost` is added at `loadView` after
`composeOrBarHost`, it sits on top — correct for an overlay — but the §2.19
attach then inserts each new scroll `.below topScrim`, which is also below
`permissionCardHost`. That is the intended layering, **but** it means the
overlay host is permanently above every transcript swap, so the M2
PassthroughHostingView is not a nice-to-have — a non-passthrough host here
shadows the I-beam across every session for the VC's whole life, not just while
a card is shown. The plan gets M2 right; what's missing is stating the z-anchor
explicitly so Step 13's "treat `permissionCardHost` as the 4th sibling host"
(§9 ordering note) doesn't accidentally re-insert transcripts above it. Fix:
specify `permissionCardHost` is added once at `loadView` *after* `composeOrBarHost`
and that the attach insert stays `.below topScrim` (so transcripts remain below
the overlay), and assert it via `DetailPaneTranscriptHitTestTests` after Step 5.

---

## Minors

- **m1 — `contextUsage` is a tracked `@Observable` field, not a pure value.**
  `contextUsage` (:310) and `contextUsageFetchedAt` (:313) are *not*
  `@ObservationIgnored`. §8 P8 calls `ContextUsageCache` "a pure value" and the
  target tree (§5) tags it `[value]`. If a SwiftUI reader observes
  `session.contextUsage` reactively today, demoting it to a plain value struct
  inside a sub-object would still need that sub-object to be `@Observable`-tracked
  to preserve re-render — same nesting trap as tasks/todos, not the simpler
  "value" case the plan implies. Verify the reader set before treating it as a
  value. (`contextUsagePendingCallbacks` at :321 *is* `@ObservationIgnored`, as
  expected.) FACT on the attributes; INFERENCE on the risk.

- **m2 — §10 item 2 wording "scrolltoTail() before bindData" is not what the
  code does; the doc-wall paraphrase is slightly loose.** §10 item 2 lists
  `factory.make(unbound) → addSubview+约束 → host layoutSubtreeIfNeeded() →
  factory.bindData → scrollToTail()`. That order is correct (matches :341-386).
  No fix needed to the code; just flagging that the wall is a paraphrase and the
  authoritative ordering is the source — reviewers of future steps should diff
  against `attachSession`, not the wall prose.

- **m3 — the plan's component tree labels the card path through
  `ChatRestingBar`, which is right, but §7.3's ASCII still shows
  `restingBarHost → ChatRestingBar → InputBarChrome` while the card闭包 are
  today inline in `ChatRestingBar` (:143-162), not in `InputBarChrome`. The
  "decision wiring moves verbatim from `ChatRestingBar`" is accurate (the 4
  closures call `session.respond(...)` at :146-155). No correctness issue;
  ensure the verbatim move pulls from `ChatRestingBar`, not `InputBarChrome`.

---

## Explicit answers

- **Did the plan break the perf contract?** No. No step enters the renderer
  interior; §2.1–§2.19 are untouched; §2.19's two merge gates are preserved and
  exist.
- **Did the plan regress functionality?** Not on the paths checked, *provided*
  Major 1 (swap seam ownership) and Major 2 (overlay z-anchor + unconditional
  PassthroughHostingView) are honored. The §7 overlay, if built per M1+M2, is
  behavior-preserving and is guarded by a real hit-test gate.
- **Did the plan over-engineer?** No — it de-scopes the speculative pieces (P6
  optional, P7 shrunk/dropped, P8 excludes TurnUsageMeter, P9/P11 deferred) and
  §11 is a credible anti-gold-plating wall.
- **Internally inconsistent?** Only m1 (calling `contextUsage` a "pure value"
  when it is a tracked `@Observable` field) is a small inconsistency with the
  plan's own nesting-trap warning.

All findings cite real source; FACT = read, INFERENCE = judgment, marked inline.

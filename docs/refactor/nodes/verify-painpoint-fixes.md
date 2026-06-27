# Adversarial verification: design-painpoint-fixes.md

Read-only review against the worktree source. Verdict, then blockers /
majors / minors / endorsements. Every claim cited file:line.

## Verdict: **sound-with-fixes**

No proposal weakens a load-bearing transcript §2 item, the §2.19 attach
contract, the synchronous selection spine, or a runloop-tick invariant —
verified directly against the code. The design is unusually disciplined about
this (it repeatedly *routes around* the contracts rather than through them).
The DI/forwarder cleanups (P1/P2/P4/P10b) are factually accurate and low-risk.

The one substantive defect is in the **priority item (§0 permission-card
overlay)**: the card-placement constant it chose (`cardLiftAboveBar = 100`)
does **not** reproduce the current card position (bottom-flush with the bar via
`chatBottomInset = 36`), and the design contradicts itself on this point. That
is a parity break in the priority deliverable, fixable with a corrected
constant. Plus an unproven AppKit hit-test premise that the design itself flags
but the merge-gate snapshot test cannot catch. Neither is a perf-contract
blocker; both are correctness/parity issues that must be resolved before §0
lands.

---

## BLOCKERS (perf contract / attach contract / runloop)

**None.** I specifically checked:

- §0 overlay never touches the coordinator, `layoutCache`, `contentInsets`, or
  the attach path. It is a sibling `NSView`/`NSHostingView` pinned over the
  pane. The transcript scroll view, `TranscriptScrollViewFactory.make/bindData`,
  and `scrollToTail` (`ChatSessionViewController.swift:341-386`) are untouched.
  §2.19 single-width contract is not in the overlay's path. **Endorsed.**
- §7 (P5/P6 crossfade/swap) explicitly preserves the load-bearing
  `removeObserver` flush ordering (`attachSession`'s `finishTranscriptFadeOut()`
  at `ChatSessionViewController.swift:306`, the note at :296-306) and the
  §2.19 contract, and instructs "STOP rather than weaken." The design correctly
  identifies the blanket `removeObserver(coordinator)` hazard
  (`finishTranscriptFadeOut` at :499-506) as the thing any shared abstraction
  must not reorder. **Endorsed; defer to last as written.**
- §8 (runtime projections) and §6 (grouping rules) both pin the synchronous
  `onMessagesChange` fire contract and the `receive` side-effect ordering and
  require the extracted pieces to be *pure*. Consistent with
  `Services/Session/CLAUDE.md` Rules. **Endorsed in principle** (these are
  large; risk is in execution, not in the design's stated invariants).

---

## MAJORS

### M1 — §0 card placement constant is wrong; the design self-contradicts (parity break)

The design's `PermissionCardOverlay` lifts the card with
`.padding(.bottom, cardLiftAboveBar)` where
`cardLiftAboveBar = ChatSessionViewController.bottomFadeScrimHeight = 100`
(design §0.4.2 line 221-223, §0.6 line 301-305).

But the **current** card placement (`InputBarChrome.swift:124-166`) is:

- `ZStack(alignment: .bottom)` containing BOTH the bar and the card;
- a single `.padding(.bottom, ChatSessionViewController.chatBottomInset)` (= 36,
  `ChatSessionViewController.swift:61`) applied to the **whole stack** at
  `:164`.

So today the **card's bottom edge is flush with the bar's bottom edge** (both at
36pt from the host bottom); the card draws *on top of* and *covers the bar's
chrome row*, extending upward. The design even asserts this in §0.4.3:
"the card only covers the bar's chrome row region while pending, exactly as
before" (line 256), and `PermissionCardView`'s own doc comment confirms
"Bottom edge sits flush with the chrome row … by way of the same
`chatBottomInset` padding" (`PermissionCardView.swift:10-12`).

`cardLiftAboveBar = 100` places the card's bottom edge at the bar's **top**
edge (100 = `chatBottomInset 36 + chrome ~22 + barSpacing 10 + pill 32`, the
bar-band height per `ChatSessionViewController.swift:56-59`). That is a
*different* position — the card would float entirely above the bar, no longer
overlapping the chrome row. This directly contradicts the design's own §0.4.3
parity claim and the §0.5 table row "Card placement … same offset."

**Fix:** to reproduce current placement exactly, the card's bottom padding must
be `chatBottomInset (36)`, not `bottomFadeScrimHeight (100)` — the card sits
bottom-flush with the bar and overlaps it on the z-axis, which is the whole
point of the original ZStack. The "scrim/inset coupling" reuse argument in §0.6
is mis-derived: the bottom scrim's 100 is the bar-band height for the *fade*, not
the card's bottom offset. If the design instead *wants* the card to sit above the
bar (a deliberate visual change), it must say so and update the snapshot —
but then "exactly as before" / "same offset" are false. Either way the doc is
currently inconsistent and the chosen constant breaks parity.

### M2 — §0 hit-test passthrough premise is unproven and the merge gate can't catch a regression

The design's load-bearing assumption is that an `NSHostingView` over the whole
pane with a `Color.clear.allowsHitTesting(false)` background returns `nil` from
`hitTest` over the clear area, so transcript clicks fall through (inv 3, §0.4.1
lines 146-166). The design *itself* flags this as INFERENCE and notes
`NSHostingView` "historically claimed its whole bounds for tracking-area/cursor
purposes" (lines 158-166), recommending the 6-line `PassthroughHostingView`
"only if a hit leaks."

This is the correct instinct but the design's proposed verification is
insufficient: it says "Verify the plain-clear-background approach first via
`PermissionCardSnapshotTests` + a click-through unit test." A snapshot test
renders pixels — it **cannot** observe hit-testing. And there is no existing
click-through unit test; the design assumes one can be written, but
`ChatSessionViewController`'s scrims achieve passthrough only because they are
**pure `NSView` with an explicit `hitTest → nil`** (`TranscriptScrimView.swift:61`),
*precisely because* `NSHostingView` passthrough was not trusted — this is
documented at `ChatSessionViewController.swift:89-91` ("The scrims are pure
AppKit (no `NSHostingView` so they don't register cursor rects that would shadow
the transcript's I-beam)").

That comment is strong evidence the plain-clear-background path will regress the
transcript's I-beam cursor and possibly clicks in the band the overlay covers
(the entire pane above the bar). **Recommendation: skip the "try plain first"
step and ship the `PassthroughHostingView` override unconditionally**, mirroring
the proven scrim pattern. The design's fallback is correct; its preferred path
is unsafe and untestable by the gate it names. Also note: the overlay is pinned
over the *whole* pane (4 edges, §0.4.1 lines 138-143), so any passthrough leak
shadows the **entire transcript**, not just the bar band — a much larger blast
radius than the current ZStack (which only grows the bottom-anchored bar host).

### M3 — §0 demo VC migration changes what the demo demonstrates

`PermissionSessionDemoViewController.installInputBar` renders `ChatRestingBar`
directly (`PermissionSessionDemoViewController.swift:106-145`) and uses the
GeometryReader+PreferenceKey+height-constraint loop (:121-144) the design wants
to kill (§0.7 line 333-337). But that demo's *purpose* is to exercise the
card-grows-the-bar-host coupling. Once §0.4.4 strips the card from
`ChatRestingBar` (lines 259-283), the demo's `ChatRestingBar` renders only the
bar — the card never appears in the demo unless the demo *also* mounts the new
`permissionCardHost`. The design says to do exactly this ("replaced with the
same `permissionCardHost` overlay"), which is correct, but it is **not**
"kills smell #6 for free" — it's a non-trivial rewrite of the demo VC's mount
(add the full-bleed host + the overlay + environment injections), and the demo's
existing height-constraint loop is load-bearing for the *bar* host there
(comment at :115-120 explains it severs window-collapse). The design must keep
the bar-host height loop (or switch the bar host to the same
`[.intrinsicContentSize]`+bottom-anchor regime production uses) AND add the
overlay. Flag as more work than "opportunistic."

---

## MINORS

### m1 — P4: dropping the `nil`-returning `stopAction` subtly changes a visibility gate

`BackgroundTaskButton.stopAction` returns `nil` when `session.runtime == nil`
(`BackgroundTaskButton.swift:80-85`), and `BackgroundTaskDetailSheet` hides the
stop button when `onStop == nil` (`BackgroundTaskDetailSheet.swift:245` —
`if task.status == .running, let onStop`). The proposed
`session.stopBackgroundTask` forwarder is non-optional, so `stopAction` would
become a non-nil closure always. This is **safe in practice** (the button only
renders when `!session.tasks.isEmpty`, and tasks require an active runtime, so
the draft branch is unreachable), but the design's blanket claim "`runtime?.x`
is exactly the behavior of the old `guard let runtime` unwrap" (§3 line 487)
glosses over the nullability-contract change. Note it explicitly, or keep
`stopAction` returning `{ session.stopBackgroundTask(taskId:) }` only when a
task surface exists. Low harm; worth a sentence.

### m2 — P1 site count is off by the demo

§1 (line 372-376) says "all 5 (+1 demo) host sites." There are exactly **5**
production injection sites (`DetailRouterViewController.swift:434-435`,
`ChatSessionViewController.swift:580-581`, `ArchiveViewController.swift:79-80`,
`ComposeSessionViewController.swift:104-105`,
`DraftSessionLandingViewController.swift:127-128`) — verified by grep. The
`permissionCards` DEBUG demo *also* injects them
(`DetailRouterViewController.swift:434-435` is the demo branch's `PermissionCardsDemoView`
host, lines 428-436), so the "+1 demo" is actually folded into the 5 if you
count branches, or a 6th if you count the `PermissionSessionDemoViewController`
(which does **not** inject them — it only injects `seed.manager` +
`inputDraftStore`, `PermissionSessionDemoViewController.swift:113-114`). The
count is loose but the underlying fact (zero SwiftUI consumers of
`NotificationService`/`TranscriptSearchBus`) is **verified true** — grep for
`@Environment(NotificationService` / `@Environment(TranscriptSearchBus` returns
0. P1 is sound; just tighten the site inventory.

### m3 — §0 overlay re-resolves the session twice

`PermissionCardOverlay.body` (design lines 187-191) reads the pending via
`manager.existingSession(sid)?.pendingPermissions.first` then wires decisions
via `manager.prepareDraftSession(sid)`. Both return `sessions[sessionId]` for an
existing session (`SessionManager.swift:208-209, 217-218`), so they're the same
instance and this is correct — but using two different accessors for the same
object in one body is needless. Use one (`existingSession`, guard non-nil) for
both. Cosmetic.

### m4 — `PermissionCardOverlay` takes `MainSelectionModel`, but the card only ever shows for `.session`

The overlay guards `case .session(let sid)` (design line 187). Good — matches
`ChatComposeStack.content` routing (`ChatSessionViewController.swift:628-639`)
and `ChatComposeStackRoutingTests` semantics (inv 6). But note the overlay is
mounted for the *lifetime* of `ChatSessionViewController`, which the router only
mounts for `.session(_)` / `.none` anyway (`ChatSessionViewController.swift:39-40`
header). So the `model`-driven guard is belt-and-suspenders, identical to the
existing `ChatComposeStack` pattern — fine, just observe it's redundant with the
router's VC-kind gating. Not a defect.

### m5 — snapshot test rewrite is larger than "byte-identical"

§0.7 (line 329-332) claims the updated `PermissionCardSnapshotTests` renders a
"byte-identical" card. The current `testCardOverInputBarSnapshot` uses
`InputBarChromeMirrorFixture` (`PermissionCardSnapshotTests.swift:214-247`)
which hand-mirrors the **ZStack(alignment:.bottom) card-flush-to-bar** layout
(lines 220-238). If the overlay changes placement (see M1), the rendered
composition PNG changes — not byte-identical. The card *body* is identical; the
*composition* is not. Minor doc imprecision, but it interacts with M1: resolve
M1 first, then the snapshot claim becomes true.

---

## What I ENDORSE (verified correct, keep as-is)

- **No perf-contract weakening anywhere.** The §0 overlay, P5/P6, P7, P8 all
  explicitly preserve §2 / §2.19 / synchronous fire / observer-flush ordering,
  and the design's "stop and route around" rule (§0.8, §7 line 626, §11) is the
  right posture. Verified the overlay never touches the transcript pipeline.
- **P1 premise (dead env injections).** Zero SwiftUI consumers of
  `NotificationService` / `TranscriptSearchBus` — grep-confirmed. Pure deletion
  of unread injections. Safe.
- **P2 `DetailContext` bundling.** The 7-arg fan-out is real and repeated 4× in
  `makeChild` (`DetailRouterViewController.swift:366-404`); each child re-declares
  the identical 7 stored props + init. Collapsing to one struct is a clean
  1-site DI edit and keeps the "views never construct services" rule (the struct
  is assembled at `MainSplitViewController`, not by a view). The rejection of
  "inject `AppState` whole" is correct (demo VCs take only `syntaxEngine:`,
  `:416-422`; the children genuinely need a 4-7 field subset, not the whole
  container). Sound.
- **P4 forwarder.** `BackgroundTaskButton.stopAction` is the only production UI
  piercing `session.runtime` (`BackgroundTaskButton.swift:81-84`); the
  `requestContextUsage` precedent the design mirrors is real
  (`Session.swift:393-402`). Restores the single-channel rule; the fix is in the
  product, not a test hook — aligns with the engineering principle. (Address m1.)
- **P10b rename** (`searchEngine` → `syntaxEngine`). Confirmed the property is
  named `searchEngine` but feeds `\.syntaxEngine` (`ChatSessionViewController.swift:69,579`;
  `DetailRouterViewController.swift:75,433`) — a genuine cross-wire with
  `searchBus`. Identifier-only, compiler-enforced. Sound; fold into P2.
- **The §0 core mechanism (constant size overlay, no host-height feedback).**
  The root cause analysis is *correct*: the bar host is
  `sizingOptions = [.intrinsicContentSize]`, bottom-anchored, no height
  constraint (`ChatSessionViewController.swift:169,202-207`), and the card grows
  the ZStack union → grows the host (`InputBarChrome.swift:143-166`). A
  fill-pane `[]` overlay whose own size is constant *does* decouple card presence
  from bar-host height. The architecture is feasible and the chosen sizing
  regime (`[]` + 4-edge pin) is the documented-safe one (root CLAUDE.md "host
  sizing"). The fix is the right shape — it just needs the correct placement
  constant (M1) and the proven passthrough host (M2).
- **Don't-over-engineer section (§9).** Leaving P9 (phase-dispatch façade),
  P10a (intentional triple closure-sink), and P11 singletons alone is the right
  call — these are boilerplate / intentional, not tangled flow. No ceremony
  added.

## Over-engineering assessment

The design is **not** over-engineered. It explicitly declines the tempting
abstractions (don't merge Controller/Coordinator, don't inject `AppState`
whole, don't unify the two crossfades if it costs the observer-flush order,
leave the 40-forwarder façade). `DetailContext` (P2) earns its keep (1-site DI
vs 5-6). The only place to watch is P5/P6 — a shared `Crossfade` +
`TranscriptSwapCoordinator` is the highest-ceremony item, but the design
correctly gates it last and tells the implementer to abandon it rather than
weaken §2.19 / observer-flush. That is the right guardrail.

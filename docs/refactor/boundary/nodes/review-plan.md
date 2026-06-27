# Adversarial review — plan-taxonomy-and-tests.md

Reviewer stance: default skepticism. Every claim below is checked against live
code in this worktree. **FACT** = read in source. **INFERENCE** = my judgment.

Verdict: **sound-with-fixes**. The taxonomy is accurate and the regime A / regime
B mechanics match the real code line-for-line. But the test plan has one
structural defect (it silently re-creates an existing CI gate), one teeth gap (the
A/B "proof" never actually collapses a window), and several seam / sequencing
imprecisions that will bite the implementer. None are fatal; all are fixable
before a line of test code is written.

---

## What the plan gets right (endorsed)

1. **Regime A mechanism is correct, with file:line.** `ArchiveViewController.swift:83-113`
   — default `NSHostingController.sizingOptions` publishes `view.fittingSize` (the
   comment at `:97` records ≈ 545×276); `sizingOptions = []` + 4-edge pin
   (`:102-111`) severs it. **FACT.** The plan's claim that the Binding is *not* the
   collapse cause is correct: the collapse reproduces on first mount before any
   binding write, and three other fill-pane children with **no** boundary-crossing
   binding need the identical fix — `ComposeSessionViewController.swift:115`,
   `DraftSessionLandingViewController.swift:136`,
   `DetailRouterViewController.swift:443` (DEBUG permission-cards). **FACT** (all
   four `sizingOptions = []` sites verified).

2. **The "binding is the pump under a leaking regime" synthesis is sound.** The
   toolbar write site `MainWindowController.swift:321` (`model.archiveSelectedFolderPath = path`)
   feeds the two-way binding `ArchiveViewController.swift:63-66`; under default
   options each body re-eval republishes the small fittingSize. This correctly
   explains the user's "two-way binding squashed the window" report as a
   *symptom-attribution* error, not the root cause. **FACT for the wiring,
   INFERENCE for the causal synthesis** — and it's a defensible inference.

3. **Regime B centering recipe is accurately transcribed.** `ChatSessionViewController.swift:182-208`
   — `centerX` + `width<=820 required` + `width==820 @high (defaultHigh)` +
   `leading >= view.leading` + `bottom == view.bottom`, with
   `sizingOptions = [.intrinsicContentSize]` (`:169`). The cap math
   `maxHostWidth = BlockStyle.maxLayoutWidth(780) + 2*detailHorizontalInset(20) = 820`
   is correct (`:182`). The `ChatRestingBar` body uses `.frame(maxWidth: .infinity)`
   (`ChatSessionViewController.swift:673`), so the host width resolves to the
   `@high` cap on a wide pane and yields to `leading>=` on a narrow one — exactly
   as the plan's two-leg (wide 1100 / narrow 680) test design predicts. **FACT.**

4. **Constants are reusable as claimed.** `BlockStyle.maxLayoutWidth = 780` is
   `nonisolated static let`, internal (`Block.swift:1104`); `detailHorizontalInset`
   / `composeMaxWidth` are `internal static let`
   (`ChatSessionViewController.swift:60,62`); `currentChild` is `private(set) var`
   readable via `@testable` (`DetailRouterViewController.swift:89`). Computing the
   820 cap *in the test* from the constants (not hardcoding) is the right call.
   **FACT.**

5. **Window-size-as-evidence is correctly reasoned.** A collapse target ≈ 276;
   a healthy 860 dwarfs it; `minSize.height = 540` sits strictly between so the
   AppKit min-clamp can't mask a partial collapse. A small/flat window cannot
   detect this. **FACT** (matches `research-painpoints.md` §1.5).

6. **Taxonomy completeness is adequate.** Regimes A / B / B′ / B″ / C / D map to
   real sites; E (leaf-in-cell) has no production instance (transcript is Core-Text
   self-drawn — confirmed via the architecture doc). The four extra regimes need
   no new gate because none has a collapse failure mode. **FACT/INFERENCE, sound.**

---

## mustFix — the implementers MUST honor these

### MF-1 (structural, highest priority) — Test (a) duplicates an existing CI gate; the plan never says so.

`DetailRouterLayoutDiagnosticsTests.testArchiveSelectionDoesNotFlattenWindow`
(`DetailRouterLayoutDiagnosticsTests.swift:104-165`) **already exists and already
runs on CI**. It is the *same* test the plan proposes as new file
`AppKitSwiftUIBoundaryTests.swift` test (a): same `makeFixture`, same real
two-item `NSSplitViewController`, same **1200×860** window, same `minSize 880×540`,
same detail `minimumThickness = 680`, same `.newSession → .archive` flip, same
`archiveHeight >= chatHeight - 1` assertion (`:161-164`), even the same fittingSize
diagnostic attachment (`:150-159`).

The plan's own research (`research-painpoints.md:124-125`) acknowledges this is
"the live merge gate" — but `plan-taxonomy-and-tests.md` §2.1 presents test (a) as
net-new without referencing the existing file. Shipping it as written produces a
**near-verbatim second copy** of a CI gate. That is dead weight and a maintenance
hazard (two files to keep in lockstep).

**Fix — pick one, state it explicitly in the plan:**
- (preferred) Do NOT recreate the height-collapse test. Instead **extend the
  existing `DetailRouterLayoutDiagnosticsTests`** with the genuinely-new assertions
  (the `currentChild.view.fittingSize.height <= 1` isolation in MF-2, the
  binding-pump neutrality, and the compose/draft-landing coverage from test (c)).
  Reserve `AppKitSwiftUIBoundaryTests.swift` for the parts that are actually new.
- OR, if a fresh "boundary taxonomy" file is wanted for discoverability, the
  existing diagnostics test's height-collapse method should be **moved** (not
  copied) into it, and the diagnostics file's comment updated to point at the new
  home. Never leave two copies.

### MF-2 — Test (b) ("teeth") never actually collapses a window; it does not prove what the plan claims.

The plan §2.1(b) says test (b) "proves the probe can DETECT a collapse, so test
(a) isn't vacuously green." But as specified it mounts a throwaway
`NSHostingController` **in isolation** (no window, no split) and asserts only on
`host.view.fittingSize.height` (default options ⇒ small; `[]` ⇒ ~0). That proves
the *host publishes* a small fitting size under default options — it does **not**
prove that small fitting size *propagates up a split and collapses a window*. The
load-bearing link (fittingSize → split.fittingSize → window constraint solver) is
exactly the part left untested.

Net effect: neither test (a) (fixed code, no collapse) nor test (b) (isolated
fittingSize) ever observes a real window collapse. The pair is **not** teeth — it
cannot distinguish "the gate would catch a regression" from "the gate is vacuous,"
because nothing in the suite drives the broken regime through the full constraint
chain. (This is an inherent limitation of testing against fixed production code —
you can't mutate production `sizingOptions`, correctly — but the plan oversells
test (b) as solving it.)

**Fix:**
- Keep the isolated `[]` vs default fittingSize contrast (it is a real, cheap unit
  fact) but **re-label** it honestly: it asserts the *measurement dimension
  responds to the regime*, not that a window collapses.
- Add the real teeth: build a **second throwaway host with default sizingOptions,
  mount it as the detail item of a real `NSSplitViewController` in the same
  1200×860 window**, and assert the window height **collapses** (e.g. drops below
  ~400, well under 860). That is the A/B that proves the *whole chain* (not just
  the host's fitting size) reproduces a collapse, and it stays inside the
  production-code rules because the host + body are test-local — you are NOT
  mutating a production VC's sizingOptions. THIS is the genuinely new, valuable
  test the file should center on; it's what the existing gate (MF-1) does NOT
  cover (the existing gate only ever runs the fixed path).
- The `currentChild.view.fittingSize.height <= 1` isolation assertion (plan
  §2.1(a) "stronger isolation") is good and should land — but on the fixed
  production path it belongs with the existing gate (see MF-1).

### MF-3 — Test (c) draft-landing routing: spell out the `.draft`-status record requirement, or the test silently exercises the wrong child.

The plan says route to `DraftSessionLandingViewController` via
`model.select(.session(draftSid))`. That only works if
`sessionManager.isDraftSession(sid)` returns true, which for an *uncached* id
requires `repository.find(sid)?.status == .draft`
(`SessionManager.swift:199-202`; routing at `DetailRouterViewController.swift:257-261`).
The existing `makeFixture` saves records with `status: .created`
(`DetailRouterLayoutDiagnosticsTests.swift:42`) — **not** `.draft`. A `.created`
id routes to `.transcript` (`ChatSessionViewController`), NOT draft-landing, so the
test would silently assert against the wrong child and prove nothing about
`DraftSessionLandingViewController`.

**Fix:** the fixture for test (c) must save a dedicated record with
`status: .draft` (and assert `router.currentChild is DraftSessionLandingViewController`
before sampling height, so a routing regression fails loudly instead of passing
vacuously). The plan's hedge ("confirm the exact draft-landing selection enum")
is not enough — make the `.draft` record an explicit, mandatory step.

### MF-4 — Snapshot test (§2.3) sequencing is incompatible with `ViewSnapshot.renderViewController` as written.

`ViewSnapshot.renderViewController(_:size:)` (`ViewSnapshot.swift:103-146`) creates
its **own** borderless window, sets the passed VC as `contentViewController`,
settles 0.4s, then snapshots. The plan's §2.3(a) wants to: mount the router in a
split, **select `.archive`, settle**, *then* render the split. You cannot do both —
handing a fresh split to `renderViewController` re-mounts it and renders before any
`.archive` selection + router swap has been driven. The 0.4s default settle is
also shorter than the diagnostics `settle()` (14 × ~60ms ≈ 840ms) that the router
swap + `ArchiveView.task` actually need.

**Fix:** for §2.3(a), mount + select + settle **manually** (reuse the diagnostics
`settle()`), then snapshot the already-mounted view directly via
`view.bitmapImageRepForCachingDisplay` + `ViewSnapshot.writePNG`, NOT via
`renderViewController`. Alternatively, pre-set `model.selection = .archive` and the
router's child *before* handing the split to `renderViewController` so the right
child is mounted at render time — but the manual path is cleaner and matches the
diagnostics harness. §2.3(b) (mount `ChatSessionViewController`, `present(sessionId:)`,
render) is fine through `renderViewController` because no async router swap is
involved — but bump `settle` above 0.4s if the bar's `.task` restore matters.

### MF-5 — The `composeOrBarHost` `private → internal` seam is acceptable, but require an assertion that the right branch rendered.

The seam (`ChatSessionViewController.swift:94`, `private var` → `internal var`,
access-modifier only) is within the allowed column of the production-code rules
(`cctermTests/CLAUDE.md`) — **endorsed**, no behavior change. There is no existing
public accessor, so the seam is genuinely needed. **FACT.**

But: `ChatComposeStack.content(for:)` returns `.none` for every selection except
`.session(_)` (`ChatSessionViewController.swift:628-639`). If the test drives the
VC without a real session selection landing in `model.selection`, the bar host
renders `EmptyView` and its frame is degenerate — the centering asserts would pass
or fail meaninglessly. **Fix:** the centering test must set `model.selection =
.session(sid)` (the same id passed to `present(sessionId:)`) AND assert the host's
hosted content is non-empty (e.g. `composeOrBarHost.fittingSize.height > 0` or the
frame is non-degenerate) before asserting width/centering, so an EmptyView render
fails loudly.

### MF-6 — Centering tolerances: tighten the "height < 0.5 * pane" heuristic; it is too loose to catch a real regression.

The plan §2.2 asserts `frame.height < view.bounds.height * 0.5` for the
component-regime invariant (INFERENCE on the 0.5). On an 800pt pane that permits a
400pt bar — a bar that has wrongly grown to fill the pane could still pass. The bar
is ~tens of pt. **Fix:** assert against a concrete upper bound tied to the bar's
real intrinsic height (e.g. `< 200`, or compute from `chatBottomInset(36) +
bottomFadeScrimHeight(100)` ≈ 136 + margin), not a fraction of the pane. The
centerX (±1) and width (==820 ±1 wide / `<= viewWidth` && `minX >= -0.5` narrow)
tolerances are sane. **INFERENCE.**

---

## Lower-priority notes (not blocking, but improve the plan)

- **N-1 Parallel-safety: the plan's per-test scaffolding is compliant** — the
  reused `makeFixture` uses `InMemorySessionRepository`, a unique
  `UserDefaults(suiteName:)` with teardown, a UUID temp dir with teardown, fresh
  `AppActivationTracker` / `NotificationService(activation:)` /
  `SyntaxHighlightEngine` / `TranscriptSearchBus`; no `*.shared`, no
  `UserDefaults.standard`, no `NotificationCenter.default`. **FACT**
  (`DetailRouterLayoutDiagnosticsTests.swift:34-71`). Keep this; do not factor into
  a shared base (XCTest forks per class — copy is correct).

- **N-2 No `sleep` for sync** — the plan reuses `settle()` which uses
  `Task.sleep(40ms)` interleaved with `RunLoop.run` as a *runloop pump*, not as a
  synchronization barrier on a condition. The diagnostics file already does this
  and is the established pattern; `cctermTests/CLAUDE.md` rule 6 forbids sleep
  *for synchronization* (waiting on a condition) — a fixed-iteration runloop pump
  to let layout/CA settle is the accepted idiom here. **Acceptable**, but where a
  condition is knowable (e.g. `router.currentChild is ArchiveViewController`),
  prefer breaking the pump loop early on that condition (as the bug-#2 test does at
  `:238`) over a fixed 14 iterations.

- **N-3 File naming / CI-gate correctness is correct.**
  `AppKitSwiftUIBoundaryTests.swift` and `HostedComponentCenteringTests.swift` have
  **no** `Snapshot` suffix ⇒ they run on CI (merge gate). `AppKitSwiftUIBoundarySnapshotTests.swift`
  **has** the suffix ⇒ auto-skipped/opt-in. Class names match filenames. **FACT**
  (matches the skip-list rule in `cctermTests/CLAUDE.md:197-201, 308-311`).

- **N-4 Line-ref drift (cosmetic):** plan cites `MainSplitViewController.swift:60`
  for the detail `minimumThickness = 680`; actual is `:59` (`:60` is
  `canCollapse = false`). Plan cites `TranscriptDemoViewController.swift:112-115`
  for the floating demo host; actual constraints are `:113-117`. Harmless but fix
  for precision.

- **N-5 Two-host overlap in regime taxonomy:** `PermissionSessionDemoViewController.swift:134`
  (`sizingOptions = []`, cited in research §1.8) is a fifth fill-pane `[]` site the
  plan's regime-A table omits from "Reference impl." Not required to test (DEBUG
  demo), but the taxonomy table should list it for completeness alongside the other
  four `[]` sites.

---

## Bottom line for implementers

The taxonomy is publishable as-is (modulo N-4/N-5 cosmetics). The test plan needs
restructuring before coding:

1. **Don't duplicate the existing archive-collapse gate (MF-1).** Extend it or move
   it; never two copies.
2. **Make the A/B actually collapse a window via a test-local default-options host
   in a real split (MF-2)** — that, not an isolated fittingSize read, is the teeth,
   and it's the genuinely-new contribution.
3. **Force the `.draft` record for the draft-landing leg (MF-3)** and assert the
   child kind before measuring.
4. **Hand-roll the snapshot mount/select/settle (MF-4)** rather than routing the
   pre-selection flow through `renderViewController`.
5. **Assert the chat branch actually rendered (MF-5)** and **tighten the bar-height
   bound (MF-6)** so the centering gate can't pass on a degenerate or pane-filling
   host.

All proposed production seams (the single `private → internal` widening, constant
reuse, `currentChild` read) are within the allowed access-modifier-only column —
**no forbidden seam in the plan.** The window IS sized correctly (1200×860 with
minSize height 540 below the ~276 collapse target).

# Adversarial review — BOUNDARY-SPEC.md (clean-lens)

Scope: read only `BOUNDARY-SPEC.md` + `nodes/verify-results.md`, then verified
every load-bearing claim against the real production code and the three test
files. I also **re-ran the gates and re-ran the teeth check** (reverted the
production `sizingOptions = []` fix in all three VCs, observed the failures,
restored). Verdict: **sound-with-fixes**. The headline claims hold up; the
issues are honesty/wording gaps and one genuinely-toothless legacy gate the spec
already flags but lists in its backing-test index without a caveat in one place.

---

## 1. Does every canonical rule have a real, passing, CI-gating test — or an honest "not yet tested"?

**Mostly yes, and the spec is unusually honest about the gaps.** Verified
file-by-file:

### Rules WITH real, passing, CI-gating, teeth-bearing tests
- **Regime A — fill-pane host publishes ≈ 0 (no collapse).** Backed by
  `AppKitSwiftUIBoundaryTests.testComposeAndDraftLandingFillPanesDoNotCollapse`
  and `.testArchiveBindingWriteStaysHeightNeutral`. I confirmed both **pass at
  HEAD** and **fail with the fix reverted** — measured exactly the values
  verify-results claims: compose child `fittingSize = 660.0`
  (`AppKitSwiftUIBoundaryTests.swift:561`) and archive child `276.5`
  (`AppKitSwiftUIBoundaryTests.swift:627`). These are genuine teeth. FACT.
- **Regime A — sizing regime governs published fitting size (A/B).**
  `testSizingRegimeGovernsPublishedFittingSize` (test-local hosts, default ⇒
  non-zero, `[]` ⇒ 0) — passes; correctly stayed green under the revert because
  it builds its own hosts. The label in the spec ("asserts the measurement
  dimension responds to the regime, not that a window collapses") is accurate.
  FACT.
- **Regime B — centered + width-capped (wide) and shrink-to-fit (narrow).**
  `HostedComponentCenteringTests` both legs pass. I dumped the attachment data:
  wide pane 1100 → host `(140, 0, 820, 100)`, midX 550 == pane midX 550 (capped,
  centered, 140pt inset each side — NOT edge-to-edge); narrow pane 680 → host
  `(0, 0, 680, 100)`, minX 0 (no overflow), height 100 (component). FACT.

### Rules HONESTLY marked "not yet tested" / "no production instance" — all verified accurate
- B′ toolbar-slot, B″ floating overlay, C window-content, D modal-sheet: spec
  says "not yet tested (by-design; no collapse failure mode)." I confirmed the
  cited reference files exist and use the claimed regime
  (`MainWindowController.swift:253,280` use `[.intrinsicContentSize]`;
  `SettingsWindowController`/`AboutWindowController`/`Transcript2SheetPresenter`
  exist and host via `NSHostingController`). The "no failure mode" rationale is
  sound — these regimes *want* content-driven sizing. FACT/INFERENCE-OK.
- E leaf-in-cell: "no production instance (transcript is Core-Text self-drawn)."
  Consistent with the architecture (NativeTranscript2). FACT.

### Rules asserted as proven that are NOT actually proven by a passing test → see Issue 2.1

No canonical *Do/Don't* rule is asserted as test-proven without backing **except**
the window-FRAME-collapse claim, which the spec itself correctly demotes (§2.4).
That demotion is the spec's strongest move and it is honest.

---

## 2. Is the archive-collapse test a gate with teeth, per verify-results?

**The window-FRAME collapse is NOT guarded offscreen, and the spec says so
clearly and repeatedly (§2.4, §6 row, Don't list).** Verified independently:

- I reverted all three production fixes and ran the suite.
  `testDefaultSizingOptionsHostCollapsesWindowInLargeSplit` **still passed** with
  the fix reverted — exactly as verify-results §"Regression teeth" states (it
  builds its own broken host inline, so it is regime-independent of production).
  The window-frame `adoptHeight < 700` assertion in that test
  (`AppKitSwiftUIBoundaryTests.swift:424`) fires on a content-adopting window
  that collapses to the `minSize` clamp **for both regimes**, so it is NOT a
  production-fix regression signal — it only proves a content-adopting window
  shrinks, which is regime-independent. The spec is candid that this test's teeth
  are on `published`, not on the frame.
- The **real** teeth are `testComposeAndDraftLandingFillPanesDoNotCollapse` and
  `testArchiveBindingWriteStaysHeightNeutral`, asserting on
  `currentChild.view.fittingSize.height ≈ 0`. Those DID fail under the revert
  (660.0 / 276.5). So the regression IS guarded — on the `fittingSize`
  dimension, which is the genuinely regime-discriminating, offscreen-stable
  signal. FACT.

**Conclusion:** the spec does **not** claim the window-frame collapse is guarded;
it claims the *regime* (the leak cause) is guarded via `fittingSize`, and that is
true. This is correct and well-disclosed. The "large window is the evidence"
framing (≥1100×760, gates use 1200×860 with minSize 540) is load-bearing for the
*live-app reasoning* and any future on-screen test, NOT for the offscreen frame
assertion — the spec states this (§2.4). No overclaim.

---

## 3. Any rule contradicting the real code or Apple's documented `sizingOptions`?

No contradictions found. Cross-checks:

- **Production code matches the spec's regime table.** Verified:
  `ArchiveViewController.swift:102` (`[]` + 4-edge pin lines 106-111, two-way
  `Binding` lines 63-66), `ComposeSessionViewController.swift:115` (`[]`, no
  boundary binding), `DraftSessionLandingViewController.swift:136` (`[]`),
  `ChatSessionViewController.swift:172` (`[.intrinsicContentSize]`) + the
  five-constraint centering recipe (lines 185-210: centerX, bottom==,
  width<=cap, leading>=, width==cap@high). The spec's claim "binding is not the
  cause" is *structurally* proven by code: two of the three fill-pane VCs that
  need the identical fix have **no** boundary-crossing binding. FACT.
- **`maxHostWidth = BlockStyle.maxLayoutWidth (780) + 2 * detailHorizontalInset
  (20) = 820`** — confirmed `detailHorizontalInset = 20`
  (`ChatSessionViewController.swift:62`) and the computation
  (`ChatSessionViewController.swift:185`). The centering test recomputes it from
  the same constants (`HostedComponentCenteringTests.swift:196-198`) rather than
  hardcoding — good. FACT.
- **Apple `sizingOptions` default.** The spec's claim that the default is the
  full set `[.minSize, .intrinsicContentSize, .maxSize]` for both
  `NSHostingController` and `NSHostingView` is sourced to WWDC22 + Webster
  (community reverse-engineering), labelled correctly as the basis for the
  `[]`-over-`[.minSize,.maxSize]` choice being INFERENCE (§2.3). The
  *behavioral* consequence the spec depends on — default publishes a non-zero
  fitting height, `[]` publishes 0 — is directly demonstrated by
  `testSizingRegimeGovernsPublishedFittingSize` and the revert run (276.5 vs 0).
  So even if the exact default-set enumeration is community-sourced rather than a
  hard Apple doc guarantee, the load-bearing behavior is empirically pinned by a
  passing test. No contradiction; the labeling is honest. FACT (behavior) /
  INFERENCE (exact default-set name).

---

## 4. Is the centering test's tolerance sane (not loose enough to pass off-center)?

**Yes, with one nuance worth recording.** `midX == pane.midX` uses
`accuracy: 1` — tight. Measured midX matched pane midX exactly (550/550,
340/340). The discriminating assertions differ per leg:

- **Wide leg:** the teeth are `frame.width == 820 (accuracy 1)` AND
  `midX == pane.midX`. Because width is capped at 820 < pane 1100, an off-center
  bar would shift midX away from 550 and fail. Both are meaningful. FACT.
- **Narrow leg:** here the host fills the full pane width (680 == pane 680), so
  `midX == pane.midX` is **trivially true** (a full-width view is always
  centered). The *real* teeth in the narrow leg are `minX >= -0.5` (no overflow
  past the leading edge) and `width <= pane.width + 1`. Those have teeth; the
  midX assertion is redundant-but-harmless there. This is a minor honesty gap:
  the narrow-leg `midX` assertion does not test centering, it rides along. Not a
  defect (the leg's intended invariant — shrink-to-fit without overflow — IS
  tested), but the spec's framing "still centered" for the narrow leg overstates
  what that specific assertion proves. INFERENCE.
- **Component-height bound:** `height < 250` AND `height < 0.5 * pane`. Measured
  height = 100. A pane-filling bar (~800) fails loudly. The `< 250` concrete
  bound (tied to the bar's real intrinsic height + the 100pt bottom scrim) is the
  stronger of the two and is sane. FACT.

The "narrow window must be pinned with REQUIRED width/height constraints or the
borderless window adopts the bar's 820 intrinsic width" caveat
(`HostedComponentCenteringTests.swift:146-166`) is real and load-bearing — I
confirmed the narrow leg genuinely runs at pane 680 (attachment: `pane bounds =
(0,0,680,800)`), so the shrink-to-fit branch is actually exercised, not vacuous.
FACT.

---

## Issues found (ranked)

### Issue A (medium) — `specMatchesTests` is TRUE only because the spec demotes the one unbacked rule; the §6 index row for the legacy gate could mislead a skim-reader
The §6 backing-test index row for
`DetailRouterLayoutDiagnosticsTests.testArchiveSelectionDoesNotFlattenWindow`
labels it "legacy gate; window-height assertion toothless offscreen — harden to
assert fitting size." That parenthetical is correct, but it is still listed as the
backing test for "Archive selection does not flatten window." A reader who trusts
the index column without reading the parenthetical would believe the archive-flatten
regression is gated by *that* test. It is not — it is gated by the two new
`fittingSize`-based tests. I independently reproduced this: with the fix reverted,
`testArchiveSelectionDoesNotFlattenWindow` is not in the failing set (only the two
new tests failed). **Recommendation:** either (a) implement the spec's own tracked
recommendation now (harden that test to assert
`currentChild.view.fittingSize.height ≈ 0`, which it already records at
`DetailRouterLayoutDiagnosticsTests.swift:150`), or (b) move it out of the
"backing test" column into a "diagnostic, non-gating" note. The recommendation is
already written in §2.4 and §6; it just hasn't been actioned, so the index slightly
oversells. This is the spec describing a real, currently-toothless gate as a
backing test.

### Issue B (low) — narrow-leg `midX` assertion does not actually test centering
`HostedComponentCenteringTests.testRestingBarShrinksToFitAndCentersInNarrowPane`
asserts `midX == pane.midX`, but at pane 680 the host is 680 wide (full pane), so
this is trivially satisfied and proves nothing about centering. The spec §3 and
the test name both say "centers in a narrow pane"; the assertion that *would* test
that (an off-center shrunk bar) cannot occur given the constraint set
(`leading >=` + `centerX ==` force symmetric shrink). Not a correctness bug — the
invariant the narrow leg cares about (no overflow) IS tested by `minX >= -0.5`. But
the "still centered" claim is over-attributed to an assertion that can't fail.
**Recommendation:** reword the narrow-leg comment/spec to say the leg proves
"shrink-to-fit without overflow"; centering-under-cap is proven by the WIDE leg.

### Issue C (low) — §2.2 mixes "~176pt" (spec) with "276.5" (tests/comment) without reconciling in one place
Spec §2.2 line 83 says the archive fitting height is "~176pt before the async list
lands," while the production comment (`ArchiveViewController.swift:92-97`) and every
test measure ≈ 276. These are two different moments (live pre-list header-only vs.
the offscreen measured value with the test/real body), and the production comment
itself records BOTH ("~176pt before the async list lands" and "≈ 545×276"). Not a
contradiction, but a reader could think the numbers disagree. **Recommendation:**
add one clause in §2.2 noting 176 is the live pre-list header and 276 is the
offscreen measured leak the gates assert on.

### Non-issue (verified, calling out so it isn't re-flagged)
- The `composeOrBarHost` access widening (private → internal,
  `ChatSessionViewController.swift:94`) is a legitimate access-modifier-only test
  seam, explicitly allowed by both CLAUDE.md and the spec's production-code rules.
  No behavior change. FACT.
- All three test files obey parallel-safety: in-memory repo, unique
  `UserDefaults(suiteName:)` + teardown, temp dirs under `temporaryDirectory/UUID`
  + teardown, no `.shared`, no `NotificationCenter.default`, no `sleep`-for-sync
  (the `settle()` pump is a fixed-iteration runloop drain, the established
  `DetailRouterLayoutDiagnosticsTests` idiom). FACT.
- Filename ↔ class name matches for all three; only the `*SnapshotTests` file is
  CI-skipped (verified against `scripts/test-unit.sh:82-83`). FACT.

---

## Bottom line
The spec is **sound-with-fixes**. Its central, surprising claim — "the two-way
binding is not the collapse cause; the `sizingOptions` regime is, and the
offscreen-discriminating signal is `fittingSize` not window height" — is correct,
honestly disclosed, and **independently reproduced** by me (revert → 276.5/660.0
failures on the `fittingSize` gates; window-frame gates regime-independent). Every
canonical rule either has a teeth-bearing CI gate or an honest "not yet tested /
no production instance" note. The three issues are wording/honesty refinements,
not falsifications. The one item that keeps `specMatchesTests` from being a clean
yes is the legacy `testArchiveSelectionDoesNotFlattenWindow` row in §6, which the
spec itself flags as toothless-offscreen but still lists as a backing test — fix by
actioning the spec's own tracked hardening recommendation.

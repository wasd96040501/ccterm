# Verify task results — AppKit↔SwiftUI boundary tests

Status: **GREEN**. All three new test files compile, run, and pass; the two
CI-gate classes execute on the default suite, the snapshot class is auto-skipped.
Regression teeth confirmed. `make fmt-check` passes. Full default suite passes
(557 cases).

## Pass/fail per class (production code at HEAD, fixes intact)

| Class | Kind | Result |
|---|---|---|
| `AppKitSwiftUIBoundaryTests` | CI gate | PASS — 4/4 cases |
| `HostedComponentCenteringTests` | CI gate | PASS — 2/2 cases |
| `AppKitSwiftUIBoundarySnapshotTests` | opt-in snapshot | PASS — 2/2 (renders PNGs) |

Default-suite run: `make test-unit` → `✓ UNIT TESTS PASSED (26s, 557 test cases)`.
Both gate classes appear in the run; the snapshot class is skipped via
`-skip-testing:cctermTests/AppKitSwiftUIBoundarySnapshotTests` (correct).

`make fmt-check` → passes (the linter reformatted the new files via `make fmt`).

Snapshot PNGs written:
- `/tmp/ccterm-screenshots/ArchiveBoundary-LargeWindow.png` (2400×1720 = 1200×860 @2x — window NOT collapsed)
- `/tmp/ccterm-screenshots/InputBar-Centered.png` (2200×1600 = 1100×800 @2x)

## What had to be repaired (and why)

### 1. The regime-A "teeth" test did not reproduce a collapse offscreen

As written, `testDefaultSizingOptionsHostCollapsesWindowInLargeSplit` asserted a
default-`sizingOptions` host **collapses the window height** to < 700 in a large
split. It measured **892** (no collapse) — i.e. it proved nothing.

Investigation (four diagnostic variations, since deleted) established the TRUE
offscreen mechanism:

- A default-options host nested in a plain detail VC, 4-edge pinned (the EXACT
  production `ArchiveViewController` containment, `ArchiveViewController.swift:83-113`)
  publishes `view.fittingSize ≈ (528, 276.5)` — the documented leak — but the
  **window frame does not shrink** when the window already has an explicit size.
- Window-frame collapse is observable offscreen ONLY when the window *adopts*
  its content size (`contentViewController` set, NO `setContentSize`). In that
  case the window collapses to its `minSize` clamp (540) **for BOTH regimes**
  (default and `[]`), because the SwiftUI `ScrollView` body supplies no height
  for either to fill. So the window-frame dimension is **NOT
  regime-discriminating offscreen**.
- An explicit `setContentSize(860)` makes the frame **sticky** at ~892 for both
  regimes; a later swap to a leaking host does not pull it down.

Decisive control: I temporarily reverted the production fix in
`ArchiveViewController.swift` (default options) and ran the EXISTING production
gate `DetailRouterLayoutDiagnosticsTests.testArchiveSelectionDoesNotFlattenWindow`
— it **still passed** (window stayed 892, archive child `fittingSize=(528,276.5)`).
That gate is itself **toothless on the window-height dimension offscreen**.

**The true mechanism (file:line):** the leak is the host's published
intrinsic/preferred size (`NSHostingController` default `sizingOptions` includes
`.preferredContentSize`/`.intrinsicContentSize`). `ArchiveViewController.swift:84-101`
documents the live-app path: that small fitting height bubbles up through the
detail VC → split `view.fittingSize` → the window solver
(`_changeWindowFrameFromConstraintsIfNecessary`) and resizes the window. The
live-app collapse is real (autosize/autosave + the constraint solver), but the
offscreen XCTest window does not run that pass, so the **window frame is not a
reproducible signal** in this harness. The regime IS discriminated, offscreen,
by the **published size** (`fittingSize`/`preferredContentSize`): default ⇒
≈ 276, `[]` ⇒ 0.

**Repair:** rewrote the teeth test as an A/B over the production containment
shape that asserts on the **published** dimension (broken > 50, fixed ≤ 1,
gap > 50), and additionally samples both window-frame paths (adopt + sticky)
into the attached report, with an in-test note that the frame is not the
discriminator offscreen. No production code changed. Measured A/B:

```
BROKEN (default sizingOptions): published leak height = 68.5; adopt=540; sticky=892
FIXED  (sizingOptions = []):    published leak height = 0.0;  adopt=540; sticky=892
```

(68.5 here is the test-local stand-in body; the real `ArchiveView` publishes the
documented 276.5 — see the teeth-revert run below.)

### 2. The "two-way binding" question — true mechanism

The user blamed `model.archiveSelectedFolderPath <-> ArchiveView` for the squash.
`testArchiveBindingWriteStaysHeightNeutral` proves the binding is **not** the
cause: under the fixed `[]` regime, a binding write
(`ArchiveViewController.swift:63-66` is the two-way `Binding`) forces an
`ArchiveView` body re-eval but the child still publishes `fittingSize ≈ 0`, so
nothing reaches the solver. The **sizing regime** is the root cause; under a
leaking (default) regime the binding would merely be the "pump" that re-trips it.
Confirmed by the teeth-revert: with default options the archive child publishes
`fittingSize=276.5` and this gate fails.

### 3. The centering NARROW leg was not exercising shrink-to-fit

`HostedComponentCenteringTests` narrow leg requested a 680pt pane but the
borderless test window **adopted the bar's intrinsic width (820)** and grew to
820 — so the pane was 820, never < the 820 cap, and the shrink-to-fit /
`leading >=` branch was never tested (it tested at exactly the cap, vacuously).
`window.minSize/maxSize` alone did not hold a borderless offscreen window.

**Repair:** pin the container to an explicit size with REQUIRED width/height
constraints (a self-sized stand-in for the split detail item, whose width the
split — not the content — governs). After the fix the narrow leg genuinely
shrinks: pane=680, host frame width=**680** (< 820 cap), midX=340=pane midX
(centered), minX=0 (no overflow). Wide leg: width=820 (capped), midX=550
(centered). Both legs: host height=100 (component, not pane-filling).

## Regression teeth — CONFIRMED (the negative case)

Reverted all three production fixes (`ArchiveViewController.swift:102`,
`ComposeSessionViewController.swift:115`, `DraftSessionLandingViewController.swift:136`
— removed `host.sizingOptions = []`, i.e. default/broken regime) and re-ran
`AppKitSwiftUIBoundaryTests`:

- `testComposeAndDraftLandingFillPanesDoNotCollapse` → **FAILED** (caught it):
  `Compose fill-pane child should publish ≈ 0 fittingSize ... got 660.0`.
- `testArchiveBindingWriteStaysHeightNeutral` → **FAILED** (caught it):
  `Archive child should still publish ≈ 0 fittingSize ... got 276.5`
  (the exact documented leak).
- `testDefaultSizingOptionsHostCollapsesWindowInLargeSplit` → still passed
  (regime-independent of production; builds its own broken host inline).

So the no-collapse gates DO fail when the fix is removed — the teeth are on the
`fittingSize ≈ 0` dimension, which is the genuinely regime-discriminating signal.
Production fixes restored (`git checkout`); all gates green again.

The centering tests also have natural teeth: a non-centered or pane-filling bar
fails the `midX == pane midX` and `height < 250 / < 0.5*pane` assertions.

## Key finding for the parent (taxonomy)

The headline reproduction premise — "a default-`sizingOptions` host collapses the
window offscreen, and a small window can't detect it" — is **only half right**.
The window FRAME does not collapse offscreen (the live constraint-solver pass
doesn't run in a headless window; an explicit content size is sticky; content
adoption collapses both regimes to minSize). The **published intrinsic/preferred
size** is the regime-discriminating, offscreen-stable proxy for the leak — and it
is what the gates (new and the toothed parts) must assert on. The existing
production gate `testArchiveSelectionDoesNotFlattenWindow` is toothless on its
window-height assertion offscreen; consider hardening it to assert
`currentChild.view.fittingSize.height ≈ 0` (it already records that value in its
report but does not assert on it).

## Production-code rule compliance

No production behavior changed. Only `git checkout` round-trip on the three VCs
during the teeth check (restored). The tests use the allowed seams only
(public `present(sessionId:)`, internal `composeOrBarHost` / `currentChild` /
`detailHorizontalInset` / `archiveSelectedFolderPath`, all already
`internal`/`var` at HEAD — no widening needed).

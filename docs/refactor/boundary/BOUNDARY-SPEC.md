# The AppKit↔SwiftUI boundary spec

Authoritative, durable conventions for hosting SwiftUI inside AppKit in CCTerm
(macOS 14+; SwiftUI by default, AppKit by documented exception). This folds the
boundary research, plan, review, and verification into one reference meant to be
merged into the project conventions and the refactor plan.

Legend: **FACT** = read directly in source/docs/Apple references. **INFERENCE** =
judgment derived from those facts. All `file:line` are against this worktree.

Companion conventions already in the tree (read these too):
- root `CLAUDE.md` § "Embedding SwiftUI in AppKit: host sizing" and § "macOS runloop tick model"
- `macos/ccterm/Content/Chat/CLAUDE.md` (per-VC host-sizing notes)
- `macos/cctermTests/CLAUDE.md` (test conventions — the gates below obey it)

---

## 0. The one rule everything else follows

> **Decide who owns the size.** Either the AppKit container drives the host's
> size (fill-a-pane) or the SwiftUI content drives it (component / window).
> The `sizingOptions` value and the constraint pattern follow mechanically from
> that single decision. Picking wrong is what collapses the window.

The default `sizingOptions` for **both** `NSHostingController` and
`NSHostingView` is the full set `[.minSize, .intrinsicContentSize, .maxSize]`
(FACT — WWDC22 "Use SwiftUI with AppKit"; Brian Webster's reverse-engineering of
the probe behavior). With the default set the host publishes the SwiftUI body's
fitting size as Auto Layout intrinsic/preferred size. That is correct when the
content should drive the size, and catastrophic when the container should.

### 0.1 The hit-test invariant (passthrough is geometry, not transparency)

> **A plain `NSHostingView` returns `self` for any point inside its bounds that
> no SwiftUI subview claims; `.allowsHitTesting(false)` does NOT turn a
> transparent region into a "click-through" region.** Whether a click reaches a
> sibling view is decided **only** by host-frame geometry: a host that should
> not occlude a sibling must keep its own frame off that sibling. (FACT —
> measured with a real `hitTest` probe against a sentinel transcript;
> `DetailPaneTranscriptHitTestTests`.)

The corollary is the rule the bottom-cluster merge follows: do **not** reach for
a `hitTest`-override "passthrough host" to let clicks fall through a transparent
overlay. Make the host's frame not cover what it shouldn't — a full-width,
**bottom-anchored, content-height** host (regime B) leaves the transcript band
above it uncovered, so the transcript receives its clicks by geometry, with no
override. The deleted `PassthroughHostingView` was a patch on the *wrong* shape
(a full-pane card host that, being full-pane, swallowed in-bounds points); the
fix was to delete the full-pane host, not the passthrough.

---

## 1. The decision table (one screen)

Every one of the 16 hosting sites in CCTerm falls into exactly one of these
buckets (FACT — `nodes/research-census.md` §1). "Backing test" names the real
class/method that guards the rule, or "not yet tested."

| Situation | Host kind | `sizingOptions` | Constraint pattern | Two-way binding rule | Canonical rule | Backing test |
|---|---|---|---|---|---|---|
| **A. Fill-a-pane** — host *is* the detail pane's content | `NSHostingController` | `[]` | pin **all 4 edges** to container | Binding/`@Bindable` OK; **not** the collapse cause; under `[]` it is height-neutral | Container drives size; host publishes none. `[]` + 4-edge pin. | `AppKitSwiftUIBoundaryTests.testComposeAndDraftLandingFillPanesDoNotCollapse`, `.testArchiveBindingWriteStaysHeightNeutral`, `.testSizingRegimeGovernsPublishedFittingSize`, `.testDefaultSizingOptionsHostCollapsesWindowInLargeSplit`; `DetailRouterLayoutDiagnosticsTests.testArchiveSelectionDoesNotFlattenWindow` |
| **B. Centered, width-capped, bottom-anchored component** — input bar over a transcript (the bar's centering + cap; when co-hosted with a full-width fade the host is full-width and the cap moves into SwiftUI — see §3 preface) | `NSHostingView` | `[.intrinsicContentSize]` | `centerX` + `width≤cap`(req) + `width==cap`(@high) + `leading≥`inset + `bottom==`edge  ·OR·  full-width (`leading==`/`trailing==`) + `bottom==`edge | read-mostly `@Bindable` OK; intrinsic height ⇒ no split leak even on write | Content drives the cross-axis (height); AppKit drives the main axis (width). | `HostedComponentCenteringTests.testBottomClusterIsFullWidthAndBottomAnchoredInWidePane`, `.testBottomClusterIsFullWidthAndBottomAnchoredInNarrowPane`, `.testPermissionCardGrowsHostUpwardWithoutMovingBarAnchor` |
| **B′. Toolbar-slot component** | `NSHostingView` | `[.intrinsicContentSize]` | none — `NSToolbar` auto-measures via intrinsic size | `@Bindable` OK (one writes `archiveSelectedFolderPath`) | Let intrinsic size feed the toolbar; pin nothing. | not yet tested (by-design; no collapse failure mode) |
| **B″. Floating / positioned overlay** (corner / bottom-center; DEBUG demos) | `NSHostingView` | default (benign) | position-only (centerX+bottom / trailing+bottom / centerX+centerY) — **never 4-edge** | `@Bindable` OK | Position it; never pin 4 edges, so its fitting size can't escape into a split. | not yet tested (DEBUG-only; no failure mode) |
| **C. Window-content host** (`NSWindow.contentViewController`) | `NSHostingController` | **default** (intended) | `NSWindow(contentViewController:)`; optionally `.preferredContentSize` | usually none | Keep the default; you *want* the window to snap to the content. | not yet tested (collapse-to-content is the goal) |
| **D. Modal-sheet host** (`beginSheet`) | `NSHostingController` | **default** (intended) | `NSWindow(contentViewController:)` → `window.beginSheet(...)` | value + Done callback | Same as C; the sheet sizes to its content. | not yet tested (by-design) |
| **E. Leaf SwiftUI in an AppKit cell/row** | `NSHostingView` (in cell) | `[.intrinsicContentSize]` | pin to cell insets; intrinsic size feeds `heightOfRow`/cell sizing | value-in, callbacks-out; avoid hot two-way binding in a recycled cell | Intrinsic size feeds the cell height; never let a recycled host fight the table's tile. | **no production instance** (transcript is Core-Text self-drawn — taxonomy-completeness node) |

Distinguishing question (root `CLAUDE.md`): **does the host fill its container
(→ `[]`, container drives size), sit inside it as a component
(→ `[.intrinsicContentSize]`, content drives size), or is it itself a window's
content (→ default, content drives the window)?**

Reference implementations:
- A — `ArchiveViewController.swift:102-111`; same regime at
  `ComposeSessionViewController.swift:115`,
  `DraftSessionLandingViewController.swift:136`,
  `DetailRouterViewController.swift:443` (DEBUG),
  `PermissionSessionDemoViewController.swift:134` (DEBUG).
- B — `ChatSessionViewController.swift` (`bottomClusterHost` in `loadView()`).
- B′ — `MainWindowController.swift:253,280`.
- B″ — `TranscriptDemoViewController.swift:113-117` and the other DEBUG demos.
- C — `SettingsWindowController.swift:15`, `AboutWindowController.swift:23`.
- D — `Transcript2SheetPresenter.swift:192`.

---

## 2. The archive window-collapse — true mechanism, fix, and guard

### 2.1 The symptom (PR #224)

Selecting the Archive tab flattens the main window's height, and switching back
to chat does not restore it. The user phrased it as "two-way binding caused the
window to be squashed." (FACT — `DetailRouterLayoutDiagnosticsTests.swift:8-17`.)

### 2.2 The TRUE mechanism — it is the `sizingOptions` regime, not the binding

`ArchiveView`'s root is a `ScrollView`, whose fitting height is just the header
(~176pt live before the async list lands; the offscreen measured leak the gates
assert on is ≈ 276 — two different moments of the same header-only content, see
the production comment at `ArchiveViewController.swift:92-97`). With
`NSHostingController`'s **default**
`sizingOptions`, the host publishes that small fitting height as its intrinsic /
preferred size. Because the archive host is a **fill-the-pane detail child**,
that small height bubbles up: detail VC → `NSSplitViewController.view.fittingSize`
→ the window constraint solver (`_changeWindowFrameFromConstraintsIfNecessary`),
which resizes the window content down to it. Switching back to chat does not
restore it because chat contributes no fitting height to grow the window again.
(FACT — `ArchiveViewController.swift:84-101`; the comment records the measured
leak `host.view.fittingSize ≈ 545×276`, and `0×0` once cleared.)

**The two-way binding is not the cause.** Three other fill-pane children with
**no** boundary-crossing binding need the identical fix
(`ComposeSessionViewController.swift:115`,
`DraftSessionLandingViewController.swift:136`,
`DetailRouterViewController.swift:443`). The collapse reproduces on first mount,
before any binding write. (FACT — those three `[]` sites + the comment.)

**What the binding actually does (the user's mental model, explained).** The
folder filter is a genuine two-way `Binding<String?>` between
`model.archiveSelectedFolderPath` (AppKit-owned, on `MainSelectionModel`) and
`ArchiveView` (FACT — `ArchiveViewController.swift:63-66`). The *same* field is
also written by the AppKit toolbar's folder-filter button
(`MainWindowController.swift:321`). Under the **default** (leaking) regime, every
binding write re-evaluates `ArchiveView.body` in the next `beforeWaiting` flush,
which re-queries the content's ideal size and **republishes** the small fitting
size — so each filter change re-trips the collapse and can defeat a manual resize
the user just performed. The binding is the *pump*; the regime is the *cause*.
(INFERENCE, grounded in the runloop tick model + the toolbar write site.)

### 2.3 The fix

```swift
host.sizingOptions = []                                       // sever the fitting-size leak
host.view.translatesAutoresizingMaskIntoConstraints = false
NSLayoutConstraint.activate([
    host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
    host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    host.view.topAnchor.constraint(equalTo: view.topAnchor),
    host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
])
```

`[]` (not `[.minSize, .maxSize]`) because a pure fill-the-pane host wants zero
auto-constraints — the 4-edge pin is the complete size story, and any residual
`.minSize`/`.maxSize` is extra probing cost and a latent leak. (FACT —
`ArchiveViewController.swift:102-111`; INFERENCE on the `[]`-over-`[.minSize,.maxSize]`
choice, grounded in Webster.)

### 2.4 The guard — and the critical offscreen caveat

**The window FRAME does not collapse in a headless XCTest window.** Verification
established this (FACT — `nodes/verify-results.md`): the live-app collapse runs
through the window's constraint-solver / autosize pass, which a borderless
offscreen window does not run. An explicit `setContentSize` is sticky for *both*
regimes; content-size adoption collapses *both* regimes to the `minSize` clamp.
So **window height is not regime-discriminating offscreen** — and the legacy
`DetailRouterLayoutDiagnosticsTests.testArchiveSelectionDoesNotFlattenWindow`
height assertion is therefore *toothless offscreen* (it passed even with the
production fix reverted).

**The regime IS discriminated, offscreen and stably, by the published
`fittingSize`:** default ⇒ ≈ 276 (the documented leak), `[]` ⇒ 0. That is the
dimension the gates assert on:

- `AppKitSwiftUIBoundaryTests.testComposeAndDraftLandingFillPanesDoNotCollapse` —
  each production fill-pane child must publish `fittingSize.height ≈ 0`. Reverting
  the fix makes it fail (measured 660 for compose). (FACT — verify-results §3.)
- `AppKitSwiftUIBoundaryTests.testArchiveBindingWriteStaysHeightNeutral` — after a
  binding write forces a body re-eval, the archive child still publishes
  `fittingSize ≈ 0`. Reverting the fix makes it fail (measured 276.5 — the exact
  documented leak). This is the test that *disproves* the "binding squashed it"
  theory. (FACT — verify-results §2.)
- `AppKitSwiftUIBoundaryTests.testSizingRegimeGovernsPublishedFittingSize` — A/B
  over the production containment shape: default-options host publishes a non-zero
  height, `[]` host publishes ≈ 0, gap > 50. Built with **test-local** throwaway
  hosts, never by mutating a production VC's `sizingOptions`.
- `AppKitSwiftUIBoundaryTests.testDefaultSizingOptionsHostCollapsesWindowInLargeSplit` —
  exercises the full split chain in a large (1200×860) window; records both
  window-frame paths into the attachment and documents in-test that the frame is
  *not* the offscreen discriminator.

**Required-window-size rule (still load-bearing for the live-app reasoning and
for any future on-screen test).** A regression probe for regime A must mount in a
**large** window (≥ ~1100×760; the gates use **1200×860** with `minSize` height
540 strictly below the healthy height) so a collapse to ~276 is unambiguous and
the `minSize` clamp can't mask a partial collapse. A small/flat window (~600×300)
cannot detect it — collapsed ≈ starting height. Call the window size out in the
test as evidence. (FACT — gate window setup; INFERENCE on detectability.)

> Recommendation (DONE): hardened
> `DetailRouterLayoutDiagnosticsTests.testArchiveSelectionDoesNotFlattenWindow`
> to *assert* `currentChild.view.fittingSize.height <= 1` (it already recorded
> that value but only asserted on the offscreen-toothless window height). The
> legacy gate now has teeth on the regime-discriminating dimension. Verified:
> passes at HEAD; the assertion fires when the production `sizingOptions = []`
> fix is reverted (the child then publishes ≈ 276).

---

## 3. Input-bar centering — best practice, and is the current code optimal?

> **Post bottom-cluster merge (BOTTOM-CLUSTER-MERGE.md):** the chat bottom band
> is now a single `bottomClusterHost` (`NSHostingView<ChatBottomClusterRoot>`)
> that holds the fade + input bar + permission card in one SwiftUI tree. Because
> the fade is full-width, the **host** is now full-width + bottom-anchored
> (`leading == view.leading`, `trailing == view.trailing`, `bottom ==
> view.bottom`, `[.intrinsicContentSize]` height) — still regime B (the content
> drives height; the container drives width). The centering + width cap below
> did not disappear; it **moved one layer down** into the SwiftUI tree
> (`ChatRestingBar` caps at `composeMaxWidth` and centers via `.frame(maxWidth:
> .infinity)`; the card caps at `BlockStyle.maxLayoutWidth`). So §3's recipe is
> the historical *host-level* form of the same rule, and remains the reference
> for any future centered-and-capped **host** (e.g. a bar that is NOT
> co-hosted with a full-width fade). The `HostedComponentCenteringTests` gate now
> asserts the host is full-width + bottom-anchored + content-height, plus a
> card-present leg (card grows the host upward without moving the bar's bottom
> anchor).

The chat resting bar is the textbook regime-B component: it sits over a
transcript that already fills the pane, so the *content* drives its height while
*AppKit* owns its horizontal placement (and, when the host isn't full-width, its
width cap). (FACT — `ChatSessionViewController.swift`; `Content/Chat/CLAUDE.md`.)

```swift
composeOrBarHost.sizingOptions = [.intrinsicContentSize]              // HEIGHT from content
let maxHostWidth = BlockStyle.maxLayoutWidth + 2 * Self.detailHorizontalInset  // 780 + 40 = 820
let widthFill = composeOrBarHost.widthAnchor.constraint(equalToConstant: maxHostWidth)
widthFill.priority = .defaultHigh
NSLayoutConstraint.activate([
    composeOrBarHost.centerXAnchor.constraint(equalTo: view.centerXAnchor),                  // center
    composeOrBarHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),                    // bottom-anchor
    composeOrBarHost.widthAnchor.constraint(lessThanOrEqualToConstant: maxHostWidth),        // hard cap (required)
    composeOrBarHost.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),     // shrink-to-fit
    widthFill,                                                                                // fill up to cap (@high)
])
```

Why each piece (FACT — `ChatSessionViewController.swift:163-208`):
- `centerX == container.centerX` — horizontal centering.
- `width ≤ cap` **required** — never exceed the widest hosted content (a
  permission card + padding); the cap is the *card* width, not the pill width
  (`composeMaxWidth = 512`), so a card is never clipped and the narrower pill
  self-centers inside.
- `width == cap` at **`.defaultHigh`** — fills to the cap on a wide pane but
  *yields* to `leading ≥` on a pane narrower than the cap, so the bar shrinks
  instead of overflowing.
- `leading ≥ container.leading` — the shrink-to-fit safety stop.
- `bottom == container.bottom` + `.intrinsicContentSize` height — the bar is
  exactly as tall as its content and grows upward for multi-line input /
  permission cards. Keeping the host's bounds tight (height from intrinsic size)
  is also what lets the transcript table below receive clicks everywhere above
  the bar — a plain `NSHostingView` claims every point in its bounds for
  hit-testing.

**Is it optimal? Yes — this is the canonical pattern.** (INFERENCE, grounded in
`nodes/research-web.md` §5, `nodes/research-painpoints.md` §2.5.)
1. `.intrinsicContentSize` is *right* here (unlike regime A): the component does
   not govern its container's size — the transcript does — so publishing the
   height carries no window-collapse risk.
2. The five-constraint recipe is the idiomatic Auto Layout expression of
   "centered, capped, shrink-to-fit" — more robust than hardcoded leading/trailing
   insets, which cannot both center *and* cap.
3. It avoids the explicitly-discarded anti-pattern: do **not** hand-roll the
   height with `GeometryReader` + `PreferenceKey` + a manual height constraint.
   `.intrinsicContentSize` does that for free. The DEBUG
   `PermissionSessionDemoViewController` input-bar host is the *legacy*
   hand-rolled shape (`sizingOptions = []` + a `PreferenceKey` height) and must
   **not** be copied; `ChatSessionViewController` is the exemplar.

Guard: `HostedComponentCenteringTests` verifies the merged `bottomClusterHost`
offscreen at two widths plus a card-present leg:
- `testBottomClusterIsFullWidthAndBottomAnchoredInWidePane` — pane 1100: host
  is full-width (== pane), bottom-anchored, height small (component, not
  pane-filling).
- `testBottomClusterIsFullWidthAndBottomAnchoredInNarrowPane` — pane 680 (the
  split detail minimum): host full-width (== pane), no leading-edge overflow,
  bottom-anchored, height small.
- `testPermissionCardGrowsHostUpwardWithoutMovingBarAnchor` — seed a pending
  permission: the host grows TALLER (card composites above the bar) but stays
  bounded (never near pane height), and the host's bottom edge — where the bar
  sits — does NOT move (the card grows upward; the bar's `frame.minY` is
  invariant). This is the PR#235→#281 "card pumps / lifts the bar" regression
  guard.

  Note: the legs pin the container to an explicit size with *required*
  width/height constraints — a borderless offscreen window otherwise adopts the
  content's fitting width. (FACT — verify-results §3.)

  Historical note: pre-merge the host itself was centered + width-capped (its
  WIDE leg proved centering-under-cap at width == 820 < pane). Post-merge the
  host is full-width and that centering moved into the SwiftUI tree (§3
  preface), so the host-frame asserts are full-width; the bar's centering is
  now a content concern, reviewed in the opt-in `InputBar-Centered` snapshot.

---

## 4. Two-way `Binding` / `@Bindable` across the boundary — guidance

(FACT for mechanism — `nodes/research-web.md` §3,9, `nodes/research-painpoints.md`
§1.6, root `CLAUDE.md` runloop model; INFERENCE for synthesis.)

1. **Allowed and idiomatic.** A `Binding(get:set:)` (or `@Bindable`) reading and
   writing an AppKit-owned `@Observable` is the standard single-source-of-truth
   pattern across the boundary (`ArchiveViewController.swift:63-66`). Use
   `[weak self]` in both closures so the SwiftUI tree never retains the VC.
2. **The binding never causes a window collapse on its own.** Collapse is a
   *sizing-regime* bug (regime A with default options). Under a leaking regime the
   binding is only the *pump* that republishes the bad fitting size on each
   update; under `[]` it is height-neutral. → See §2.2.
3. **Update timing is async to the writer.** An AppKit-side write to the model
   does **not** reach the SwiftUI body in the same runloop tick — bodies
   re-evaluate in `beforeWaiting`. Do not read the model from a SwiftUI view
   immediately after an AppKit write expecting the new value.
4. **No infinite ping-pong from a well-formed binding.** A `Binding` whose `set`
   writes the same `@Observable` its `get` reads does not oscillate — SwiftUI
   coalesces and only re-evaluates on actual value change. The danger was *layout
   republish* (point 2), not value ping-pong.
5. **Read-mostly `@Bindable` (e.g. `ChatComposeStack`'s `model`) is the lightest
   crossing** — no hot two-way write loop, and the host is regime B (intrinsic
   height) so there is no split leak even if it did write.

When the SwiftUI `.toolbar { }` modifier is silently dropped inside an
AppKit-rooted host, move the control to the `NSToolbar` and share state through a
two-way binding on the model — that is precisely why
`model.archiveSelectedFolderPath` is two-way (FACT —
`MainSelectionModel.swift:93-99`, `ArchiveView.swift:48-54`).

---

## 5. Do / Don't

**Do**
- Decide size ownership first; let `sizingOptions` + constraints follow (§0).
- Fill-a-pane host → `sizingOptions = []` + pin all 4 edges (regime A).
- Component over other content → `[.intrinsicContentSize]` + position-only
  constraints (regime B/B′/B″).
- Center + cap a component with `centerX` + `width≤cap`(req) + `width==cap`(@high)
  + `leading≥`inset (§3).
- Window/sheet content → keep the default `sizingOptions` (regime C/D).
- Use `NSHostingController` for panes/sheets/window content (lifecycle +
  appearance forwarding); `NSHostingView` for in-place subviews (tighter
  hit-testing, no VC overhead).
- Use `[weak self]` in both closures of an AppKit-built `Binding`.
- Test regime-A no-collapse by asserting `view.fittingSize.height ≈ 0` (the
  offscreen-stable signal), in a large (≥1100×760) window.

**Don't**
- Don't leave default `sizingOptions` on a fill-a-pane host — it leaks
  `fittingSize` up the split and collapses the window.
- Don't blame a two-way binding for a collapse — fix the sizing regime (§2.2).
- Don't hand-roll a component's height with `GeometryReader` + `PreferenceKey` +
  a manual height constraint — `.intrinsicContentSize` does it for free.
- Don't pin all 4 edges of a floating/positioned overlay (B″) — that would let
  its fitting size govern the container.
- Don't assert a regime-A collapse via *window height offscreen* — it is not
  regime-discriminating in a headless window (§2.4).
- Don't test in a small/flat window — it cannot distinguish filled from collapsed.
- Don't mutate a production VC's `sizingOptions` to exhibit the bad regime in a
  test — build a test-local throwaway host instead.
- Don't add a `hitTest`-override "passthrough host" to fake click-through
  through a transparent overlay — passthrough is geometry, not transparency
  (§0.1). Keep the host's frame off the sibling it shouldn't occlude.
- Don't expose mutable internals / add `forceXxxForTest()` / `#if DEBUG` UI
  variants. Access-modifier-only widening is the most a test may ask of
  production code.

---

## 6. Backing-test index (per canonical rule)

| Canonical rule | Backing test | File |
|---|---|---|
| Fill-pane host publishes ≈ 0 fitting size (no collapse) | `AppKitSwiftUIBoundaryTests.testComposeAndDraftLandingFillPanesDoNotCollapse` | `cctermTests/AppKitSwiftUIBoundaryTests.swift` |
| Two-way binding write under `[]` stays height-neutral (binding is not the cause) | `AppKitSwiftUIBoundaryTests.testArchiveBindingWriteStaysHeightNeutral` | same |
| Sizing regime governs published fitting size (A/B teeth: default ⇒ leak, `[]` ⇒ 0) | `AppKitSwiftUIBoundaryTests.testSizingRegimeGovernsPublishedFittingSize` | same |
| Full-split large-window probe + frame-path documentation | `AppKitSwiftUIBoundaryTests.testDefaultSizingOptionsHostCollapsesWindowInLargeSplit` | same |
| Archive selection does not flatten window (legacy gate, **now hardened** to assert `currentChild.view.fittingSize.height <= 1` — the window-height assertion alone is toothless offscreen) | `DetailRouterLayoutDiagnosticsTests.testArchiveSelectionDoesNotFlattenWindow` | `cctermTests/DetailRouterLayoutDiagnosticsTests.swift` |
| Bottom cluster is full-width + bottom-anchored in a wide pane | `HostedComponentCenteringTests.testBottomClusterIsFullWidthAndBottomAnchoredInWidePane` | `cctermTests/HostedComponentCenteringTests.swift` |
| Bottom cluster is full-width + bottom-anchored in a narrow pane | `HostedComponentCenteringTests.testBottomClusterIsFullWidthAndBottomAnchoredInNarrowPane` | same |
| Permission card grows the cluster host upward without moving the bar's bottom anchor | `HostedComponentCenteringTests.testPermissionCardGrowsHostUpwardWithoutMovingBarAnchor` | same |
| Hit-test invariant: cluster host doesn't occlude the transcript above; in-card click resolves into the host (passthrough is geometry, not transparency — §0.1) | `DetailPaneTranscriptHitTestTests.testPermissionCardPassesTranscriptClicksThrough` | `cctermTests/DetailPaneTranscriptHitTestTests.swift` |
| Archive fills pane in a large window (visual) | `AppKitSwiftUIBoundarySnapshotTests.testArchiveInLargeWindow` (opt-in, CI-skipped) | `cctermTests/AppKitSwiftUIBoundarySnapshotTests.swift` |
| Input bar centered (visual) | `AppKitSwiftUIBoundarySnapshotTests.testInputBarCentered` (opt-in, CI-skipped) | same |
| Toolbar-slot (B′), floating overlay (B″), window-content (C), sheet (D) | **not yet tested** — by-design regimes with no collapse failure mode | — |
| Leaf-in-cell (E) | **no production instance** (transcript is Core-Text self-drawn) | — |

All gate classes (`AppKitSwiftUIBoundaryTests`, `HostedComponentCenteringTests`)
have **no** `Snapshot` filename suffix → they run on CI as merge gates. The
`*SnapshotTests` class is auto-skipped on CI / opt-in via FILTER. All pass at HEAD
and the no-collapse gates fail when the production fix is reverted (teeth
confirmed — `nodes/verify-results.md`).

---

## 7. Sources

Apple primary: NSHostingSizingOptions, NSHostingController(.sizingOptions /
.preferredContentSize), NSHostingView, WWDC22 "Use SwiftUI with AppKit".
Community: Brian Webster "How NSHostingView determines its sizing" (the
full-default-set fact). CCTerm: the file:line citations throughout and the four
research nodes under `docs/refactor/boundary/nodes/` (removed from this PR's
tip to keep it lean, preserved in branch git history).

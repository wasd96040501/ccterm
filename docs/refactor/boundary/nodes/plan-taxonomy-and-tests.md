# Plan: canonical AppKit↔SwiftUI boundary taxonomy + concrete test plan

Built from the three research nodes (`research-web.md`, `research-census.md`,
`research-painpoints.md`) and re-verified against live code in this worktree.

Legend: **FACT** = read directly in source/docs. **INFERENCE** = my judgment.
All `file:line` are against `/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f`.

Verified constants (re-read for this plan, FACT):
- `BlockStyle.maxLayoutWidth = 780` — `nonisolated static let`, **internal** access, reusable verbatim in tests (`macos/ccterm/Content/Chat/NativeTranscript2/Model/Block.swift:1104`).
- `ChatSessionViewController.detailHorizontalInset = 20`, `composeMaxWidth = 512` — `internal static let`, reusable (`ChatSessionViewController.swift:60,62`).
- ⇒ `maxHostWidth = BlockStyle.maxLayoutWidth + 2 * detailHorizontalInset = 780 + 40 = 820` (`ChatSessionViewController.swift:182`).
- `ChatSessionViewController.present(sessionId:animated:)` is the public attach entry (`ChatSessionViewController.swift:249`).
- `DetailRouterViewController.currentChild` is `private(set) var` → readable under `@testable import ccterm` (`DetailRouterViewController.swift:89`).
- `NSWindow.ccterm_orderFrontForTesting()` exists (`App/CCTermApp.swift`).
- `composeOrBarHost` is `private var` on `ChatSessionViewController` (`ChatSessionViewController.swift:94`). **Test seam needed** — see §2.2.

---

## PART 1 — The canonical taxonomy

### 1.1 The four regimes (decision table)

The root `CLAUDE.md` names two regimes (`[]` fill-pane / `[.intrinsicContentSize]`
component); the census surfaced two more (window-content, modal-sheet). Every one of
the 16 hosting sites falls into exactly one bucket (FACT — `research-census.md` §9).

| # | Boundary situation | Host kind | `sizingOptions` | Constraint pattern | Binding rule | Window-collapse risk | Canonical rule (one line) | Reference impl |
|---|---|---|---|---|---|---|---|---|
| A | **Fill-a-pane host** (detail child that *is* the pane) | `NSHostingController` | `[]` | pin **all 4 edges** to container | two-way `Binding`/`@Bindable` OK; the binding is **not** the collapse cause | **YES** if default options — `view.fittingSize` leaks up the split into the window solver | Container drives size; host publishes none. `[]` + 4-edge pin. | `ArchiveViewController.swift:102-111` |
| B | **Centered, width-capped, bottom-anchored component** (input bar) | `NSHostingView` | `[.intrinsicContentSize]` | `centerX` + `width<=cap`(req) + `width==cap`(@high) + `leading>=`inset + `bottom==`edge | read-mostly `@Bindable` OK; height intrinsic ⇒ no split leak even on write | **NO** — content drives height only; AppKit owns width/placement | Content drives the cross-axis; AppKit centers + caps the main axis. | `ChatSessionViewController.swift:169,182-208` |
| B′ | **Toolbar-slot component** | `NSHostingView` | `[.intrinsicContentSize]` | none — `NSToolbar` auto-measures via intrinsic size | `@Bindable` OK (one writes `archiveSelectedFolderPath`) | NO — toolbar sizes the slot, host never feeds a split | Let intrinsic size feed the toolbar; pin nothing. | `MainWindowController.swift:253,280` |
| B″ | **Floating/positioned component** (corner / bottom-center overlay; DEBUG demos) | `NSHostingView` | default (benign) | position-only (centerX+bottom / trailing+bottom / centerX+centerY) — **never 4-edge** | `@Bindable` OK | NO — never pins 4 edges, so intrinsic size never governs the container | Position it; don't pin 4 edges, so its fitting size can't escape. | `TranscriptDemoViewController.swift:112-115` |
| C | **Window-content host** (`NSWindow.contentViewController`) | `NSHostingController` | **default** (intended) | `NSWindow(contentViewController:)`; optionally `.preferredContentSize` | usually none | N/A — collapse-to-content is the **goal** | Keep the default; you *want* the window to snap to the content. | `SettingsWindowController.swift:15`, `AboutWindowController.swift:23` |
| D | **Modal-sheet host** (`beginSheet`) | `NSHostingController` | **default** (intended) | `NSWindow(contentViewController:)` → `window.beginSheet(...)` | value + Done callback | N/A — sheet sizes to content by design | Same as C; the sheet sizes to its content. | `Transcript2SheetPresenter.swift:192` |
| E | **Leaf SwiftUI in an AppKit cell/row** | `NSHostingView` (inside cell) | `[.intrinsicContentSize]` (INFERENCE — no production instance today; the transcript is Core-Text self-drawn, not hosted) | pin to cell content insets; let intrinsic size feed `heightOfRow`/cell sizing | value-in, callbacks-out (avoid hot two-way binding in a recycled cell) | NO — the cell/row owns the height query | Intrinsic size feeds the cell's height; never let a recycled cell host fight the table's tile. | none in CCTerm (taxonomy-completeness node) |

The **distinguishing question** (root `CLAUDE.md` §"Embedding SwiftUI in AppKit: host sizing", FACT):
> Does the host **fill its container** (→ `[]`, container drives size) or **sit inside it as a component** (→ `[.intrinsicContentSize]`, content drives size)?
> — plus the third axis: is the host **itself a window's content** (→ default, content drives the *window*)?

### 1.2 Two-way `Binding`-across-boundary — the rule

(FACT for mechanism, INFERENCE for synthesis — `research-web.md` §3,9; `research-painpoints.md` §1.6)

1. **Allowed and idiomatic.** A `Binding(get:set:)` (or `@Bindable`) reading/writing an
   AppKit-owned `@Observable` is the standard single-source-of-truth pattern across the
   boundary (`ArchiveViewController.swift:63-66`). Use `[weak self]` in both closures.
2. **The binding is NOT the cause of the archive collapse.** The collapse is a *sizing-regime*
   bug (regime A with default options). It reproduces on **first mount**, before any binding
   write (`ArchiveViewController.swift:84-101` comment; `research-painpoints.md` §1.3). Three
   other fill-pane sites with **no** boundary-crossing binding need the identical `[]` fix
   (`ComposeSessionViewController.swift:115`, `DraftSessionLandingViewController.swift:136`,
   `DetailRouterViewController.swift:443`) — proving the binding is not the mechanism.
3. **Under a leaking regime the binding is the *pump*.** With default options, every binding-driven
   body re-eval re-queries the content's ideal size and **republishes** the small `fittingSize`,
   so a filter change re-trips the collapse and can defeat a manual resize — which is why the
   user perceived "two-way binding squashed the window" (INFERENCE, grounded in the runloop
   tick model + the toolbar write site `MainWindowController.swift:321`).
4. **With `sizingOptions = []` the binding is height-neutral.** No intrinsic size to republish ⇒
   body re-evals can't move the window; the 4-edge pin holds regardless of write frequency.
5. **Timing:** `@Observable` writes don't reach SwiftUI bodies in the same runloop tick (bodies
   re-eval in `beforeWaiting`). Don't read the model from SwiftUI right after an AppKit write.

### 1.3 `NSHostingController` vs `NSHostingView`

(FACT — `research-web.md` §6)
- **`NSHostingController`** — a pane / child VC / sheet / popover / window content; forwards
  `viewDidLoad`/`viewWillAppear`/appearance/size-class into the SwiftUI runtime. Regimes A, C, D.
- **`NSHostingView`** — a small in-place subview (component, toolbar slot, bar over a transcript);
  no VC lifecycle, you own placement, tighter hit-testing. Regimes B, B′, B″, E.

### 1.4 The required-window-size rule (headline evidence)

(FACT + INFERENCE — `research-painpoints.md` §1.5, §3.1; existing gate `DetailRouterLayoutDiagnosticsTests.swift:122,128`)
- A collapse target is ~545×276 (≈276pt tall). A regression probe for regime A **MUST** mount
  in a **large** window (≥ ~1100×760; existing gate uses **1200×860**) with `window.minSize.height`
  **strictly below** the healthy height (existing: 540), so AppKit's `minSize` clamp can't mask a
  partial collapse and the drop to ~276 is unambiguous.
- A small/flat window (~600×300) CANNOT detect this — collapsed ≈ starting height, so the
  assertion passes on both broken and fixed code. **The window size is part of the evidence and
  must be called out in the test.**
- Regime B (subordinate component) does NOT need a large window; its load-bearing dimension is
  **width** (> `maxHostWidth = 820`) to exercise the cap.

---

## PART 2 — The concrete test plan (exactly three files)

Shared conventions (FACT — `cctermTests/CLAUDE.md`): `@MainActor final class`, class name == filename,
`continueAfterFailure = false`; fresh in-memory deps per test (`InMemorySessionRepository`,
`SessionManager(repository:cliClientFactory:{ _ in FakeCLIClient() })`); unique `UserDefaults(suiteName:)`
+ teardown; temp dirs under `temporaryDirectory/UUID()` + teardown; no `*.shared`, no `.default`
NotificationCenter, no `UserDefaults.standard`, no `sleep`/`Task.sleep` for sync (use runloop pump
+ MainActor settle, exactly like `DetailRouterLayoutDiagnosticsTests.settle()`).

Reuse the proven fixture builder + `settle()` + `drainMainLoop()` pattern from
`DetailRouterLayoutDiagnosticsTests.swift:34-90` verbatim (copy into each new file; do not factor
into a shared base — XCTest forks per class).

### 2.1 `AppKitSwiftUIBoundaryTests.swift` — CI gate, measurement probe (regime A)

Filename has **no** `Snapshot` suffix ⇒ runs on CI as a merge gate. Class `AppKitSwiftUIBoundaryTests`.

**Fixture** (per test): the `makeFixture(sessionCount:)` from `DetailRouterLayoutDiagnosticsTests.swift:34-71`
— builds a real `MainSelectionModel`, `SessionManager`, and `DetailRouterViewController` with all six
injected in-memory deps. **No new production seam needed** for tests (a)/(c) — they drive the real
router swap path, exactly as the existing diagnostics gate does.

**Test (a) — `testArchiveFillPaneDoesNotCollapseLargeWindow`**
- *Mounts:* real `DetailRouterViewController` as the **detail item of a real two-item
  `NSSplitViewController`** that is the window's `contentViewController` (the production shape —
  a bare VC as content collapses regardless; the split is what makes the leak observable,
  `DetailRouterLayoutDiagnosticsTests.swift:96-103,108-130`). Sidebar item = placeholder
  `NSViewController`; detail item = router, `minimumThickness = 680`.
- *Window size:* **1200 × 860**, `minSize 880 × 540`, parked at `(-30_000,-30_000)`, `alphaValue 0.01`,
  `ccterm_orderFrontForTesting()`. **Call the size out in a comment as load-bearing evidence**:
  the healthy height (860) must dwarf the collapse target (~276) for the assertion to have teeth.
- *Steps:* `model.selection = .newSession`; `await settle()`; record `chatHeight = window.frame.height`.
  `model.select(.archive)`; `await settle()`; record `archiveHeight`.
- *Asserts:*
  - `archiveHeight >= chatHeight - 1` (window did not flatten) — tolerance 1pt, matching the
    existing gate (`:161-164`).
  - **Stronger isolation (promote the existing diagnostic to an assertion):**
    `XCTAssertLessThanOrEqual(router.currentChild?.view.fittingSize.height ?? .greatestFiniteMagnitude, 1)`
    — the fixed `[]` regime publishes `0×0`; this isolates the regime from any window-clamp noise
    (`research-painpoints.md` §1.7 step 6).
  - Attach a text `XCTAttachment` with chat/archive heights + child fittingSize (debug aid, matches
    `:151-159`).

**Test (b) — `testDefaultSizingOptionsHostLeaksFittingSizeInLargeWindow` (the A/B that proves the gate has teeth)**
- *Purpose:* prove the probe can DETECT a collapse, so test (a) isn't vacuously green.
- *Mounts:* a **throwaway** `NSHostingController(rootView:)` built inline in the test (NOT a mutated
  production VC — production-code rule, `research-census.md` §8), hosting a `ScrollView`-rooted body
  with a small header (faithful stand-in for `ArchiveView`'s shape: `ScrollView { VStack { … }
  .frame(minWidth: 480, maxWidth: 760) }`). Leave `sizingOptions` at **default** (do not set `[]`).
- *Window size:* same **1200 × 860** large window (the size that makes the leak visible).
- *Asserts (two faces of the same fact):*
  - The default-options host's `host.view.fittingSize.height` is **small** (`< 400`, comfortably
    below the 860 window and bracketing the documented ~276) — i.e. the bad regime publishes a
    collapse-sized fitting height. Use a band assertion (`> 50 && < 400`) rather than an exact 276
    (the number drifts with content; FACT — `ArchiveViewController.swift:91,97`,
    `research-census.md` §2.1).
  - **Contrast leg:** build the *same* body in a second host, set `sizingOptions = []`, assert its
    `view.fittingSize.height <= 1` (≈ `0×0`). The pair (default leaks small / `[]` ⇒ 0) is the
    teeth: it demonstrates the measurement dimension responds to the regime.
- *No production seam* — entirely test-local hosts.

**Test (c) — `testComposeAndDraftLandingFillPanesDoNotCollapse`**
- *Purpose:* the regime-A no-collapse contract for the other two production fill-pane children
  (`ComposeSessionViewController`, `DraftSessionLandingViewController`).
- *Mounts:* real `DetailRouterViewController` in the same large split/window as (a). Drive
  `model.select(.newSession)` (→ `ComposeSessionViewController`) and a draft-landing selection
  (→ `DraftSessionLandingViewController` — route via `model.select(.session(draftSid))` for a draft
  session id created in the fixture; confirm the exact draft-landing selection enum by reading
  `DetailRouterViewController.makeChild` `:375-404` and `DetailRouterDraftRoutingTests.swift`).
- *Window size:* **1200 × 860**, `minSize 880 × 540`.
- *Steps/asserts:* record height on a known full-height child, switch to each fill-pane child,
  `await settle()`, assert `height >= baseline - 1` and `currentChild.view.fittingSize.height <= 1`
  after each. One height-collapse assertion per child.
- *Binding-pump regression (optional, strong — `research-painpoints.md` §1.7):* after landing on
  `.archive` in test (a), write `model.archiveSelectedFolderPath = "/tmp/x"` to force a body re-eval,
  `await settle()`, assert the height **still** holds — proving the `[]` regime makes binding writes
  height-neutral. Add as a final block in test (a) or as a 4th method `testArchiveBindingWriteStaysHeightNeutral`.

### 2.2 `HostedComponentCenteringTests.swift` — CI gate, measurement probe (regime B)

Filename no `Snapshot` suffix ⇒ CI gate. Class `HostedComponentCenteringTests`.

**What it mounts:** the **real** `ChatSessionViewController` (full DI init — same six deps as the
router fixture). Drive `present(sessionId:)` with a session id so `ChatComposeStack.content(for:)`
renders the **chat resting bar** branch (`ChatSessionViewController.swift:628,636,659`), then pump
the runloop to settle layout.

**Test seam (REQUIRED — obeys production rules):** `composeOrBarHost` is `private var`
(`ChatSessionViewController.swift:94`). To sample its frame, **widen `private` → `internal`** on the
stored property declaration only — *access modifier only, no behavior change* (explicitly allowed,
`cctermTests/CLAUDE.md` Production code rules; `research-census.md` §8). Do **not** add a
`forceXxx`/getter method, do **not** expose it `public`, do **not** add a DEBUG variant. (INFERENCE:
this is the minimal seam; the alternative — recursively finding the `NSHostingView<AnyView>` in the
view tree — is brittle and discouraged.)

**Window:** offscreen, `alphaValue 0.01`, `ccterm_orderFrontForTesting()`, mounted so the VC's view
gets a real frame (pin the router/VC view into a sized container exactly like
`DetailRouterLayoutDiagnosticsTests.swift:201-212`). Height only needs to host transcript + bar
(e.g. 800); **width is the load-bearing dimension.** Run at **two widths**:

- **Wide leg — width ≈ 1100** (detail wider than `maxHostWidth = 820`):
  - `composeOrBarHost.frame.width == 820` (cap reached) — tolerance ±1pt.
  - centered: `abs(composeOrBarHost.frame.midX - view.bounds.midX) <= 1`.
- **Narrow leg — width ≈ 680** (the split detail minimum, `MainSplitViewController.swift:60`;
  680 < 820 so the cap can't be met):
  - `composeOrBarHost.frame.width <= viewWidth` (no overflow) AND `frame.minX >= -0.5` (the
    `leading >=` guard held).
  - still centered: `abs(frame.midX - view.bounds.midX) <= 1`.
- **Both legs:**
  - bottom-anchored: `abs(composeOrBarHost.frame.maxY - view.bounds.maxY) <= 1`.
  - height is the bar's intrinsic height, NOT full-pane: `frame.height < view.bounds.height * 0.5`
    (small relative to the pane — the component-regime invariant). (INFERENCE on the 0.5 factor; the
    bar is ~tens of pt vs an 800pt pane.)
- Attach a text report (both widths' frames) for debugging.

Reuse `BlockStyle.maxLayoutWidth` (=780, internal) and `ChatSessionViewController.detailHorizontalInset`
(=20, internal) to compute the expected `820` cap **in the test** rather than hardcoding — keeps the
gate in lockstep if the constants change (FACT — both internal, `research-census.md` §8).

**Best-practice conclusion baked into the test's doc comment** (FACT/INFERENCE — `research-web.md` §5,
`research-painpoints.md` §2.5): this five-constraint recipe (`centerX` + `width<=cap`(req) +
`width==cap`(@high) + `leading>=`inset + `bottom`) with `[.intrinsicContentSize]` for height is the
**canonical** "centered, width-capped, shrink-to-fit, bottom-anchored component" pattern — superior
to a `GeometryReader`+`PreferenceKey` height hack (the discarded approach, root `CLAUDE.md`). Note in
the comment that the DEBUG `PermissionSessionDemoViewController` host (census #11) is the *legacy*
hand-rolled shape and should not be copied.

### 2.3 `AppKitSwiftUIBoundarySnapshotTests.swift` — opt-in PNG (visual confirmation)

Filename **has** `Snapshot` suffix ⇒ auto-skipped on CI; opt-in via `make test-unit FILTER=...`.
Class `AppKitSwiftUIBoundarySnapshotTests`. Pure visual review — passes on plausibility, not pixels.

**Test (a) — `testArchiveInLargeWindow`**
- Mount the real `DetailRouterViewController` (router fixture) as the detail item of the real split
  in a large window, select `.archive`, settle, then render the **window's split content view** to PNG
  via `ViewSnapshot.renderViewController(split, size: CGSize(width: 1200, height: 860))` (or capture
  the split's view). Write `ArchiveBoundary-LargeWindow.png`. Assert `image.size.width >= 1100`
  (plausibility). Human opens the PNG to confirm the archive list fills the pane (not collapsed).
- (Reuse `ViewSnapshot.renderViewController` `:103` for the AppKit-rooted host; `ViewSnapshot.writePNG`
  `:153`.)

**Test (b) — `testInputBarCentered`**
- Mount the real `ChatSessionViewController`, `present(sessionId:)` a session, render at a wide size
  (e.g. 1100 × 800) to PNG `InputBar-Centered.png`. Assert `image.size.width >= 1000`. Human opens the
  PNG to confirm the bar is horizontally centered + width-capped.

No new seam beyond the §2.2 `private`→`internal` widening (already justified); the snapshot itself
needs no property access.

### 2.4 Production-code seams summary (all obey the rules)

| Seam | File | Change | Justification |
|---|---|---|---|
| `composeOrBarHost` reachable in §2.2 | `ChatSessionViewController.swift:94` | `private var` → `internal var` (modifier only) | Allowed: access-modifier widening, no behavior change (`cctermTests/CLAUDE.md`). Needed to sample the host frame for the centering gate. |
| `BlockStyle.maxLayoutWidth` | `Block.swift:1104` | none — already `internal` | Reuse verbatim to compute the 820 cap. |
| `detailHorizontalInset` / `composeMaxWidth` | `ChatSessionViewController.swift:60,62` | none — already `internal` | Reuse verbatim. |
| `currentChild` | `DetailRouterViewController.swift:89` | none — `private(set)`, readable via `@testable` | Sample `currentChild.view.fittingSize` in §2.1. |

**Forbidden (not used):** `#if DEBUG` UI variants, env-gated layout, `forceXxxForTest()`, exposing
mutable internals, mutating production `sizingOptions` to exhibit the bad regime (the §2.1(b) bad-regime
host is built **inline** in the test, never via production code).

### 2.5 Why these three and no more

- `AppKitSwiftUIBoundaryTests` covers regime A (the collapse class) for all 3 production fill-pane
  children + the A/B teeth proof + the binding-pump neutrality.
- `HostedComponentCenteringTests` covers regime B (the centered component) end-to-end at both width
  extremes.
- `AppKitSwiftUIBoundarySnapshotTests` gives the two human-eyeball confirmations.
- Regimes B′ (toolbar), B″ (floating demos), C (window-content), D (sheet), E (leaf-in-cell) are
  **documented in the taxonomy** but need no new gate: B′/B″/C/D are by-design and have no
  collapse failure mode (the host never pins 4 edges into a split / is the window's own content),
  and E has no production instance in CCTerm (transcript rows are Core-Text self-drawn, not hosted).
  (INFERENCE — `research-census.md` §5,6,9.)

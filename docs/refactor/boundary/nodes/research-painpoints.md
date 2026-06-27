# Boundary pain-points deep-dive: Archive window-collapse + input-bar centering

Two AppKit↔SwiftUI boundary situations dissected against the live code, with
the exact mechanism and a reproduction recipe (including the required window
size) for each.

All `file:line` references are against the worktree
`/Users/luoyangze/code/ccterm/.claude/worktrees/epic-nightingale-1d6c6f`.

Legend: **FACT** = read directly in source/docs. **INFERENCE** = my judgment
from reading the code.

---

## 1. Archive window-collapse

### 1.1 The reported symptom

The user reported (PR #224) that selecting the Archive tab "flattens" the main
window — its height collapses — and that switching back to chat does not restore
it. The user also phrased it as "two-way binding caused the window to be
squashed."

The harness comment that pins both PR #224 regressions:
`DetailRouterLayoutDiagnosticsTests.swift:8-17` —

> 1. Selecting Archive flattens the window (height collapses).
> 2. Opening a history session can paint a blank transcript.

### 1.2 The component chain

```
NSWindow.contentViewController
  └─ MainSplitViewController (NSSplitViewController)      MainSplitViewController.swift:10
       ├─ sidebar item  → SidebarViewController            (minThickness 220)  :47-56
       └─ detail item   → DetailRouterViewController        (minThickness 680, canCollapse=false)  :58-62
            └─ (selection == .archive) → ArchiveViewController   DetailRouterViewController.swift:395-404
                 └─ NSHostingController<AnyView>(ArchiveView)     ArchiveViewController.swift:83
                      └─ ArchiveView  →  root is a ScrollView     ArchiveView.swift:106
```

The detail item is **non-collapsible** and has `minimumThickness = 680`
(width only) — `MainSplitViewController.swift:60-61`. **FACT.** That governs
*width*, not *height*; nothing in the split pins the detail's height, so the
height is free to be driven by whatever the detail subtree publishes as its
fitting size. **INFERENCE.**

### 1.3 The TRUE mechanism — it is the `sizingOptions` regime, NOT the Binding

The collapse is caused by **`NSHostingController`'s default `sizingOptions`
publishing the SwiftUI body's `fittingSize` as an intrinsic size**, which leaks
*up* through the split's own `view.fittingSize` into the window's constraint
solver, which then resizes the window's content down to that small fitting
height. The two-way `Binding` is **not** the cause of the collapse; it is a
separate, real concern (see §1.6) but it only changes *when SwiftUI re-evaluates
the body*, not *whether the fitting size leaks*.

The authoritative in-code explanation is the block comment on the fix,
`ArchiveViewController.swift:84-101` (quoted verbatim):

```
// `NSHostingController`'s default `sizingOptions` binds the
// SwiftUI body's fitting size into the hosting view's layout, so
// `host.view.fittingSize` tracks the content's ideal size. That's
// right for a standalone window's `contentViewController` (Settings
// / About / Logs size to their content), but this host is a
// fill-the-pane detail child: `ArchiveView`'s root is a `ScrollView`
// whose fitting height is just the header (~176pt before the async
// list lands). With the default options that small fitting height
// bubbles up through the detail VC → the `NSSplitViewController`'s
// `view.fittingSize`, and the window resizes its content down to it
// — the whole window collapses to ~176pt the instant Archive is
// selected (and stays collapsed when you switch back, since chat
// contributes no fitting height to grow it again). Confirmed
// offscreen: with the default, `host.view.fittingSize` ≈ 545×276;
// cleared, it's 0×0 and the split fills the window. The pane must
// take whatever height the window gives it via the 4-edge
// constraints below — never drive it. `[]` matches `NSHostingView`'s
// default, which the chat pane's compose host already relies on.
```

The fix itself: `ArchiveViewController.swift:102` —

```swift
host.sizingOptions = []
```

…followed by pinning all four edges so the *container* drives the host's size,
`ArchiveViewController.swift:104-111`:

```swift
host.view.translatesAutoresizingMaskIntoConstraints = false
view.addSubview(host.view)
NSLayoutConstraint.activate([
    host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
    host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    host.view.topAnchor.constraint(equalTo: view.topAnchor),
    host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
])
```

**Why "switch back to chat doesn't restore it":** chat (`ChatSessionViewController`)
contributes *no* fitting height — its scroll view fills the pane and its bar host
is `.intrinsicContentSize` but bottom-anchored, not a full-height driver — so once
the window has shrunk to ~276pt there is nothing to push it back up. **FACT** (the
comment states this) / **INFERENCE** (corroborated by the chat VC's constraint
shape, §2).

### 1.4 The `~545×276` figure and how it was measured

The comment records the measured leak: `host.view.fittingSize ≈ 545×276` with
the default options, `0×0` when cleared (`ArchiveViewController.swift:97-98`).
**FACT.**

`276` is the height the window collapses toward; `545` is the ScrollView's ideal
width (the column is `frame(minWidth: 480, maxWidth: 760)` + 24pt horizontal
padding, `ArchiveView.swift:112-117`, `ArchiveView.swift:302-303`). The exact
value drifts with content (the comment elsewhere says "~176pt before the async
list lands", `ArchiveViewController.swift:91`) — the point is it is *small
relative to a real window height*, not the precise number. **INFERENCE.**

### 1.5 The existing regression gate (and its caveat)

`DetailRouterLayoutDiagnosticsTests.testArchiveSelectionDoesNotFlattenWindow`
(`DetailRouterLayoutDiagnosticsTests.swift:104-165`) is the live merge gate.
**FACT.** Structure worth copying:

- It mounts the **real** `DetailRouterViewController` as the detail item of a
  **real two-item `NSSplitViewController`** that is the window's
  `contentViewController` — `:108-130`. The comment at `:96-103` is explicit
  that the *split shape matters*: a plain VC as `contentViewController` collapses
  to AppKit's minimum regardless, so the split is what makes the leak observable.
  **FACT.**
- It diagnoses with `fx.router.currentChild?.view.fittingSize`
  (`:150`) and asserts `archiveHeight >= chatHeight - 1` (`:161-164`).
- It records `chatHeight` first (selection starts at `.newSession`, `:106`),
  flips to `.archive` (`:141`), re-reads (`:143`).

**The window-size evidence.** The test window is `1200 × 860`
(`DetailRouterLayoutDiagnosticsTests.swift:122`) with `minSize 880 × 540`
(`:128`). This sizing is itself load-bearing evidence: a collapse to ~276pt is
unambiguous only when the *healthy* height is far larger. **A small/flat test
window cannot detect this bug** — if the window were already ~300pt tall, the
"collapsed" height would be ≈ the starting height and the assertion would pass
on both the broken and the fixed code. **FACT** (the window is 860 tall; the
collapse target is ~276) / **INFERENCE** (the detectability argument). Note also
the `minSize.height = 540` (`:128`): a regression test must keep the window's
`minSize` height *below* the chat height but the assertion tolerance tight, or
AppKit's own `minSize` clamp would mask a partial collapse — `540 < 860` leaves
room for the collapse to show.

> Recommendation for the canonical taxonomy: a regression test for the
> fill-pane-host regime should use a window **≥ ~1100×760** (the existing one
> uses 1200×860) so the post-collapse ~276pt height is unmistakable, AND keep
> `window.minSize.height` strictly below the healthy height so AppKit's clamp
> doesn't hide it.

### 1.6 What the two-way Binding actually is (and why it is *not* the collapse)

The Binding the user referred to is constructed in
`ArchiveViewController.viewDidLoad`, `ArchiveViewController.swift:63-66`:

```swift
let folderBinding = Binding<String?>(
    get: { [weak self] in self?.model.archiveSelectedFolderPath },
    set: { [weak self] in self?.model.archiveSelectedFolderPath = $0 }
)
```

…passed into `ArchiveView(selectedFolderPath: folderBinding, …)`
(`ArchiveViewController.swift:68-69`), where it lands on
`@Binding var selectedFolderPath: String?` (`ArchiveView.swift:54`).

The source of truth is `MainSelectionModel.archiveSelectedFolderPath`
(`MainSelectionModel.swift:99`), a **plain `@Observable` var** (it is *not*
`@ObservationIgnored`, unlike `selectionObserver` at `:45`). **FACT.**

The reason it is two-way: the *same* field is written by the AppKit toolbar's
folder-filter button (`ArchiveFilterToolbarButton`,
`MainWindowController.swift:299-327`, which reads/writes
`model.archiveSelectedFolderPath` at `:310-321`) and read by the list filter
(`ArchiveView.filteredRecords`, `ArchiveView.swift:276-292`). The doc comment at
`MainSelectionModel.swift:93-99` and `ArchiveView.swift:48-54` both explain that
the binding exists because the SwiftUI `.toolbar { }` modifier is silently
dropped inside an AppKit-rooted host, so the button had to move to the
`NSToolbar` and share state through the model. **FACT.**

**Why the Binding could *look* like the culprit (and why it is not):**
because `archiveSelectedFolderPath` is observable, writing it (e.g. via the
toolbar popover, or `ArchiveView.onChange(of: manager.archivedFolderOptions)`
auto-clearing a stale filter, `ArchiveView.swift:135-145`) re-evaluates
`ArchiveView.body`. Under the **default** `sizingOptions` regime, every body
re-eval republishes `host.view.fittingSize` — so a filter change would *re-trip*
the collapse and make it feel "caused by the binding." But the collapse is
present on the *first* mount before any binding write, purely from the initial
fitting-size publish. **The Binding amplifies/re-triggers the symptom under the
broken regime; it does not create it.** With `sizingOptions = []` the host
publishes no fitting size at all (`0×0`), so binding-driven body re-evals are
harmless. **INFERENCE** (grounded in the tick model: `@Observable` writes →
SwiftUI body re-eval in `beforeWaiting`, per `CLAUDE.md` "macOS runloop tick
model"; and in the measured `0×0` vs `545×276` from `ArchiveViewController.swift:97`).

### 1.7 Reproduction recipe (regression test)

To reproduce a *collapse* (i.e., to prove the fix matters), a test must:

1. Build the **real** `DetailRouterViewController` and mount it as the **detail
   item of a real `NSSplitViewController`** that is the window's
   `contentViewController`. A bare VC won't show it (`:96-103`).
2. Make the window **large**: `≥ ~1100×760` (existing gate: `1200×860`,
   `:122`), `minSize` height strictly below that (`540`, `:128`).
3. Start selection on a *full-height* child (`.newSession` or a session), record
   `window.frame.height`.
4. `model.select(.archive)`, pump **both** the AppKit runloop and the MainActor
   executor (the `settle()` helper, `:85-90` — the router swaps on a synchronous
   observer call but `ArchiveView.task`/async layout settle needs the executor),
   re-read `window.frame.height`.
5. Assert `archiveHeight >= chatHeight - 1` (`:161-164`). On *broken* code
   (default `sizingOptions`) the height collapses to ~276 and the assertion
   fails; on *fixed* code (`sizingOptions = []`) it holds.
6. (Optional, stronger) directly assert `currentChild.view.fittingSize.height`
   is ~0 on the fixed code vs ~276 on broken — the diagnostic the existing test
   only *records* (`:150-159`) rather than asserts. **INFERENCE**: promoting
   that to an assertion would isolate the regime from any window-clamp noise.

To additionally exercise the *binding re-trigger* path (taxonomy completeness):
after landing on `.archive`, write `model.archiveSelectedFolderPath = <somePath>`
to force a body re-eval, settle, and assert the height *still* holds. This proves
the `[]` regime makes binding writes height-neutral. **INFERENCE.**

### 1.8 Same regime, replicated across all fill-pane detail children

The `sizingOptions = []` + 4-edge-pin pattern is the canonical "fill-a-pane
host" regime and is applied identically in every full-pane detail child — this
is the taxonomy node, not an Archive one-off. **FACT:**

- `ArchiveViewController.swift:102`
- `ComposeSessionViewController.swift:115` (comment `:112-114` repeats the
  fitting-size-leak rationale)
- `DraftSessionLandingViewController.swift:136` (comment `:134-136`)
- `DetailRouterViewController.swift:443` — the DEBUG permission-cards demo child
  (comment `:438-442`)
- `PermissionSessionDemoViewController.swift:134` (comment `:120` —
  "collapses the window. `sizingOptions = []` below severs that path.")

Contrast — the **subordinate-component** regime uses `[.intrinsicContentSize]`
because the host is a toolbar slot / bottom-anchored bar whose container is sized
by something else: `MainWindowController.swift:253` (project chip),
`MainWindowController.swift:280` (archive-filter toolbar button),
`ChatSessionViewController.swift:169` (input-bar host, §2). **FACT.** This is the
exact `[]` vs `[.intrinsicContentSize]` split documented in the root
`CLAUDE.md` "Embedding SwiftUI in AppKit: host sizing".

---

## 2. Input-bar centering (in-page hosted SwiftUI component)

### 2.1 What it is

The chat resting input bar is a SwiftUI component (`ChatComposeStack` →
`ChatRestingBar`, `ChatSessionViewController.swift:605-679`) hosted in a plain
`NSHostingView<AnyView>` named `composeOrBarHost`
(`ChatSessionViewController.swift:94`, created `:161`). It must be horizontally
centered + width-capped within the detail pane, bottom-anchored, and tall only
as the bar itself so the transcript receives clicks above it. **FACT.**

### 2.2 The host sizing option — subordinate component, not fill-pane

`ChatSessionViewController.swift:169`:

```swift
composeOrBarHost.sizingOptions = [.intrinsicContentSize]
```

Rationale comment `:163-168` — a plain `NSHostingView` "claims every point in
its bounds for hit-testing, shadowing the transcript table below it. We keep its
bounds to just the bar: the HEIGHT is left to the content's own intrinsic size
(`.intrinsicContentSize`), so the host is only as tall as the bar." **FACT.**

This is the **opposite** regime to Archive (§1): here width is owned by AppKit
constraints and height by the SwiftUI content. Because the host is
*bottom-anchored over a transcript that already fills the pane*, the host is a
subordinate component — there is no window-collapse risk from
`.intrinsicContentSize` (it does not govern its container's size). **FACT**
(matches the root `CLAUDE.md` rule of thumb).

### 2.3 The exact centering constraints

`ChatSessionViewController.swift:182-208`. The cap constant
(`:182`):

```swift
let maxHostWidth = BlockStyle.maxLayoutWidth + 2 * Self.detailHorizontalInset
```

(`detailHorizontalInset = 20`, `:62`.) The five constraints
(`:202-207`, activated in the block at `:191-208`):

```swift
composeOrBarHost.centerXAnchor.constraint(equalTo: view.centerXAnchor),                       // centerX
composeOrBarHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),                          // bottom-anchor
composeOrBarHost.widthAnchor.constraint(lessThanOrEqualToConstant: maxHostWidth),              // width <= cap (required)
composeOrBarHost.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),           // leading >= pane edge
composeOrBarHostWidthFill,                                                                      // width == cap @ .defaultHigh
```

where `composeOrBarHostWidthFill` is
(`:183-185`):

```swift
let composeOrBarHostWidthFill = composeOrBarHost.widthAnchor.constraint(
    equalToConstant: maxHostWidth)
composeOrBarHostWidthFill.priority = .defaultHigh
```

So the full recipe is the canonical centering pattern:

| Role | Constraint | Priority | file:line |
|---|---|---|---|
| Center horizontally | `centerX == view.centerX` | required | `:202` |
| Bottom-anchor | `bottom == view.bottom` | required | `:203` |
| Hard width cap | `width <= maxHostWidth` | required | `:204` |
| Don't overflow narrow pane | `leading >= view.leading` | required | `:205-206` |
| Fill up to cap on wide pane | `width == maxHostWidth` | `.defaultHigh` | `:183-185`, `:207` |

The constraint comments (`:172-181`) state the design intent precisely:
width fills up to the cap on a wide pane but **yields to `leading >=` on a pane
narrower than the cap (detail can be as small as 680)** so the bar shrinks to fit
instead of overflowing. The SwiftUI side then fills whatever width it is handed
(`.frame(maxWidth: .infinity)`, `ChatComposeStack.body` at
`ChatSessionViewController.swift:676`), and the narrower input pill
(`composeMaxWidth = 512`, `:60`) self-centers inside via its own frame
(`:176-177`, `:670-675`). **FACT.**

### 2.4 Why the cap is `BlockStyle.maxLayoutWidth + 2*inset`, not `composeMaxWidth`

The host is capped at the **widest content it ever hosts** — the permission card
(`BlockStyle.maxLayoutWidth`) plus its horizontal padding — so the card is never
clipped; the narrower input pill self-centers inside that width
(`:173-178`). **FACT.** **INFERENCE:** this is correct — sizing the host to the
*pill* width (512) would clip a permission card; sizing to the card width and
letting the pill self-center is the right layering.

### 2.5 Assessment — is this best practice?

**INFERENCE (yes, with one caveat).** The five-constraint pattern
(`centerX` + required `width<=cap` + `leading>=inset` + `width==cap @high`) is
the textbook AppKit way to express "centered, capped, but shrink-to-fit on a
narrow container" without a `GeometryReader`/`PreferenceKey` height hack — which
the root `CLAUDE.md` explicitly calls out as the discarded earlier approach
("Never hand-roll the height with `GeometryReader` + `PreferenceKey` + a manual
height constraint"). Using `.intrinsicContentSize` for the height is exactly what
that section prescribes for a subordinate component. So the *pattern* is
canonical and should be the taxonomy's reference implementation for "center an
in-page hosted SwiftUI component."

### 2.6 Edge cases worth noting

- **Very wide window:** `width == maxHostWidth @ .defaultHigh` wins (no
  competing high-priority width constraint), so the bar caps at `maxHostWidth`
  and `centerX` centers it — correct. **FACT** (constraint math) / **INFERENCE**.
- **Narrow pane (detail min 680, `MainSplitViewController.swift:60`):** if
  `maxHostWidth > pane width`, the required `width <= cap` and `leading >= edge`
  both bind; the `@high` `width == cap` is dropped, so the bar shrinks to
  `pane width - (centerX symmetry)` and stays inside both edges. `BlockStyle.maxLayoutWidth + 40`
  vs a 680 pane: whether the cap exceeds 680 depends on `BlockStyle.maxLayoutWidth`
  (not read here) — **INFERENCE:** if the cap is ≤ ~640 the bar never hits the
  narrow-pane branch in practice; if it exceeds the pane, the `leading >=`
  guard is what saves it. Either way the constraints are correct; the
  edge case is exercised, not broken.
- **No explicit `min width`:** there is no lower bound on the host width other
  than the SwiftUI content's own intrinsic minimum. **INFERENCE:** acceptable —
  the pill/card define their own minimums; an explicit floor would only matter
  for a degenerate (<~300pt) pane, which the 680 detail minimum precludes.
- **Trailing symmetry:** there is a `leading >=` guard but no explicit
  `trailing <=` guard. **INFERENCE:** unnecessary because `centerX` + the
  symmetric `width <= cap` make the layout symmetric — pinning leading is
  sufficient; AppKit derives the trailing inset from centerX symmetry. A
  `trailing <=` would be redundant.

### 2.7 Reproduction recipe (measurement probe)

A merge-gate measurement probe (NOT `*SnapshotTests.swift`) should:

1. Mount a real `ChatSessionViewController` in an offscreen window at **two**
   widths — one **wide** (e.g. detail ≈ 1100, wider than `maxHostWidth`) and one
   **narrow** (detail ≈ 680, the split minimum, `MainSplitViewController.swift:60`).
2. `present(sessionId:)` a session so `ChatComposeStack` renders the chat bar
   branch (`:647-667`); pump the runloop to settle layout.
3. Sample `composeOrBarHost.frame` and assert:
   - **wide:** `frame.width == maxHostWidth` (cap reached) and the host is
     centered (`frame.midX ≈ view.bounds.midX`).
   - **narrow:** `frame.width <= pane width` and `frame.minX >= 0` (leading
     guard held — no overflow) and still centered.
   - **both:** `frame.maxY == view.bounds.maxY` (bottom-anchored) and
     `frame.height` ≈ the bar's intrinsic height (small, not full-pane).
4. No window-collapse assertion is needed here (the host is subordinate); the
   window size only needs to be tall enough to host a transcript + bar
   (the bottom-anchor / intrinsic-height claims are width-independent). A
   wide-enough width to exceed `maxHostWidth` is the load-bearing dimension,
   not height. **INFERENCE.**

---

## 3. Canonical taxonomy nodes extracted

| Node | Regime | sizingOptions | Constraints | Window-collapse risk | Reference impl |
|---|---|---|---|---|---|
| Fill-a-pane detail child | container drives size | `[]` | pin all 4 edges | YES if default options | `ArchiveViewController.swift:102-111` |
| In-page subordinate component (centered, capped, bottom-anchored) | content drives height, AppKit caps width | `[.intrinsicContentSize]` | centerX + `width<=cap`(req) + `leading>=inset` + `width==cap`@high + bottom | NO | `ChatSessionViewController.swift:182-208` |
| Toolbar slot | content drives size | `[.intrinsicContentSize]` | toolbar auto-measures | NO | `MainWindowController.swift:253`, `:280` |

Key distinguishing question (root `CLAUDE.md`, "Embedding SwiftUI in AppKit:
host sizing"): **does the host fill its container (→ `[]`) or sit inside it as a
component (→ `[.intrinsicContentSize]`)?**

### 3.1 Required-window-size rule (the headline evidence)

A regression test for the **fill-pane** node MUST use a **large** window
(≥ ~1100×760; existing gate uses 1200×860,
`DetailRouterLayoutDiagnosticsTests.swift:122`) with `minSize` height strictly
below the healthy height, so a collapse to ~276pt
(`ArchiveViewController.swift:97`) is unambiguous. A small/flat test window
cannot detect the collapse — the broken and fixed heights would be
indistinguishable. The **subordinate-component** node does not need a large
window; its load-bearing test dimension is *width* (> `maxHostWidth`) to exercise
the cap.

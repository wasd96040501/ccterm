# Web best-practices: `NSHostingController` / `NSHostingView` sizing across the AppKit↔SwiftUI boundary (macOS 14+)

Scope: authoritative best practices for hosting SwiftUI inside AppKit on macOS Ventura+ (CCTerm targets macOS 14 Sonoma). Each rule is tagged **FACT** (read in Apple docs / WWDC / primary community source / CCTerm code) or **INFERENCE** (my judgment, derived from those facts). CCTerm code is cited as `file:line`; external sources as URLs.

---

## 0. TL;DR — the canonical rules

1. **The default `sizingOptions` for BOTH `NSHostingController` and `NSHostingView` is the full set `[.minSize, .intrinsicContentSize, .maxSize]`.** (FACT — WWDC22 §"Sizing", Brian Webster primary source.) This is the single most misunderstood fact; multiple secondary snippets wrongly claim the default is empty.
2. **Fill-a-pane host → `sizingOptions = []` + pin all 4 edges.** The container drives the size; the host must publish *no* intrinsic/min/max constraints, or its `view.fittingSize` leaks up the responder/constraint chain and collapses the window.
3. **Subordinate component → `sizingOptions = [.intrinsicContentSize]`** (drop `.minSize`/`.maxSize` unless you need them). Pin position only; let the content supply the missing dimension(s).
4. **Standalone window content (`window.contentViewController = host`) → keep the default** (or `[.preferredContentSize]`). You *want* the content's fitting size to drive the window.
5. **Two-way `Binding` across the boundary is fine in itself** — it does not by itself cause the collapse. The collapse is a *sizing-regime* bug; the binding only changes *when* the (bad) fitting size gets republished.

---

## 1. `NSHostingSizingOptions` — what each option does

`NSHostingSizingOptions` is an `OptionSet` introduced in macOS Ventura (13) / iOS 16 that controls **which Auto Layout constraints the host auto-creates from the SwiftUI content's proposed sizes**. (FACT — [NSHostingSizingOptions](https://developer.apple.com/documentation/swiftui/nshostingsizingoptions), [WWDC22 "Use SwiftUI with AppKit"](https://developer.apple.com/videos/play/wwdc2022/10075/).)

How the host derives each size — it **probes the SwiftUI rootView with three size proposals** (FACT — [Brian Webster, "How NSHostingView determines its sizing"](https://www.tumblr.com/brian-webster/723846294121152512/how-nshostingview-determines-its-sizing), mirrored at [mjtsai.com](https://mjtsai.com/blog/2023/08/03/how-nshostingview-determines-its-sizing/)):

| Option | Proposal used | Effect on Auto Layout | Notes |
|---|---|---|---|
| `.minSize` | `0×0` proposal → view's minimum size | Adds `>=` width/height constraints at the content's minimum. | Keeps the host from shrinking below content min. |
| `.intrinsicContentSize` | `nil×nil` proposal → ideal size | Publishes the content's **ideal** size as the host's `intrinsicContentSize` (an `==`-ish preferred constraint). | **This is the option that "pins" a host to its content and is the usual culprit in the collapse pitfall.** |
| `.maxSize` | `∞×∞` proposal → maximum size | Adds `<=` width/height constraints at the content's maximum. | For most content `∞` ⇒ no real cap, but it still costs a probe. |
| `.standardBounds` | (convenience) | Combination covering the common min/intrinsic/max bounds. | Shorthand grouping; prefer naming the specific options you want. |
| `.preferredContentSize` | ideal size | Drives the controller's `preferredContentSize` rather than adding view constraints. | `NSHostingController`-only flavor; used for popover/sheet/modal auto-sizing. (FACT — [preferredContentSize](https://developer.apple.com/documentation/swiftui/nshostingcontroller/preferredcontentsize), WWDC22.) |

**Defaults (FACT):**

- `NSHostingController.sizingOptions` default = `[.minSize, .intrinsicContentSize, .maxSize]`. (WWDC22; Webster.)
- `NSHostingView.sizingOptions` default = `[.minSize, .intrinsicContentSize, .maxSize]`. (WWDC22; Webster.)
- Pre-Ventura `NSHostingView` had no opt-out and *always* behaved like the intrinsic-size case; the macOS 12 workaround was to subclass and override `intrinsicContentSize` to return `NSView.noIntrinsicMetric` for the flexible axis. (FACT — Webster.)

> ⚠️ **Conflicting source, resolved.** A Bing/Apple search *snippet* during this research claimed "The default sizing options value is empty." That is **wrong** and contradicts both the WWDC22 talk and Webster's reverse-engineering of the probe behavior. Treat the full-set default as authoritative. (INFERENCE — the snippet was a low-quality auto-summary; the two primary sources agree on the full set.)

**Performance cost (FACT — [sizingOptions](https://developer.apple.com/documentation/swiftui/nshostingcontroller/sizingoptions), WWDC22):** every enabled option makes the host re-query the content's ideal size *on each view update*. Disabling options you don't need is a legitimate perf optimization, not just a layout fix.

---

## 2. The window-collapse / "squash" pitfall — true mechanism

**Symptom:** mounting a SwiftUI host that is supposed to *fill* a pane instead shrinks the whole window down to the content's natural height.

**Mechanism (FACT, cross-checked against CCTerm code + Apple/community sources):**

1. With `.intrinsicContentSize` enabled (the default), the host publishes the SwiftUI body's **ideal/fitting size** as an Auto Layout intrinsic-size constraint. ([NSHostingSizingOptions]; Webster.)
2. A `ScrollView`-rooted body has a *small* fitting height — the scroll view is happy to be any height, so its ideal height is roughly just the non-scrolling chrome (header). For CCTerm's `ArchiveView` this is ~176pt of header before the async list lands. (FACT — `macos/ccterm/Content/Archive/ArchiveViewController.swift:84-101`.)
3. That small intrinsic height bubbles **up the `view.fittingSize` chain**: detail child → `NSSplitViewController.view.fittingSize` → the window's constraint solver (`_changeWindowFrameFromConstraintsIfNecessary`), which then *resizes the window content down to it*. (FACT — CCTerm `CLAUDE.md` "Embedding SwiftUI in AppKit: host sizing"; corroborated by the WWDC22 note that a hosting view set as a window's content auto-drives the window's size.)
4. CCTerm measured this offscreen: with the default options the archive host's `view.fittingSize ≈ 545×276`; with `sizingOptions = []` it is `0×0` and the split fills the window. (FACT — `ArchiveViewController.swift:96-99`, and the live diagnostics probe `macos/cctermTests/DetailRouterLayoutDiagnosticsTests.swift:92-164` which asserts the window height does **not** flatten when archive is selected.)

**Cure (FACT — Apple WWDC22 "if the constraints are already added to surrounding views" + CCTerm):**

> A fill-a-pane host must publish **no** size constraints of its own and instead be pinned to its container on all four edges, so layout flows *down* (container → host), never *up* (host → window).

```swift
host.sizingOptions = []                                 // sever the fittingSize leak
host.view.translatesAutoresizingMaskIntoConstraints = false
NSLayoutConstraint.activate([
    host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
    host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    host.view.topAnchor.constraint(equalTo: view.topAnchor),
    host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
])
```

(FACT — `ArchiveViewController.swift:102-111`.)

**Why `[]` and not `[.minSize, .maxSize]`:** Webster's community fix for "Spacer won't expand" is `[.minSize, .maxSize]` (drop only `.intrinsicContentSize`). That is correct for a *component* that should still respect content min/max but flex in between. For a **pure fill-the-pane** host you want zero auto-constraints — the container's 4-edge pin is the complete size story, and any residual `.minSize`/`.maxSize` is just extra probing cost and a latent leak. CCTerm chose `[]`, matching `NSHostingView`'s pre-Ventura fill behavior. (INFERENCE, grounded in `ArchiveViewController.swift:100-101` + Webster.)

---

## 3. Is the collapse caused by the two-way `Binding`?

The user flagged "two-way binding caused the window to be squashed" for the archive page. **The binding is not the root cause.** (INFERENCE, grounded in code.)

- The collapse is fully explained by the **sizing regime** (`.intrinsicContentSize` on a `ScrollView`-rooted fill host). It reproduces on first mount, before any binding write, because the host publishes the small fitting size the instant it lays out. (FACT — `ArchiveViewController.swift:88-99`; diagnostics test mounts and the flatten is observed at selection time, `DetailRouterLayoutDiagnosticsTests.swift:139-164`.)
- The archive folder filter *is* a genuine two-way `Binding<String?>` between `model.archiveSelectedFolderPath` (AppKit-owned, on `MainSelectionModel`) and `ArchiveView`. (FACT — `ArchiveViewController.swift:63-66`.)
- **What the binding *would* do under the bad regime:** each write flips `model.archiveSelectedFolderPath`, re-evaluates `ArchiveView.body` in the next `beforeWaiting` flush, which re-probes the content's ideal size and **re-publishes** the (still small) fitting size — i.e. the binding turns a one-shot collapse into a *re-triggered* collapse on every filter change, and can defeat a manual window resize the user just performed. (INFERENCE, grounded in the runloop tick model in `CLAUDE.md` §"macOS runloop tick model" + the per-update re-query cost noted in [sizingOptions].)
- **With `sizingOptions = []` the binding is harmless:** the host has no intrinsic size to republish, so body re-evals can't move the window; the 4-edge pin holds the size regardless of how often the binding fires. (INFERENCE — once the leak path is severed, there is no fitting size to leak.)

**Verdict (TRUE mechanism):** the squash is a **sizing-regime bug** (`ArchiveViewController.swift:88-102`), not a binding bug. A two-way binding across the boundary only *amplifies* a pre-existing leak by re-publishing the fitting size on each update; it cannot create the leak where `sizingOptions = []`. CCTerm's comment at `ArchiveViewController.swift:88-99` describes exactly this.

---

## 4. Test-window sizing is itself evidence

A collapse to ~276pt is only *detectable* if the test window starts much larger than that.

- A small/flat test window (say 600×300) would already be ≈ the collapsed size, so "did it collapse?" is undetectable — the assertion can't distinguish "filled" from "collapsed." (INFERENCE.)
- CCTerm's diagnostics probe uses **1200×860** content with a 880×540 minSize and a 680pt detail minimum thickness, then compares window height in chat mode vs archive mode. The large window is what makes a drop to ~276 unambiguous. (FACT — `DetailRouterLayoutDiagnosticsTests.swift:122-131` window setup; `:128` minSize; `:119` detail min thickness; `:139-164` the height-comparison assertion.)
- **Rule for any new collapse-regression probe:** mount in a window ≥ ~1100×760 (CCTerm uses 1200×860), then assert the window height after selecting the fill-host pane is **not** materially less than before. Call the window size out in the test as part of the evidence. (INFERENCE, matching the existing probe.)

---

## 5. Centering + width-capping a hosted SwiftUI component (the input bar)

CCTerm's chat resting bar is the textbook **subordinate component** case: it sits over a transcript that already fills the pane, so the *content* should drive its height while *AppKit* owns its horizontal placement and width cap. (FACT — `ChatSessionViewController.swift:161-208`; `Content/Chat/CLAUDE.md:11`.)

The canonical constraint recipe (FACT — `ChatSessionViewController.swift:169`, `:182-207`):

```swift
composeOrBarHost.sizingOptions = [.intrinsicContentSize]   // HEIGHT from content
// WIDTH owned by AppKit:
let widthFill = composeOrBarHost.widthAnchor.constraint(equalToConstant: maxHostWidth)
widthFill.priority = .defaultHigh                            // fills up to cap, yields on narrow panes
NSLayoutConstraint.activate([
    composeOrBarHost.centerXAnchor.constraint(equalTo: view.centerXAnchor),     // centered
    composeOrBarHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),       // bottom-anchored
    composeOrBarHost.widthAnchor.constraint(lessThanOrEqualToConstant: maxHostWidth), // hard cap (required)
    composeOrBarHost.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor), // shrink-to-fit
    widthFill,
])
```

Why each piece (FACT, from the inline comments at `ChatSessionViewController.swift:163-185`):

- `centerX == container.centerX` — horizontal centering.
- `width <= cap` at **required** priority — never exceed the widest hosted content (permission card + padding).
- `width == cap` at **high** (not required) priority — fills to the cap on a wide pane but *yields* to `leading >=` on a pane narrower than the cap, so it shrinks instead of overflowing.
- `leading >= container.leading` — the safety stop that lets it shrink.
- `bottom == container.bottom` + `.intrinsicContentSize` height — the bar is exactly as tall as its content and grows upward for multi-line input / permission cards.
- The SwiftUI body itself uses `.frame(maxWidth: .infinity)` to fill whatever width AppKit hands it. (FACT — `ChatSessionViewController.swift:676`.)

**Best-practice assessment (INFERENCE):** this is the correct canonical pattern. Key correctness points:

1. **`.intrinsicContentSize` is RIGHT here** (unlike §2), because the component does not govern its container's size — the transcript does — so there is no window-collapse risk from publishing the height. CCTerm's `CLAUDE.md` makes this the explicit dividing line: *"does the host fill its container (→ `[]`) or sit inside it as a component (→ `[.intrinsicContentSize]`)?"*
2. **Center via `centerXAnchor`, cap via a `<=` width at required + an `==` width at non-required**, with a `leading >=` escape hatch. This is the standard Auto Layout idiom for "centered, capped, shrink-to-fit" and is more robust than hardcoding leading/trailing insets, which can't both center *and* cap.
3. **Anti-pattern (explicitly called out in CCTerm `CLAUDE.md`):** do **not** hand-roll the height with `GeometryReader` + `PreferenceKey` + a manual height constraint. `.intrinsicContentSize` does this for free; the GeometryReader approach was an earlier workaround.
4. **Hit-testing caveat (component-specific, FACT — `ChatSessionViewController.swift:163-168`):** a plain `NSHostingView` claims *all* points in its bounds for hit-testing. Keeping its bounds to just the bar (height from intrinsic size) is what lets the transcript below receive clicks everywhere above the bar. This is a reason to keep the component host tight rather than full-bleed.

---

## 6. `NSHostingController` vs `NSHostingView` — when to use which

(FACT — [NSHostingController](https://developer.apple.com/documentation/swiftui/nshostingcontroller), [NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview), WWDC22; usage corroborated by CCTerm.)

| | `NSHostingController` | `NSHostingView` |
|---|---|---|
| Kind | `NSViewController` | `NSView` |
| Lifecycle | Forwards `viewDidLoad` / `viewWillAppear` / `viewDidAppear` / appearance + size-class changes into the SwiftUI runtime. | No VC lifecycle; just a view. |
| Use for | A full pane / child VC / sheet / popover / modal / window content — anywhere you want proper child-VC containment and lifecycle. | A small embedded view: a cell, a toolbar item, a bar over another view. |
| Window/modal auto-size | Yes — drives window min/max + popover/sheet size via `.preferredContentSize`. | No VC-level sizing; you wire constraints yourself. |
| `sizingOptions` default | `[.minSize, .intrinsicContentSize, .maxSize]` | `[.minSize, .intrinsicContentSize, .maxSize]` |

**CCTerm's split decision matches this guidance (FACT):**
- `ArchiveViewController` uses **`NSHostingController`** because it is a detail *child VC* and the comment notes the controller "forwards `viewDidLoad` / `viewWillAppear` / etc. into the SwiftUI runtime, which `NSHostingView` alone does not." (`ArchiveViewController.swift:10-13`.)
- `ComposeSessionViewController` uses **`NSHostingController`** (full-pane card, `sizingOptions = []`). (`Content/Chat/CLAUDE.md:12`.)
- The chat input bar uses a plain **`NSHostingView`** because it is a *component* over the transcript, not a pane, and needs tight hit-testing bounds. (`ChatSessionViewController.swift:161`, `:163-168`.)

**Rule (INFERENCE):** prefer `NSHostingController` whenever the SwiftUI tree owns a pane/sheet/window or needs lifecycle/appearance forwarding; prefer `NSHostingView` for in-place subviews where you fully own placement and want minimal overhead / tight hit-testing.

---

## 7. First-responder / focus across the boundary

(FACT — WWDC22 "Use SwiftUI with AppKit".)

- SwiftUI views in a host participate in the AppKit responder chain. Use `.focusable()` to make a SwiftUI view focusable, and `.onCommand(...)` / `.onCopyCommand()` / etc. to receive menu/keyboard commands routed through the chain.
- For programmatic first-responder, AppKit's `window.makeFirstResponder(host)` targets the host view; SwiftUI then routes focus to the focusable element (in SwiftUI ≥ macOS 14, `@FocusState` + `.focused(...)` is the in-SwiftUI mechanism). (FACT — WWDC22 + general SwiftUI focus API.)
- CCTerm note: the chat input bar resets its SwiftUI `@State` (including focus) on session switch via `.id(sid)` on `ChatRestingBar`. (FACT — `ChatSessionViewController.swift:648-667`.) This is a focus/state-isolation pattern: changing the SwiftUI identity discards stale focus/text from the previous session.
- CCTerm note: `⌘F` / transcript search first-responder semantics are exactly *why* the toolbar uses AppKit `NSSearchToolbarItem` instead of SwiftUI `.searchable` — `.searchable` doesn't give the first-responder + `⌘F` behavior the transcript needs. (FACT — top-level `CLAUDE.md` architecture section.) This is the canonical "reach for AppKit when SwiftUI's focus story is insufficient" data point.

---

## 8. Safe area

(FACT — WWDC22; [NSHostingController](https://developer.apple.com/documentation/swiftui/nshostingcontroller).)

- The host bridges AppKit's `safeAreaInsets` / `additionalSafeAreaInsets` into the SwiftUI environment so `safeAreaInset` / `.ignoresSafeArea()` behave inside the hosted tree.
- For a fill-a-pane host pinned to its container edges, the SwiftUI content sees the container's safe area; use `.ignoresSafeArea()` deliberately if the hosted content must bleed under chrome.
- CCTerm relevance is low (no inset chrome around these panes), but the general rule stands: **if a hosted pane must extend under a titlebar/toolbar accessory, set `.ignoresSafeArea()` in SwiftUI rather than fighting AppKit constraints.** (INFERENCE.)

---

## 9. Two-way `Binding` across the boundary — gotchas summary

(FACT for the mechanism pieces; INFERENCE for the synthesized guidance.)

1. **It's allowed and idiomatic** — a `Binding` whose `get`/`set` read/write an AppKit-owned `@Observable` model is the standard way to share a single source of truth (CCTerm: `ArchiveViewController.swift:63-66`). Use `[weak self]` in both closures to avoid retaining the VC from the SwiftUI tree (FACT — `:64-65`).
2. **Update timing is asynchronous to the writer.** An AppKit-side write to the model does **not** reach the SwiftUI body in the same runloop tick; bodies re-evaluate in `beforeWaiting`. (FACT — CCTerm `CLAUDE.md` §"macOS runloop tick model": *"`@Observable` writes don't reach SwiftUI bodies in the same tick."*) Don't read the model from a SwiftUI view immediately after an AppKit write expecting the new value.
3. **Re-layout loop risk only under a leaking sizing regime.** Each binding-driven body re-eval re-queries the content's ideal size (per-update cost is documented). If the host has `.intrinsicContentSize` and is a *fill* host, that republishes a bad fitting size every update — the §3 amplification. Severing the leak (`sizingOptions = []`) removes the loop. (INFERENCE + FACT [sizingOptions] per-update query.)
4. **No infinite ping-pong from a well-formed `Binding`.** A `Binding` whose `set` writes the same `@Observable` the `get` reads does not oscillate — SwiftUI coalesces and only re-evaluates on actual value change. The danger is *layout* republish (point 3), not value ping-pong. (INFERENCE.)

---

## Sources

Apple primary:
- NSHostingSizingOptions — https://developer.apple.com/documentation/swiftui/nshostingsizingoptions
- NSHostingController.sizingOptions — https://developer.apple.com/documentation/swiftui/nshostingcontroller/sizingoptions
- NSHostingController.preferredContentSize — https://developer.apple.com/documentation/swiftui/nshostingcontroller/preferredcontentsize
- NSHostingController — https://developer.apple.com/documentation/swiftui/nshostingcontroller
- NSHostingView — https://developer.apple.com/documentation/swiftui/nshostingview
- NSHostingSizingOptions.intrinsicContentSize — https://developer.apple.com/documentation/swiftui/nshostingsizingoptions/intrinsiccontentsize
- WWDC22 "Use SwiftUI with AppKit" — https://developer.apple.com/videos/play/wwdc2022/10075/

Community (high-signal, used to establish the default-set fact + the collapse mechanism):
- Brian Webster, "How NSHostingView determines its sizing" — https://www.tumblr.com/brian-webster/723846294121152512/how-nshostingview-determines-its-sizing
- Michael Tsai blog mirror/discussion — https://mjtsai.com/blog/2023/08/03/how-nshostingview-determines-its-sizing/
- vbat.dev, "Adapting UIHostingController to changes in SwiftUI View size" — https://vbat.dev/adapting-uihostingcontroller-to-changes-in-swiftui-view-size

CCTerm code & docs:
- `macos/ccterm/Content/Archive/ArchiveViewController.swift:63-111` (binding + `sizingOptions = []` + 4-edge pin + measured `545×276` leak)
- `macos/ccterm/App/AppKit/ChatSessionViewController.swift:161-208`, `:648-676` (input bar host: `.intrinsicContentSize`, centerX + capped width, hit-testing, `.id(sid)` focus reset)
- `macos/cctermTests/DetailRouterLayoutDiagnosticsTests.swift:92-164` (large-window collapse probe, 1200×860)
- top-level `CLAUDE.md` §"Embedding SwiftUI in AppKit: host sizing" and §"macOS runloop tick model"
- `macos/ccterm/Content/Chat/CLAUDE.md:11-12` (per-VC host-sizing notes)

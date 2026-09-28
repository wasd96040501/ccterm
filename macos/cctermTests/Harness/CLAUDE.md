# AppKit verification harness

`Harness/` is the scaffold for **self-verifying AppKit layout, geometry,
animation, and complex interaction** without launching the app. Mount a
real production view tree off-screen, then sample its geometry / drive
real events / probe its animation curve and assert on the result. It runs
on the default `make test-unit` suite + CI (assertion-driven merge gates,
not PNG snapshots).

> **Real objects only.** The factories assemble production types —
> `mainSplit` mounts the real `MainSplitViewController` exactly as
> `MainWindowController` builds it. Nothing is mocked at the controller
> layer; when a tree needs state, its factory injects per-stage in-memory
> dependencies through the production init seams. This is the same
> engineering rule as the rest of the repo (root `CLAUDE.md` → "Never
> compromise production code to make tests pass"): the test adapts to the
> product, not the reverse.

## The pieces

| File | Role |
|---|---|
| [`AppKitStage.swift`](AppKitStage.swift) | Off-screen mount + runloop control (`settle` / `drainUntil` / `sourcePhase`) + `find<T>` subview lookup. The generic `mount(vc:)` entry. |
| [`AppKitStageFactories.swift`](AppKitStageFactories.swift) | Real-tree factories (`mainSplit`) and queries against what they built (`sidebarWidth` / `detailPaneWidth`). |
| [`Geometry.swift`](Geometry.swift) | Region/position assertion vocabulary (`assertContained` / `assertNoOverlap` / `assertCenteredX` / `assertBottomAnchored` / `assertAligned` / `assertWidth` / `assertWithinViewport`) in a chosen ancestor coordinate space, with tolerance + readable diagnostics. |
| [`AnimationProbe.swift`](AnimationProbe.swift) | `CADisplayLink` per-frame sampler of any view's `layer.presentation()` frame/opacity → an assertable `Timeline` (`assertOpacity` monotonic, `assertNoJump`, `assertFinalOpacity`). |
| [`InteractionDriver.swift`](InteractionDriver.swift) | Real hit-test routing (`hitTest(at:from:)`, `enclosing`) and the pre-post recipe for gestures that enter AppKit's event-tracking loop. |

## How to add a test for a new component

Three steps; you touch only the high-level API.

1. **Pick a factory.** The main window's content → `AppKitStage.mainSplit(...)`.
   Anything else → `AppKitStage.mount(myRealVC, size:)`; when a component
   gets a real-tree test of its own, add a factory for it here.
2. **`stage.find(SomeView.self)`** to locate the target in the real tree.
3. **Assert** with `Geometry` / `AnimationProbe`, or **drive** with
   `stage.driver`.

```swift
@MainActor
final class MyComponentTests: XCTestCase {
    func testLayout() async throws {
        let stage = AppKitStage.mainSplit()
        defer { stage.teardown() }
        await stage.settle()

        let view = try XCTUnwrap(stage.find(MyView.self))
        Geometry.assertContained(view, in: stage.rootView)
    }
}
```

Worked example: [`MainSplitLayoutTests`](../MainSplitLayoutTests.swift).

## Window size

Factories default to `AppKitStage.defaultWindowSize` = **1200×860**, the
main window's first-launch content size (source:
`MainWindowController.init` `contentRect` — the baseline most users run
at). Override per call for edge cases; `AppKitStage.minWindowSize`
(880×540) is the production `window.minSize` for narrow-pane tests. The
size constants are sourced from production, not magic numbers — if the
window default changes, update them here.

## Parallel safety

A factory whose tree needs state builds it per stage — a `UserDefaults`
suite keyed on a UUID, a temp directory — and registers its disposal as a
cleanup that `teardown()` runs. No factory touches `~/.claude`, a `.shared`
instance or `UserDefaults.standard`, so stages are safe under XCTest's
per-class process parallelism (see [`../CLAUDE.md`](../CLAUDE.md)).

## What it CANNOT observe (off-screen / non-key-window limits)

The window sits at `(-30_000, -30_000)` with `alphaValue = 0.01` and never
becomes key. So this harness is a geometry / layout / animation-curve /
hit-test reachability gate — **not** an end-to-end UI automation
replacement. Out of reach:

- **Key-window / first-responder behavior.** `NSTrackingArea` hover
  (`.activeInKeyWindow`), selection-highlight key-window tinting, cursor
  rects / flashing, focus ring. A test that needs these must run the app.
- **The real `NSApp.nextEvent(.eventTracking)` drag loop.** Pre-posting
  the dragged + up events (see `InteractionDriver`) lets the loop drain
  synchronously — a faithful approximation of the gesture's *outcome*,
  but not live hardware event delivery.
- **Live render-server scheduling under load / occlusion.**
  `AnimationProbe` samples `presentation()` — which returns post-flush
  values in this offscreen setup — but the render server can delay
  compositing a busy/occluded window in ways a quiet test environment
  won't reproduce.

When a user-reported visual glitch does **not** reproduce here, that's a
signal the bug lives in one of the above layers — expand the probe
(sample more dimensions) or reach for a live-window scaffold before
declaring it falsified.

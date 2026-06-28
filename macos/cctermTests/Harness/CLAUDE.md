# AppKit verification harness

`Harness/` is the scaffold for **self-verifying AppKit layout, geometry,
animation, and complex interaction** without launching the app. Mount a
real production view tree off-screen, then sample its geometry / drive
real events / probe its animation curve and assert on the result. It runs
on the default `make test-unit` suite + CI (assertion-driven merge gates,
not PNG snapshots).

> **Real objects only.** The factories assemble production types
> (`MainSplitViewController` → real `SidebarViewController` + real
> `DetailRouterViewController` + real `SessionManager`) with in-memory,
> per-stage dependencies. Nothing is mocked at the controller layer — to
> test sidebar↔transcript linkage you drive the *real* sidebar and the
> *real* router, never a stand-in. This is the same engineering rule as
> the rest of the repo (`../../CLAUDE.md` → "Never compromise production
> code to make tests pass"): the test adapts to the product, not the
> reverse.

## The four pieces

| File | Role |
|---|---|
| [`AppKitStage.swift`](AppKitStage.swift) | Off-screen mount + runloop control (`settle` / `drainUntil` / `sourcePhase`) + `find<T>` subview lookup. The generic `mount(vc:)` entry. |
| [`AppKitStageFactories.swift`](AppKitStageFactories.swift) | Real-tree factories (`mainSplit` / `detailRouter`) with parallel-safe in-memory deps + `SessionSpec` seeding; `sidebarWidth` / `detailPaneWidth` queries. |
| [`Geometry.swift`](Geometry.swift) | Region/position assertion vocabulary (`assertContained` / `assertCenteredX` / `assertBottomAnchored` / `assertAligned` / `assertWidth` / `assertWithinViewport`) in a chosen ancestor coordinate space, with tolerance + readable diagnostics. |
| [`AnimationProbe.swift`](AnimationProbe.swift) | `CADisplayLink` per-frame sampler of any view's `layer.presentation()` frame/opacity → an assertable `Timeline` (`assertOpacity` monotonic, `assertNoJump`, `assertFinalOpacity`). |
| [`InteractionDriver.swift`](InteractionDriver.swift) | Synthesized real interactions — `selectSidebarRow` (real outline write-back), `dragSelectVisibleRow` (synthesized `NSEvent` through real `hitTest`/`mouseDown`), `hitTest` / `enclosing` resolution. |

## How to add a test for a new component

Three steps; you touch only the high-level API.

1. **Pick a factory.** Sidebar↔detail linkage → `AppKitStage.mainSplit(...)`.
   Router/chat/transcript only → `AppKitStage.detailRouter(...)`. Anything
   else → `AppKitStage.mount(myRealVC, size:)`.
2. **`stage.find(SomeView.self)`** to locate the target in the real tree.
3. **Assert** with `Geometry` / `AnimationProbe`, or **drive** with
   `stage.driver`.

```swift
@MainActor
final class MyComponentTests: XCTestCase {
    func testLayout() async throws {
        let fx = AppKitStage.mainSplit(
            sessions: [.init(title: "A"), .init(title: "B")], initialIndex: 0)
        defer { fx.teardown() }
        await fx.stage.settle()

        let bar = (fx.stage.router?.currentChild as? ChatSessionViewController)!.restingBarHost!
        Geometry.assertCenteredX(bar, in: bar.superview!)
        Geometry.assertContained(bar, in: bar.superview!)
    }
}
```

Worked examples: [`MainSplitLinkageTests`](../MainSplitLinkageTests.swift)
(layout/region + real sidebar→transcript switch) and
[`DetailPaneTranscriptHitTestTests`](../DetailPaneTranscriptHitTestTests.swift)
(synthesized drag-select + permission-card passthrough).

## Window size

Factories default to `AppKitStage.defaultWindowSize` = **1200×860**, the
main window's first-launch content size (source:
`MainWindowController.init` `contentRect` — the baseline most users run
at). Override per call for edge cases; `AppKitStage.minWindowSize`
(880×540) is the production `window.minSize` for narrow-pane tests. The
size constants are sourced from production, not magic numbers — if the
window default changes, update them here.

## Parallel safety

Every factory builds a fresh `InMemorySessionRepository`, a `UserDefaults`
suite keyed on a UUID, and a temp `InputDraftStore` directory, disposed by
`teardown()`. No factory touches `CoreDataSessionRepository`,
`SessionManager.shared`, `~/.claude`, or `UserDefaults.standard` — so
stages are safe under XCTest's per-class process parallelism (see
[`../CLAUDE.md`](../CLAUDE.md)). The DI seam that makes this possible is
`AppState.init`'s `nil`-defaulted parameters: production calls `AppState()`
unchanged; the harness injects the in-memory stores.

## What it CANNOT observe (off-screen / non-key-window limits)

The window sits at `(-30_000, -30_000)` with `alphaValue = 0.01` and never
becomes key. So this harness is a geometry / layout / animation-curve /
hit-test reachability gate — **not** an end-to-end UI automation
replacement. Out of reach:

- **Key-window / first-responder behavior.** `NSTrackingArea` hover
  (`.activeInKeyWindow`), selection-highlight key-window tinting, cursor
  rects / flashing, focus ring. A test that needs these must run the app.
- **The real `NSApp.nextEvent(.eventTracking)` drag loop.**
  `InteractionDriver.dragSelectVisibleRow` pre-posts the dragged + up
  events so the loop drains synchronously — a faithful approximation of
  the gesture's *outcome*, but not live hardware event delivery.
- **Live render-server scheduling under load / occlusion.**
  `AnimationProbe` samples `presentation()` — verified to return
  post-flush values in this offscreen setup — but the render server can
  delay compositing a busy/occluded window in ways a quiet test
  environment won't reproduce.

When a user-reported visual glitch does **not** reproduce here, that's a
signal the bug lives in one of the above layers — expand the probe
(sample more dimensions: scroller knob, not just clip origin) or reach for
a live-window scaffold before declaring it falsified. See the transcript
snapshot tests' notes in [`../CLAUDE.md`](../CLAUDE.md) for prior art on
this exact lesson.

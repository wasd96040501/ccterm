# Unit tests

`cctermTests` is the only test target. Two kinds of tests live here:

1. **Pure-logic tests** — bridge dispatch, history parsing,
   block-builder output, session-handle state transitions. Most tests
   are this kind. Click / keystroke / focus flows are covered by
   driving the handle / bridge / controller directly — there is no
   XCUITest target.

2. **View snapshot tests** — render a real SwiftUI view through
   `NSHostingController` into an offscreen window and attach a PNG to
   the xcresult. **For human review and PR diff context, not a
   pixel-diff regression gate.** See [Snapshot tests](#snapshot-tests)
   below before adding one.

## Parallel execution: hard rules

XCTest runs unit tests **in parallel across `XCTestCase` classes**, each in
its own forked process. The runner picks worker count automatically; CI
forces 4 (see `scripts/test-unit.sh`). Methods inside the same class still
run sequentially.

This is fast — but only if no test can observe another's side effects. Two
tests writing to `~/.claude/projects/foo.jsonl` race; two tests sharing a
`SessionManager` race; two tests calling `CoreDataStack.shared` race.

### Required practices

1. **Per-test in-memory dependencies.** Build a fresh
   `InMemorySessionRepository` (or a fresh `CoreDataStack(inMemory: true)`
   if you need the real CoreData layer) inside `setUp` /
   `setUpWithError`. Never reach for `CoreDataStack.shared`,
   `SessionManager.shared`, or any other process-wide singleton.

2. **Unique on-disk artifacts.** When a test must hit the filesystem
   (e.g. a JSONL file for `loadHistory(overrideURL:)`), write it under
   `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)`
   and clean up in `tearDownWithError`. Never write to a hardcoded `/tmp/foo.jsonl`
   path. Never write to `~/.claude` or `~/.cache/ccterm`.

3. **No `UserDefaults` reads / writes.** If a behavior depends on a
   default, inject the value at the call boundary instead of reading from
   `UserDefaults.standard`.

4. **No `NotificationCenter.default.post`.** Posts on the default center
   would leak across parallel test processes if they happened to share a
   notification name. Use a dedicated `NotificationCenter()` instance
   when a test exercises notification routing.

5. **`@MainActor func testXxx() async` is OK.** The handle and bridge are
   `@MainActor`-isolated; tests touching them should run on the main
   actor. Parallel-safety is enforced at the **process** level (separate
   fork per class), so a `@MainActor` test is safe — it just can't share
   a `MainActor.run`-captured object with a sibling class in the same
   process (and there isn't one — each class is its own process).

6. **No `sleep` / `Task.sleep` for synchronization.** Use
   `XCTestExpectation`, `await`, or `XCTNSPredicateExpectation` to wait
   for a condition. Sleeping is fragile under CI load.

### Quick recipe — bridge / handle test

```swift
import XCTest
@testable import ccterm

@MainActor
final class MyBridgeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSomething() throws {
        let repo = InMemorySessionRepository()
        let handle = SessionRuntime(sessionId: UUID().uuidString, repository: repo)
        // ... drive handle, assert on its state ...
    }
}
```

For JSONL replay tests, write a temp file:

```swift
let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(UUID().uuidString).jsonl")
try jsonlText.write(to: url, atomically: true, encoding: .utf8)
addTeardownBlock { try? FileManager.default.removeItem(at: url) }
handle.loadHistory(overrideURL: url)
```

## What goes here

| Scenario | Approach |
|---|---|
| Block builder produces correct ids for a parsed entry | Call the builder, assert on its output |
| `Session.loadHistory` backfills a JSONL file into the controller | Drive the `TranscriptBackfillPipeline` (real or `FakeReversePageSource`), await `historyLoadState == .loaded`, assert `controller.blockIds` |
| Bridge applies `.appended` / `.updated` → controller's blockIds match | Construct the bridge + controller, feed a `MessagesChange`, assert controller state |
| Send-button enable state under various input | Drive `SessionRuntime.send` and inspect `isRunning` / `status` directly |
| Sidebar selection routes to the right handle | Hold the manager, simulate the selection change in code, assert the resulting handle |
| "What does this view look like today?" — visual review of a SwiftUI view | [Snapshot tests](#snapshot-tests) |

If a test feels like it wants to "click a button," reach for the
underlying method the button would invoke. The button click is `handle.send(...)`;
the keystroke is `controller.handleKey(...)`. Test those.

## Smoke tests (real `claude` CLI)

Smokes are **not** XCTests — they live as `executableTarget`s in
`macos/AgentSDK` and run via `swift run`. They were originally
`*SmokeTests.swift` files in this folder, but XCTest's host-app
bundle-load triggers `CCTermApp` startup (including `GitProbe.loadHeavy`
which can hang on misbehaving git folders), making the smoke take
~6+ minutes to fail even when the smoke code itself is fine.
Standalone executables bypass the host-app entirely.

```bash
cd macos/AgentSDK
swift run DumpSmoke                      # one turn, dump JSONL + counts
SMOKE_SCENARIO=bgjob swift run DumpSmoke # background-bash post-result drain
swift run InterruptSmoke                 # interrupt mid-stream and report
                                         #   whether the CLI's user echo
                                         #   arrives AFTER our interrupt
                                         #   (the bug-trigger condition)
```

Env: `CLAUDE_BINARY_PATH` (override path), `SMOKE_MODEL`
(default `claude-haiku-4-5`), `SMOKE_PROMPT`, plus
`INTERRUPT_AFTER_MS` (default 1500) for `InterruptSmoke`.

Each smoke creates its work directory under
`/tmp/ccterm-{dump,interrupt}-smoke-<timestamp>/` and writes the CLI's
exported JSONL to `…/export/`. Both are kept after the run so you can
inspect them.

## Snapshot tests

Render a real SwiftUI view through `NSHostingController` into an
offscreen, alpha-0.01 window, capture the backing-store bitmap, write
a PNG under `/tmp/ccterm-screenshots/`, and attach it to the xcresult.
For **visual review only** — no golden-image diff, no CI gate.

> **You changed a view and want to see how it renders right now —
> skip to [I want to verify a view change](#i-want-to-verify-a-view-change).**

### Existing snapshot tests

Inventory — these are the views currently wired up. To verify any of
them: `make test-unit FILTER=<class>` then `open <png>`.

| View | Test class | PNG |
|---|---|---|
| `TranscriptDemoViewController` ([source](../ccterm/Content/TranscriptDemo/TranscriptDemoViewController.swift)) | `TranscriptDemoSnapshotTests` ([source](TranscriptDemoSnapshotTests.swift)) | `/tmp/ccterm-screenshots/TranscriptDemoView.png` |
| `SidebarViewController` source-list sidebar + per-row state indicators ([source](../ccterm/Sidebar/SidebarViewController.swift)) | `SidebarView2SnapshotTests` ([source](SidebarView2SnapshotTests.swift)) | `/tmp/ccterm-screenshots/SidebarView2.png` |
| `NewSessionConfigurator` three-column compose card ([source](../ccterm/Content/Chat/NewSessionConfigurator.swift)) | `NewSessionConfiguratorSnapshotTests` ([source](NewSessionConfiguratorSnapshotTests.swift)) | `/tmp/ccterm-screenshots/NewSessionConfigurator.png` + `…-empty.png` |
| `DiffView` standalone diff card (modified + new file) ([source](../ccterm/Components/DiffView.swift)) | `DiffViewSnapshotTests` ([source](DiffViewSnapshotTests.swift)) | `/tmp/ccterm-screenshots/DiffView.png` |
| Transcript attach sequence — first-frame scroll origin / row geometry ([source](../ccterm/Content/Chat/NativeTranscript2/AppKit/TranscriptScrollViewFactory.swift)) | `TranscriptScrollFirstFrameSnapshotTests` ([source](TranscriptScrollFirstFrameSnapshotTests.swift)) | `/tmp/ccterm-screenshots/TranscriptScrollFirstFrame-Production.png` + `…-NoNote.png` |
| Transcript attach sequence — first **composited** frame on a live render pipeline (CADisplayLink + `CALayer.presentation()`) ([source](../ccterm/Content/Chat/NativeTranscript2/AppKit/TranscriptScrollViewFactory.swift)) | `TranscriptScrollLivePresentationSnapshotTests` ([source](TranscriptScrollLivePresentationSnapshotTests.swift)) | none — text-only timeline attachment |

If your view isn't in this table, jump to [I want to add a snapshot
test for a new view](#i-want-to-add-a-snapshot-test-for-a-new-view).

### Measurement probes (NOT snapshots — CI merge gate)

Some tests use the same offscreen-window scaffolding as snapshots —
they mount a real view, drive a real attach sequence, sample state —
but they're **assertion-driven property tests**, not PNGs for human
review. They have to run on CI as merge gates. **Do not give them the
`*SnapshotTests.swift` filename suffix** — `scripts/test-unit.sh`
auto-skips that pattern from the default suite.

Inventory:

| File | What it asserts |
|---|---|
| [`TranscriptReentryLayoutCacheTests.swift`](TranscriptReentryLayoutCacheTests.swift) | The bare `TranscriptScrollViewFactory.make → addSubview → layoutSubtreeIfNeeded → bindData → scrollToTail` sequence typesets each block at exactly one width inside one source-phase tick. |
| [`TranscriptHostReentryLayoutCacheTests.swift`](TranscriptHostReentryLayoutCacheTests.swift) | Same property, but driven through real hosts: the AppKit demo VC (`TranscriptDemoViewController`) and the production sidebar-switch path (`TranscriptDetailViewController.attachSession` on a `MainSelectionModel.selection` flip). Closes the gap between the factory test and host orchestration. |
| [`TranscriptBackfillLayoutCacheTests.swift`](TranscriptBackfillLayoutCacheTests.swift) | **U1** — the single-width contract extended across multi-tick backfill: a real `TranscriptBackfillPipeline` cold-load (tail `.append` + several `.prepend` ticks) typesets each block at exactly one width and exactly once. Prepend ticks are cache hits (off-main precompute, 5b); a width-mismatched producer shows up as a second write at a second width. |
| [`TranscriptBackfillAnchorTests.swift`](TranscriptBackfillAnchorTests.swift) | **U2/U3/U7/U8** — anchor invariant (prepend pins the visual-top row, clip shifts by the inserted height, no jitter over N ticks); in-tick stability (anchor correct before any runloop drain — the deleted `mutationCounter` regression); `.update`/`.replace` riding `.saveVisible` preserve the viewport mid-document; interleaved tail-append + head-prepend land at opposite ends without moving the anchor. |
| [`TranscriptColdAttachTests.swift`](TranscriptColdAttachTests.swift) | **U4/U5/U6** — cold attach renders 0 rows then lands the tail page at the bottom; `blocks.count == numberOfRows` after every change in a mixed `prepend`/`append`/`replace`/`remove`/`update` sequence; warm re-entry into a `.loaded` session fires zero backfill typeset. |

All four reuse the offscreen-window scaffold; the three backfill probes share the [`Helpers/MountedTranscript.swift`](Helpers/MountedTranscript.swift) mount + geometry-sampling helper.

When you add a new test that's "drive a real view + assert on a property at the boundary," follow these naming rules:

- Filename: `<Subject>Tests.swift` (e.g. `TranscriptHostReentryLayoutCacheTests.swift`) — no `Snapshot` suffix.
- Class name must match the filename (XCTest's runtime discovery + the skip-list script both key off the file name).
- Attachment: text reports via `XCTAttachment(string:)` are fine; a PNG is fine if it helps debugging. The test passes / fails on `XCTAssert`, not on the human eyeball.
- Don't reuse the snapshot test infrastructure's `ViewSnapshot.render` if your test only needs to assert on model state — that helper carries a long deliberate runloop drain that you usually don't want.

### Probing AppKit attach sequences offscreen

`TranscriptScrollFirstFrameSnapshotTests` is a different shape from the
SwiftUI snapshot tests above and worth understanding before you write
your own. It's a measurement harness: it drives the exact AppKit attach
sequence used in production (`TranscriptScrollViewFactory.make` →
`addSubview` + constraints → `view.layoutSubtreeIfNeeded()` →
`TranscriptScrollViewFactory.bindData` → `controller.scrollToTail()`)
inside an offscreen window, and samples state —
`clip.bounds.origin.y`, `documentView.frame.height`, `numberOfRows`,
`rect(ofRow:)` — at four named transition points: after factory.make,
after layoutSubtreeIfNeeded+bindData, after scrollToTail (still source
phase), and after one runloop drain. Each measurement is attached to the
xcresult as a text report alongside a final-frame PNG.

What this scaffold is good for:

- Asserting on **model state** that a one-tick visual glitch should
  show up in — clip origin, document height, row geometry — without
  launching the app.
- A/B'ing two variants of the same attach sequence: one with the
  production factory, one with a duplicated factory-minus-some-call.
- Verifying tick-model claims — `testTickModelLayoutDoesForceRowTileOnFrameChange`
  examines whether `layoutSubtreeIfNeeded` cascades into NSTableView's
  tile (it does, but only when `dataSource` is bound — the production
  factory now defers that bind, which is exactly the point this test
  is calibrated against).

What it **cannot** observe:

- **Live-window render-pipeline timing.** The PNG comes from
  `bitmapImageRepForCachingDisplay`, which is a synchronous re-draw,
  not an actual frame the render server composited. If the bug is
  "the rendered first frame on a live window paints stale because the
  prior CATransaction commit was already in flight," this scaffold
  will pass while the live app still glitches. For that class of bug,
  reach for the live-presentation scaffold below.
- Anything that needs a key window / first responder / cursor flashing
  — the test window has `alphaValue = 0.01` and goes through
  `ccterm_orderFrontForTesting()` which skips the responder activation.

### Probing the live render pipeline — display-link + `CALayer.presentation()`

`TranscriptScrollLivePresentationSnapshotTests` is the next rung up.
Same fixture as the offscreen scaffold above, plus a `CADisplayLink`
attached to `NSScreen.main` that samples
`(clip.bounds.origin.y, clip.layer?.presentation()?.bounds.origin.y)`
on every screen refresh tick for ~30 frames. The first sample where
`presentation` is non-nil is the first frame the render server actually
composited — its origin is what a user would have seen.

The display link runs off `NSScreen.main` (not `NSView.displayLink`) on
purpose: the view's own link only fires when the view is visible on a
screen, but the test window is at `(-30_000, -30_000)` with `alphaValue
= 0.01`. The screen-level link fires unconditionally at the screen's
refresh rate, which is what we want — we're sampling state every
refresh tick, independent of whether the render server picked our
specific window for compositing. The flush probe (`testCATransactionFlushPresentationTimeline`
in the sibling file) already proved that the render server DOES composite
this window — `presentation()` returns the post-flush value at tail.

This scaffold confirms the **content layer** lands at tail on the first
composited frame — `nil → tail` on consecutive refresh ticks, no
intermediate `top-clamp` frame. That's necessary but not sufficient: an
earlier investigation chased a content-origin hypothesis here and missed
the real bug, which lived in
`NSScrollView.verticalScroller.doubleValue` (the scroller-knob
position, *not* the clip origin). The lesson is general: when a
user-reported visual glitch doesn't reproduce here, expand the sampled
dimensions before declaring the bug falsified. See
`TranscriptScrollFirstFrameSnapshotTests.testScrollerKnobLandsAtTailAfterScrollToTail`
for the scroller-knob regression gate that caught it.

What this scaffold **still can't** observe:

- **NSScrollView non-content state.** The scroller's `doubleValue` /
  `knobProportion` / fade-in alpha are separate dimensions; sample them
  explicitly if a glitch is reported in the chrome (the sibling test
  above does this).
- **Production sibling-view interactions.** In the real app the same
  attach tick also lays out the top scrim, bottom scrim, and compose
  host (all `NSHostingView`s). Any of those committing on the same
  CATransaction could perturb timing in ways the bare-scroll harness
  doesn't reproduce. To rule this out you would need to host
  `TranscriptDetailViewController` directly in a test window — feasible
  but a larger lift.
- **WindowServer scheduling under load.** The render server can delay
  compositing a window if its parent process is busy on the GPU /
  another window is occluding etc. None of those reproduce in a quiet
  test environment.

### Run policy — opt-in only

Snapshot tests do **not** execute on the default-all suite (locally or
on CI). The runner discovers any file named `*SnapshotTests.swift`
and injects `-skip-testing:<ClassName>` when `FILTER` is empty. Files
stay in the test target so they're still **compiled** — bit-rot fails
at build time, not at runtime.

```bash
make test-unit                                                   # snapshot tests SKIPPED
make test-unit FILTER=TranscriptDemoSnapshotTests                # runs
make test-unit FILTER=TranscriptDemoSnapshotTests/testFoo        # runs (one method)
```

Filename ↔ class name **must match** — the skip injection keys off
the filename. `TranscriptDemoSnapshotTests.swift` must contain
`class TranscriptDemoSnapshotTests`. Split files if you need multiple
classes.

---

### I want to verify a view change

Use this when you've edited a SwiftUI view and want a screenshot of
how it renders, without launching the app.

1. Find your view in the [Existing snapshot tests](#existing-snapshot-tests) table.
2. Run the test and open the PNG:

   ```bash
   make test-unit FILTER=TranscriptDemoSnapshotTests
   open /tmp/ccterm-screenshots/TranscriptDemoView.png
   ```

3. Look at the PNG. It's a real render under the test's fixture —
   what you see is what a user sees after that view loads.
4. If the view isn't in the table, **add one**: go to
   [I want to add a snapshot test for a new view](#i-want-to-add-a-snapshot-test-for-a-new-view).
5. If the PNG looks wrong, see [Troubleshooting](#troubleshooting).

> **Why not just run the app?** Snapshots run in seconds, don't steal
> focus, and capture deterministic fixture state — good for
> tight-loop iteration while polishing a layout. Run the app for
> interactive flows.

---

### I want to add a snapshot test for a new view

Use this when the view you changed isn't yet in the inventory.

**Decisions to make first** (1 minute of reading the view):

- **How does the view get its initial state?**
  - If state is passed in via `init` already → straightforward.
  - If state is seeded in `.task` / `.onAppear` → those won't fire
    reliably in an offscreen hosted-test window. **You'll need a
    test seam**: an additional `init(controller:)` / `init(state:)`
    overload that accepts a pre-built state object. Default init
    stays the same; production behavior unchanged. See [Production
    code rules](#production-code-rules) below.
- **What constants does production seed from?** You'll reuse them
  verbatim. If they're `fileprivate` static lets, widen to `internal`
  — access modifier only, no logic change.
- **What does the view pull from `.environment(...)`?** You'll need to
  inject fresh in-memory instances (never `*.shared`).

**Then do this:**

1. Create `macos/cctermTests/<ViewName>SnapshotTests.swift` (file
   name **must** match the class name; the runner skips by filename).
2. Copy the [template](#template) below.
3. Replace `MyView`, `MyController`, fixture constants, and the
   environment injections with your view's.
4. Run it: `make test-unit FILTER=<YourClass>`.
5. `open /tmp/ccterm-screenshots/<name>.png` — inspect the actual
   bitmap. CI won't catch a wrong-but-non-empty render; **you must
   look at it**.
6. Add a row to the [Existing snapshot tests](#existing-snapshot-tests)
   table in this file so the next person finds it.

### Template

Drop this in `macos/cctermTests/MyViewSnapshotTests.swift` and edit
the marked spots.

```swift
import AppKit
import SwiftUI
import XCTest

@testable import ccterm

@MainActor
final class MyViewSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDefaultState() throws {
        // 1. Seed state the same way production's .task would.
        //    Reuse production constants (widen `fileprivate` → `internal`
        //    if needed — access modifier only).
        let controller = MyController()
        controller.loadInitial(MyView.initialFixture)

        // 2. Mount via the test-seam init; inject fresh environment.
        let view = MyView(controller: controller)
            .environment(\.syntaxEngine, SyntaxHighlightEngine())

        // 3. Render → write → attach.
        let image = ViewSnapshot.render(
            view, size: CGSize(width: 720, height: 720))
        let url = ViewSnapshot.writePNG(image, name: "MyView")

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "MyView.png"
        attachment.lifetime = .keepAlways  // survives in xcresult
        add(attachment)

        // 4. Plausibility only — no golden-image comparison.
        XCTAssertGreaterThanOrEqual(image.size.width, 700)
        // Optional non-uniform check: see TranscriptDemoSnapshotTests.isUniform
    }
}
```

The helper functions are in [Helpers/ViewSnapshot.swift](Helpers/ViewSnapshot.swift) — don't reinvent.

### Production code rules

The point of snapshotting the real view is fidelity, so view
behavior cannot drift to make tests work.

| Allowed (no behavior change) | Forbidden |
|---|---|
| Adding a secondary initializer `init(controller: SomeController? = nil)` so tests can inject pre-built state. Default init unchanged. | `#if DEBUG` UI variants, env-var-gated layout / styling |
| Widening `fileprivate` → `internal` on a static `let` fixture the test reuses verbatim (same bytes, modifier only) | `forceXxxForTest()` methods, exposing mutable internals for assertion |
| Reading the same constants production's `.task` reads | Test-only seed paths that diverge from production fixture data |

If the seam you need doesn't fit the "Allowed" column, snapshot is
the wrong tool — assert on the underlying handle / controller
instead.

### Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| PNG is a single flat color | `.task` / `.onAppear` never ran offscreen, controller is empty | Seed manually via the test-seam init (see [add a snapshot test](#i-want-to-add-a-snapshot-test-for-a-new-view) step 1) |
| PNG is mostly empty but right-sized | `settle` too short — async layout hadn't landed | Bump `settle:` from default `0.4` to `0.6`–`1.0` |
| Test crashes in `bitmapImageRepForCachingDisplay returned nil` | `size` too small or zero | Pass a size ≥ the view's `minFrame` (typically ≥ 320×240) |
| Window flashes onscreen during local runs | Window suppression bypassed | Always go through `ViewSnapshot.render` — it uses `ccterm_orderFrontForTesting()` which keeps the swizzle scoped |
| Want to diff against a saved image | Not supported here | Snapshot tests are review-only by design. Propose golden-image infra explicitly before adding it |
| Want to test a click / scroll / focus transition | Wrong tool | Drive `handle` / `controller` / bridge directly in a logic test |
| View depends on `*.shared` singleton | Singleton leaks across parallel tests | Inject an in-memory replacement via `.environment(...)` (see [Parallel execution](#parallel-execution-hard-rules)) |
| Test ran in CI but I want to see the CI-side PNG | CI skips snapshot tests entirely | Reproduce locally — CI cannot render them. If a CI-only metric matters, propose a one-off workflow change explicitly |

## Running

```bash
# Run everything in cctermTests (parallel by class):
make test-unit

# Filter to one class:
make test-unit FILTER=MessageEntryBlockBuilderTests

# Filter to one method:
make test-unit FILTER=MessageEntryBlockBuilderTests/testAssistantTextProducesParagraph
```

Unit tests do not steal focus and are safe to run locally during normal
development.

## CI

The `test` workflow (`.github/workflows/test.yml`) runs `make test-unit`
on every PR and push to `main`. DerivedData under `macos/build/test-dd`
is cached across runs so incremental builds reuse `.swiftmodule` /
`.o` outputs. On failure, the `xcresult` bundle is uploaded as a
workflow artifact for post-mortem.

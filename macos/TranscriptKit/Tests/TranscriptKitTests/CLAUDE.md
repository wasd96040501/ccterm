# TranscriptKitTests

`make test-kit [FILTER=<Class>]` from the repo root (`swift test` in the package). A suite of its own, so the package stays testable without the app.

Almost nothing here is pure logic: the list under the transcript asks its data source and delegate anything only when it lays out or commits. So a test mounts a real `TranscriptView` in a real window (`MountedTranscript` over `TestWindow`) and asserts on geometry and on **what the transcript asked for** — the widths passed to `heightOfRow`, how many times, how many views were built vs recycled (`RecordingHost`). The second kind catches what the screen can't show: a wrong width or a doubled measurement pass.

## Rules

- **The harness has no logic.** Build a window, mount, flush layout, drain the runloop — no branches, no derived expectations, no helper that computes what to assert.
- **Every test first asserts the transcript was provoked** (e.g. `heightWidths` is non-empty). A mount that never lays out makes every later assertion pass on an empty tree.
- **Verify a new test by breaking the code it covers:** short out the production path and check that this test goes red while the others stay green.
- **A test comparing two configurations asserts that they differ** (e.g. that two widths really wrap the documents differently) before asserting on the difference.
- **`settle()` runs one pass on purpose.** Width invalidation lands in the pass that changed the width for every row the list has prepared; a change that needs two passes there has pushed work to a later tick — a visible frame at the old geometry, i.e. a bug. Rows outside it are refreshed on idle turns (ExactList W5); `settleWidthChange()` waits those out.
- **When a test depends on something AppKit or the window server does later, wait for that thing**, not for a pass that usually covers it:
  - The window server lists a window a turn or more after `orderFront`, and queued mouse events are rebuilt from global coordinates — `TestWindow.make` returns only once the window is listed. `MountedTranscript.press` queues the rest of a gesture and asserts it was consumed, so a leftover event fails where it was posted.
  - `viewDidAppear` arrives on a later turn than the one that inserted the view — `EditorAreaTests` waits for the selected tab's appearance before clicking.

## One harness: a window the window server composites

Every test mounts through `TestWindow.make`. The window is **really on screen** — parked off the bottom-left corner of the main display with one point showing, opaque — so the window server composites all of it. It's never made key and the process runs with the `.prohibited` activation policy, so the person at the machine keeps focus.

- Don't mount far off-screen: AppKit defers the first measure there, which tests an ordering no host can rely on (a composited table asks at once).
- Pixel assertions read `WindowCapture.bitmap(of:)` — the composited window cropped to the view, one pixel per point — **not `cacheDisplay`**, which redraws in-process and sets up appearance on the way, hiding appearance bugs.
- **The mount's size is the test's on every machine:** the harness re-sets the frame after init and overrides `constrainFrameRect(_:to:)` so a small screen (CI runners are 1024×768) can't shrink it; assigning a `contentViewController` resizes the window, so re-park afterwards (`TestWindow.park`). SF Symbol metrics snap to the main screen's pixel grid, so `InlineSymbolTests` checks recorded numbers only on a 2x screen.

## `WindowCapture` (ScreenCaptureKit)

`SCShareableContent.currentProcess` (macOS 14.4) lists this process's windows without Screen Recording permission; `SCContentFilter(desktopIndependentWindow:)` captures one.

- Captures fail transiently (`-3811`, invalid transition) on a just-ordered window or back-to-back — a capture orders front, waits two display-link frames, and retries up to 30 times two frames apart.
- Frame waits have a 5 s deadline, then throw `XCTSkip` (a locked or sleeping display presents no frames).
- **One `xctest` process captures at a time, machine-wide.** replayd tells clients apart by executable path, and every test process is the same `xctest`: two that have both touched ScreenCaptureKit evict each other forever and their requests are dropped unanswered — even when one is idle. So a process's first capture takes `/tmp/xctest-screencapturekit.lock` (`flock`) until it exits; a concurrent `make test-kit` waits there. Every ScreenCaptureKit request also has a 10 s deadline and fails as `Unanswered` rather than hanging.

## What a test cannot do here (measured)

- **Start a real drag.** `beginDraggingSession` from a test never ends and stays attached to the real pointer. So `EditorTabBar` splits leaving the bar into `dragWillBegin(tabAt:)` / `dragDidEnd()`, which tests call directly; destinations get a `StubDraggingInfo` through the real `NSDraggingDestination` methods. A drag *along* the bar is plain mouse events.
- **Press a left button through `NSApp.sendEvent`** — it can make the window key. `EditorAreaTests` exercises the event monitor with an other-mouse-down.
- **Click a segment of a constraint-laid-out `NSSegmentedControl`** — the action never fires, and a momentary control won't keep an externally written `selectedSegment`. `FindBarViewTests` presses segments through their accessibility elements.
- **Provoke a real hover** — `xctest` never becomes active, so key-window tracking areas never arm. Call `mouseMoved` directly and assert on the report and the band sublayer.

## Snapshots

`*SnapshotTests` write PNGs to `/tmp/transcriptkit-screenshots/` and are skipped by `make test-kit` unless named with `FILTER`. They assert premises, not pixels — they're for reading, like the demo. A pixel *assertion* is not a snapshot: it runs in the default suite and reads `WindowCapture.bitmap`.

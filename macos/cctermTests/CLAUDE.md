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
`SessionManager2` race; two tests calling `CoreDataStack.shared` race.

### Required practices

1. **Per-test in-memory dependencies.** Build a fresh
   `InMemorySessionRepository` (or a fresh `CoreDataStack(inMemory: true)`
   if you need the real CoreData layer) inside `setUp` /
   `setUpWithError`. Never reach for `CoreDataStack.shared`,
   `SessionManager2.shared`, or any other process-wide singleton.

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
        let handle = SessionHandle2(sessionId: UUID().uuidString, repository: repo)
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
| `SessionHandle2.loadHistory` fires `.reset` with prebuilt blocks | Wire up a closure on the handle, assert it fires with the expected payload |
| Bridge applies `.reset` → controller's blockIds match | Construct the bridge + controller, feed a `MessagesChange`, assert controller state |
| Send-button enable state under various input | Drive `SessionHandle2.send` and inspect `isRunning` / `status` directly |
| Sidebar selection routes to the right handle | Hold the manager, simulate the selection change in code, assert the resulting handle |
| "What does this view look like today?" — visual review of a SwiftUI view | [Snapshot tests](#snapshot-tests) |

If a test feels like it wants to "click a button," reach for the
underlying method the button would invoke. The button click is `handle.send(...)`;
the keystroke is `controller.handleKey(...)`. Test those.

## Snapshot tests

Render a real SwiftUI view through `NSHostingController` into an
offscreen, alpha-0.01 window, capture the backing-store bitmap, and
attach it to the xcresult. Used for **visual review** — PR reviewers
open the xcresult and see what the view looks like under that test's
fixture. We do **not** check golden images in or do bit-for-bit
regression.

### Run policy — opt-in only

Snapshot tests do **not** run on the default-all suite, locally or on
CI. The runner (`macos/scripts/test-unit.sh`) discovers any file
named `*SnapshotTests.swift` and adds `-skip-testing:` for its class
when `FILTER` is empty. They execute only when `FILTER` names them:

```bash
make test-unit                                # snapshot tests SKIPPED
make test-unit FILTER=TranscriptDemoSnapshotTests              # runs
make test-unit FILTER=TranscriptDemoSnapshotTests/testTranscriptDemoSnapshot   # runs
```

Two consequences:

- **CI never gates on a snapshot test.** They're for human review, not
  green-bar enforcement. The `test` workflow runs `make test-unit`
  with no filter, so snapshot tests are skipped there too.
- **Compilation is still gated.** The files are part of the
  `cctermTests` target, so `xcodebuild test` still compiles them —
  bit-rot is caught at build time even when the bodies don't execute.

Filename ↔ class name **must match** — the skip injection is by
filename. `TranscriptDemoSnapshotTests.swift` must contain
`class TranscriptDemoSnapshotTests`. If you split a snapshot file
into multiple classes, give each its own `*SnapshotTests.swift`
file.

### File layout & naming

- File: `macos/cctermTests/<ViewName>SnapshotTests.swift` — flat with
  other test files, no subdirectory. Example:
  [TranscriptDemoSnapshotTests.swift](TranscriptDemoSnapshotTests.swift).
- Class: `<ViewName>SnapshotTests: XCTestCase`, annotated
  `@MainActor`.
- One class per view; one `test…` method per visual state worth
  capturing (`testEmptyState`, `testWithRunningTool`, …).
- Helper: [Helpers/ViewSnapshot.swift](Helpers/ViewSnapshot.swift) —
  exposes `ViewSnapshot.render(_:size:settle:)` and
  `ViewSnapshot.writePNG(_:name:)`. Don't reinvent.
- Output: `/tmp/ccterm-screenshots/` (override with
  `CCTERM_SCREENSHOT_DIR`). **Never** write under the repo — gitignored
  scratch only, plus an `XCTAttachment` with `lifetime = .keepAlways`
  so the bundle survives in xcresult.

### Production-code rules (don't compromise the app for snapshots)

The whole point of snapshotting the real view is fidelity, so the
view's production behavior cannot drift to accommodate the test.

| Allowed | Forbidden |
|---|---|
| A secondary initializer that injects pre-built state (e.g. `init(controller: Transcript2Controller? = nil)`) — default init unchanged, no behavior change | `#if DEBUG` UI variants, env-var-gated layout/styling |
| Widening `fileprivate` → `internal` on a static fixture the test reuses verbatim (access modifier only, same bytes) | `forceXxxForTest()` methods, exposing mutable internals for assertion |
| Reading the same `let` constants the production `.task` would seed from | Adding a test-only seed path that diverges from production seed data |

If the seam you need doesn't fit the "Allowed" column, the snapshot
is the wrong tool — assert on the underlying handle / controller
instead.

### SOP — adding a snapshot test

1. **Identify the seed path.** Read the view. If its initial state
   comes from `.task` / `.onAppear`, that closure will **not fire
   reliably** in an offscreen hosted-test window. The supported fix:
   add an `init(state:)`-style overload that accepts a pre-built state
   holder, leaving the default init alone. The view body stays
   identical; the existing `.task` becomes idempotent on already-seeded
   state.
2. **Mirror production seed data.** In the test, build the state
   object using the **same constants** the production `.task` reads
   (widen their access modifier if needed — see the "Allowed" column).
   Do not invent fixture data that diverges.
3. **Inject services via `.environment(...)`.** Anything the view
   pulls from the environment (`SyntaxHighlightEngine`,
   `SessionManager2`, …) must be supplied as a fresh in-memory
   instance. Never reach for `*.shared`.
4. **Render and attach.** Call `ViewSnapshot.render(view, size:)` at a
   realistic size (≥ the view's `minFrame`). Attach the PNG with
   `XCTAttachment(contentsOfFile: url)` and `lifetime = .keepAlways`.
5. **Plausibility assertions only.** Check the bitmap exists, has the
   expected dimensions, and is not a single flat color. Do **not**
   compare to a checked-in image.
6. **Inspect locally before committing.** Open the PNG under
   `/tmp/ccterm-screenshots/` and verify it looks right. CI will not
   catch a wrong-but-non-uniform render.

Recipe — pattern to copy:

```swift
@MainActor
final class MyViewSnapshotTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testDefaultState() throws {
        // 1. Build state the same way production's .task would.
        let controller = SomeController()
        controller.loadInitial(MyView.initialFixture)   // shared constant

        // 2. Mount the view via its test-seam init, inject env.
        let view = MyView(controller: controller)
            .environment(\.syntaxEngine, SyntaxHighlightEngine())

        // 3. Render → write → attach.
        let image = ViewSnapshot.render(view, size: CGSize(width: 720, height: 720))
        let url = ViewSnapshot.writePNG(image, name: "MyView_default")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "MyView_default.png"
        attachment.lifetime = .keepAlways
        add(attachment)

        // 4. Plausibility only.
        XCTAssertGreaterThanOrEqual(image.size.width, 700)
        // (optional) non-uniform check — see TranscriptDemoSnapshotTests.isUniform
    }
}
```

### When the snapshot doesn't behave — troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| PNG is a single flat color | `.task` / `.onAppear` never ran offscreen, controller is empty | Seed the controller manually in the test (step 2 above) |
| PNG is mostly empty but right-sized | `settle` too short — async layout hadn't landed | Bump `settle:` from default `0.4` to `0.6`–`1.0` |
| Test crashes in `XCTFail("bitmapImageRepForCachingDisplay returned nil")` | `size` too small or zero | Pass a size ≥ the view's `minFrame` (typically ≥ 320×240) |
| Random window flashes onscreen during local runs | Window suppression bypassed | Always go through `ViewSnapshot.render` — it uses `ccterm_orderFrontForTesting()`, which keeps the swizzle scoped |
| Want to diff against a saved image | Not supported here | If you genuinely need golden-image regression, propose it before adding the infra — current convention is review-only |
| Want to test a click / scroll / focus transition | Wrong tool | Drive `handle` / `controller` / bridge directly in a logic test |
| Snapshot depends on `*.shared` singleton | Singleton access leaks across parallel tests | Inject an in-memory replacement via `.environment(...)` (see [Parallel execution](#parallel-execution-hard-rules)) |

### Running

```bash
make test-unit FILTER=TranscriptDemoSnapshotTests
open /tmp/ccterm-screenshots/TranscriptDemoView.png
```

CI does not run snapshot tests (see [Run policy](#run-policy--opt-in-only)).
To inspect a snapshot rendered on the CI runner — e.g. for a font /
metrics difference you can't reproduce locally — push a temporary
workflow that calls `make test-unit FILTER=<ClassName>` and download
the xcresult; do not flip the default suite to include them.

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

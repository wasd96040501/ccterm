# Unit tests (`cctermTests`)

The app's only test target. Three kinds of test live here:

| Kind | What | Runs on default suite / CI |
|---|---|---|
| **Logic tests** (most) | Bridge dispatch, history parsing, block builder, `Session` / `SessionRuntime` transitions. Click / keystroke / focus flows are covered by calling the method the control would call (`session.send(...)`, `controller.handleKey(...)`). | yes |
| **Measurement probes / harness tests** | Mount a real production view tree off-screen and **assert** on geometry, row-typeset counts, animation curves, hit-testing. See [Measurement probes](#measurement-probes-merge-gates) and [Harness/CLAUDE.md](Harness/CLAUDE.md). | yes — merge gates |
| **Snapshot tests** (`*SnapshotTests.swift`) | Render a view to a PNG for a human to look at. No golden-image diff. See [Snapshot tests](#snapshot-tests). | **no** — opt-in by name |

Real-CLI smokes are not XCTests — see [AgentSDK/CLAUDE.md](../AgentSDK/CLAUDE.md).

## Parallel execution: hard rules

XCTest runs **classes in parallel**, each in its own forked process (CI forces 4 workers, `scripts/test-unit.sh`); methods within a class run sequentially. No test may observe another's side effects:

1. **Per-test in-memory dependencies.** Build a fresh `InMemorySessionRepository` (or `CoreDataStack(inMemory: true)`) in `setUp`. Never touch `CoreDataStack.shared`, `SessionManager.shared` or any process-wide singleton.
2. **Unique on-disk artifacts.** Write under `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)` and clean up in teardown. Never a fixed `/tmp/foo` path, never `~/.claude` or `~/.cache/ccterm`.
3. **No `UserDefaults.standard`.** Inject the value at the call boundary (or a UUID-named suite, as the harness does).
4. **No `NotificationCenter.default.post`.** Use a dedicated `NotificationCenter()`.
5. **`@MainActor func testXxx() async` is fine** — isolation is per process.
6. **No `sleep` / `Task.sleep` to synchronize.** Use `await`, `XCTestExpectation`, or `XCTNSPredicateExpectation`.

## Recipes

Runtime / bridge test:

```swift
@MainActor
final class MyBridgeTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSomething() throws {
        let repo = InMemorySessionRepository()
        let runtime = SessionRuntime(sessionId: UUID().uuidString, repository: repo)
        // drive runtime, assert on its observable state
    }
}
```

History replay — load orchestration lives on the `Session` façade, so wrap the runtime:

```swift
let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
try jsonlText.write(to: url, atomically: true, encoding: .utf8)
addTeardownBlock { try? FileManager.default.removeItem(at: url) }

let session = Session(runtime: runtime, cliClientFactory: { _ in FakeCLIClient() })
session.loadHistory(overrideURL: url)
let exp = XCTNSPredicateExpectation(
    predicate: NSPredicate { _, _ in session.historyLoadState == .loaded }, object: nil)
await fulfillment(of: [exp], timeout: 5)   // backfill is async (off-main producer + main drain)
// assert on session.controller.blockIds
```

Shared fixtures live in `Helpers/` (`FakeReversePageSource`, `Message2Fixtures`, `TempJSONLFile`, `MountedTranscript`, `ViewSnapshot`, …) — look there before writing a new one.

## Measurement probes (merge gates)

Tests that mount a real view and assert on a property at the boundary. They use the same off-screen scaffolding as snapshots but pass/fail on `XCTAssert`.

- **Never give them the `Snapshot` filename suffix** — the runner skips that pattern. Name `<Subject>Tests.swift`; the class name must match the file name.
- Text reports via `XCTAttachment(string:)` (and a PNG if it helps debugging) are fine.
- Don't use `ViewSnapshot.render` for them — it carries a long deliberate runloop drain.
- For new real-tree tests prefer the [Harness](Harness/CLAUDE.md) (`AppKitStage`); `Helpers/MountedTranscript.swift` is the transcript-only mount.
- Area-owned gates are listed with the invariant they guard: transcript attach / backfill in [NativeTranscript2 §2.19](../ccterm/Content/Chat/NativeTranscript2/CLAUDE.md), SwiftUI host sizing in [Content/Chat](../ccterm/Content/Chat/CLAUDE.md#swiftui-hosts-two-sizing-regimes).

What the off-screen window (at `(-30_000, -30_000)`, `alphaValue = 0.01`, never key) **cannot** observe:

- A frame the render server actually composited — `bitmapImageRepForCachingDisplay` is a synchronous in-process redraw. For first-composited-frame questions sample `CALayer.presentation()` from a `CADisplayLink` on `NSScreen.main` (not the view's link, which never fires off-screen); `TranscriptScrollLivePresentationSnapshotTests` is the reference.
- Key-window / first-responder behavior: hover tracking areas, cursor rects, focus rings.
- Sibling-view interactions in the real pane and render-server scheduling under load.

When a reported visual glitch doesn't reproduce, **widen the sampled dimensions before declaring it falsified** — e.g. the scroller knob (`verticalScroller.doubleValue`), not just the clip origin (`TranscriptScrollFirstFrameSnapshotTests.testScrollerKnobLandsAtTailAfterScrollToTail`).

## Snapshot tests

Render a real view into an off-screen window, write `/tmp/ccterm-screenshots/<Name>.png`, attach it to the xcresult. **For review only.**

- **Existing ones:** `ls macos/cctermTests/*SnapshotTests.swift` — the class name tells you the view. Run with `make test-unit FILTER=<Class>` and `open` the PNG.
- **Run policy:** the runner injects `-skip-testing:<Class>` for every `*SnapshotTests.swift` when `FILTER` is empty, so they never run on the default suite or CI but still compile. File name must equal class name; split files for multiple classes.
- **Helpers:** `ViewSnapshot.render(_ view: some View, size:settle:)` for SwiftUI, `ViewSnapshot.renderViewController(_:size:settle:)` for AppKit VCs, `ViewSnapshot.writePNG(_:name:)`. Always go through them — they use `ccterm_orderFrontForTesting()`, which keeps the test-process window swizzle scoped.

Adding one:

1. Create `<ViewName>SnapshotTests.swift`; seed state the way production does and reuse production fixture constants.
2. Inject fresh in-memory dependencies (never `*.shared`).
3. Render → `writePNG` → attach with `lifetime = .keepAlways`; assert only plausibility (size, non-uniform).
4. Run it and **open the PNG** — CI can't tell a wrong-but-non-empty render from a right one.

Production seams a snapshot may add (behavior unchanged):

| Allowed | Forbidden |
|---|---|
| A secondary initializer that accepts pre-built state (`init(controller:)`), because SwiftUI `.task` / `.onAppear` don't fire reliably off-screen. Default init unchanged. | `#if DEBUG` UI variants, env-var-gated layout or styling |
| Widening a static fixture `let` from `fileprivate` to `internal` so the test reuses the same bytes — the only access change allowed; it exposes data, not a control | `forceXxxForTest()`, exposing mutable internals, test-only seed data that diverges from production |

If the seam you need isn't in the left column, a snapshot is the wrong tool — assert on the controller / session instead.

| Symptom | Fix |
|---|---|
| PNG is one flat colour | State seeded in `.task` never ran — seed through the test init |
| PNG right-sized but mostly empty | Raise `settle:` (0.4 → 0.6–1.0) |
| `bitmapImageRepForCachingDisplay returned nil` | Size too small / zero; use ≥ the view's min frame |
| Window flashes on screen | Bypassed `ViewSnapshot` — go through it |

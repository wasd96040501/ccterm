# Unit tests

`cctermTests` is the only test target. Use it for **pure-logic** tests
— bridge dispatch, history parsing, block-builder output, session-handle
state transitions. There is no separate UI-test target; cover anything
that would otherwise require a click / keystroke / focus state by
exercising the underlying handle, bridge, or controller directly. See
the root [CLAUDE.md](../../CLAUDE.md#tests) for the rationale.

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

If a test feels like it wants to "click a button," reach for the
underlying method the button would invoke. The button click is `handle.send(...)`;
the keystroke is `controller.handleKey(...)`. Test those.

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

# UI tests

End-to-end XCUITest. There are no unit tests; this is the entire test suite.

**Run on CI, not locally, by default.** UI tests bring `ccterm.app` to the foreground, take focus, and drive keyboard + mouse — running them locally interrupts your desktop. Push a PR and the `ui-test` workflow runs `make test-all` for you.

Only run locally when you need to reproduce a CI failure or you're debugging the tests themselves. Each test takes 10–30s; never default to running the full suite locally.

## Architecture

```
┌─────────────────────────┐                ┌──────────────────────────┐
│ XCUITest runner         │  app.launch()  │ ccterm.app (parent)      │
│ (cctermUITests target)  │ ─────────────▶ │ ─ AppState.applyTestMode │
│ launchEnvironment[ ... ]│                │ ─ InMemorySessionRepo    │
└─────────────────────────┘                │ ─ SessionHandle2.mock... │
                                           └─────────┬────────────────┘
                                                     │ spawn (binaryPath = self,
                                                     │        env CCTERM_RUN_AS_MOCK_CLI=1)
                                                     ▼
                                           ┌──────────────────────────┐
                                           │ ccterm binary (child)    │
                                           │ AppEntryPoint            │
                                           │  → MockCLIRunner.run()   │
                                           │  → reads stdin / writes  │
                                           │    line-delimited JSON   │
                                           │    on stdout             │
                                           └──────────────────────────┘
```

Test-mode switches are **environment variables only** (`launchEnvironment`), never command-line flags.

| Env var | Effect |
|---|---|
| `CCTERM_TEST_MODE=1` | Master switch. Required for the in-memory repo + mock CLI override to be installed. |
| `CCTERM_MOCK_CLI_SCENARIO=foo` | Which scenario the child process should run (see `MockCLIRegistry`). |

## Mock infrastructure

### `InMemorySessionRepository`

`Services/Session/SessionRepository+InMemoryMock.swift` (DEBUG only). A purely in-memory implementation with the same protocol and behavioral contract as `CoreDataSessionRepository`. **Never writes to the main Core Data store**, so UI tests leave no residue.

### Mock CLI

`Services/Session/MockCLI/` (DEBUG only).

- **`MockCLIBaseScenario`** — **most scenarios should inherit from this**. It provides default behavior that mirrors the real Claude CLI: `initialize` ack + `system.init`, `interrupt` ack + `result.error`, user echo + `result.success`, and ack-everything for unrecognized `control_request` subtypes. A scenario only overrides the hook it actually cares about. Every "how mock claude behaves" decision is **test-specific** and lives on the scenario — the mock CLI framework (Runner / Sender / Parser) is scaffolding only.

  Available hooks: `onStart`, `onInitialize`, `onInterrupt`, `onControlRequest` (other subtypes), `onUserMessage`, `onControlResponse`, `onUnknown`.

- **`MockCLIScenario`** (protocol) — implement directly only if you need fully custom routing or want to skip the default parser (typical case: chaos tests that read raw JSON and emit randomly). You own routing via two callbacks: `onStart` / `onIncoming`.

- **`MockCLISender`** — convenience handle for writing to stdout. Common messages have shortcuts:
  - `ackControlSuccess(requestId:response:)` / `ackControlError(...)` — respond to a host `control_request`
  - `sendSystemInit(sessionId:model:)` — system init signal
  - `echoUser(text:uuid:sessionId:)` — echo the user message (drives queued → confirmed matching)
  - `sendAssistantText(_:sessionId:messageId:)` — assistant text
  - `sendResultSuccess(...)` / `sendResultError(...)` — end of turn
  - `sendJSON(_:)` — arbitrary JSON (for edge cases)

- **`MockCLIRunner`** — the child-process entry point. Reads stdin, parses, dispatches to the scenario. On EOF, `exit(0)` so `SessionHandle2.onProcessExit` sees a clean exit.

- **`MockCLIRegistry`** — `name → factory` lookup. **New scenarios must register here**, with a name matching the test's `CCTERM_MOCK_CLI_SCENARIO` value.

### Authoring a scenario

1. In `Services/Session/MockCLI/Scenarios/<Name>Scenario.swift`, write a class that **inherits `MockCLIBaseScenario`** and overrides only what your test cares about:
   ```swift
   #if DEBUG
   final class MyScenario: MockCLIBaseScenario {
       // Deviate from default: never end the turn — echo the user but skip the result frame.
       override func onUserMessage(text: String, uuid: String?, send: MockCLISender) {
           if let uuid { send.echoUser(text: text, uuid: uuid, sessionId: sessionId) }
       }
       // Other hooks (initialize / interrupt / ...) keep the base defaults; no override needed.
   }
   #endif
   ```
2. Register it in `MockCLIRegistry.scenarios`: `"myScenario": { MyScenario() }`.
3. In the test, set `launchEnvironment["CCTERM_MOCK_CLI_SCENARIO"] = "myScenario"`.

One scenario serves one test (or a set of related tests sharing the same CLI deviation). Don't pile unrelated branches into a single scenario — write multiple small ones, each overriding just the one or two hooks it needs. That makes "what does this scenario change relative to the real CLI?" easy to see. Chaos tests and other scenarios that need irregular behavior can implement `MockCLIScenario` directly and bypass the base parser.

### Things not to do

- ❌ Add launch arguments (`--skip-bootstrap`, `--force-running`, ...). They're tricks that grow conditional branches in production code paths. **The only sanctioned testing entry point is a mock CLI scenario** that covers the edge case via the real CLI protocol.
- ❌ Add `forceXxxForTest()` methods to `SessionHandle2` or `SessionManager2`.
- ❌ Read or write internal fields (`pendingTurnCount`, `status`, ...) directly. To get `isRunning == true`, let the scenario actually keep the turn open.
- ❌ `#if DEBUG` skips around production paths. The only DEBUG branches are in `makeAgentConfig` and `AppState.init`, and both **inject** the mock — they never bypass anything.

## Writing tests

### File organization

- One invariant per test method. Don't chain multiple user journeys.
- One invariant family per test class (stop button, send button, sidebar selection, ...).
- Run on `MainActor` (`@MainActor func testXxx()`).
- `continueAfterFailure = false` by default — fail fast.

### Launching the app

```swift
let app = XCUIApplication()
app.launchEnvironment = [
    "CCTERM_TEST_MODE": "1",
    "CCTERM_MOCK_CLI_SCENARIO": "myScenario",
]
app.launch()
```

**Don't use `launchArguments`** to control mock behavior. `launchArguments` is equivalent to `CommandLine.arguments`, which has "trick" energy. `launchEnvironment` is the isolated test channel.

### Accessibility identifiers

```swift
.accessibilityIdentifier("ComponentName.ElementName")
// e.g. InputBar2.SendButton, InputBar2.StopButton, InputBar2.TextField
```

Notes:
- **Set on the leaf element**, not the outer container. SwiftUI's container identifier propagates to every descendant and overrides their own ids.
- Plain `NSTextView` wrapped by `NSViewRepresentable` is not directly addressable via a11y queries — click the outer container to focus the `NSTextView`, then `app.typeText(...)`.

### Waiting for elements

XCUI looks up elements lazily; wait with `waitForExistence(timeout:)`:

```swift
XCTAssertTrue(button.waitForExistence(timeout: 5), "button should appear after X")
```

Use a generous timeout (3–10s); avoid blind `sleep`. Before clicking, wait for `isHittable`:

```swift
_ = button.waitForExistence(timeout: 5)
button.click()
```

### Caveats around keyboard input

- `app.typeText(...)` / `app.typeKey(...)` go through `CGEventPost` — the system-level input stack. **If your local machine has a non-English IME as the active input source**, you may trigger the IME picker or System Settings dialog, which contaminates the test environment. (GitHub CI runners default to English, so this isn't an issue there — another reason to default to CI.)
- Local prerequisite for UI tests: active input source = English / ABC.
- If a test doesn't need keyboard input, prefer driving the state through a mock CLI scenario rather than typing.

### Assertion style

- Expecting existence: `waitForExistence(timeout:)` + `XCTAssertTrue`.
- Expecting absence: `XCTAssertFalse(element.exists)` (no wait — UI mutations are visible synchronously).
- Write messages that **state which invariant was violated**, not "X should be Y".

## Running tests

### Default: push and let CI run

Push to any PR branch → `.github/workflows/test.yml` runs `make test-all` automatically. Results are on the GitHub Actions page:
- Pass → green check.
- Fail → workflow log lists the failed case and assertion; the `xcresult` artifact is uploaded automatically and opens in Xcode (with screenshots and video).

The CI runner already has Go and Xcode set up — no local build environment to maintain.

### Local reproduction (only when needed)

```bash
make test FILTER=InputBar2StopButtonUITests/testStopButtonCancelsRunningState   # single method
make test FILTER=InputBar2StopButtonUITests                                     # single class
make test-all                                                                   # full suite (handle with care; takes focus)
```

Output is progressive: pass prints one line + the `xcresult` path; failure prints the key assertion, crash log, and the three detail paths (summary / full log / xcresult). The `xcresult` bundle contains screenshots and video — `open /tmp/ccterm-test-…/result.xcresult` loads it in Xcode.

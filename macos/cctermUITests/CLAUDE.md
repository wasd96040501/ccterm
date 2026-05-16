# UI tests

End-to-end XCUITest. There are no unit tests; this is the entire test suite.

**Run on CI, not locally, by default.** UI tests bring `ccterm.app` to the foreground, take focus, and drive keyboard + mouse — running them locally interrupts the desktop. Push to any PR branch and `.github/workflows/test.yml` runs `make test-all`. Run locally only to reproduce a CI failure or debug the tests themselves. Each test takes 10–30s.

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

- **`MockCLIBaseScenario`** — base class for almost every scenario. Provides default behavior that mirrors the real Claude CLI: `initialize` ack + `system.init`, `interrupt` ack + `result.error`, user echo + `result.success`, and ack-everything for unrecognized `control_request` subtypes. A scenario only overrides the hook it actually cares about. Every "how mock claude behaves" decision is test-specific and lives on the scenario — the mock CLI framework (Runner / Sender / Parser) is scaffolding only.

  Available hooks: `onStart`, `onInitialize`, `onInterrupt`, `onControlRequest` (other subtypes), `onUserMessage`, `onControlResponse`, `onUnknown`.

- **`MockCLIScenario`** (protocol) — implement directly only when you need fully custom routing or want to skip the default parser (e.g. chaos tests that read raw JSON and emit randomly). You own routing via two callbacks: `onStart` / `onIncoming`.

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

One scenario serves one test (or a set of related tests sharing the same CLI deviation). Do not pile unrelated branches into a single scenario — write multiple small ones, each overriding the one or two hooks it needs.

### Hard rules

- ❌ No launch arguments to control mock behavior (`--skip-bootstrap`, `--force-running`, ...). They grow conditional branches in production code paths. The only sanctioned testing entry point is a mock CLI scenario covering the edge case via the real CLI protocol.
- ❌ No `forceXxxForTest()` methods on `SessionHandle2` or `SessionManager2`.
- ❌ No reading or writing internal fields (`pendingTurnCount`, `status`, ...) directly. To get `isRunning == true`, let the scenario keep the turn open.
- ❌ No `#if DEBUG` skips around production paths. The only DEBUG branches are in `makeAgentConfig` and `AppState.init`, and both **inject** the mock — they never bypass anything.

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

**Never use `launchArguments` to control mock behavior.** `launchArguments` is equivalent to `CommandLine.arguments` and leaks into production code paths. `launchEnvironment` is the isolated test channel.

### Accessibility identifiers

UI-test-only chrome must not ship in Release. Use the `.testIdentifier(_:)`
wrapper instead of calling `.accessibilityIdentifier(_:)` directly:

```swift
.testIdentifier("ComponentName.ElementName")
// e.g. ChatSearchBar.Field, InputBar2.SendButton
```

`testIdentifier(_:)` is defined in `macos/ccterm/Extensions/View+TestIdentifier.swift`.
In DEBUG it forwards to `accessibilityIdentifier(_:)`; in Release it's a
no-op `self`-returning passthrough. Both branches return the same opaque
`some View` so call sites compile in every flavor without a flag check.

**File-layout rule.** Anything whose sole purpose is wiring a UI test —
a11y identifiers, test-only modifiers, `#if DEBUG`-only scenarios /
hooks — lives in a sibling `+TestSupport` / `+TestIdentifier` /
`+TestXxx` extension file (`MainType+Suffix.swift`), wrapped in
`#if DEBUG`. Don't sprinkle bare `.accessibilityIdentifier(_:)` in
production view bodies; don't inline test scenarios next to production
session logic. The boundary makes "what does this file ship at release"
auditable at a glance.

Examples in this codebase:
- `Extensions/View+TestIdentifier.swift` — the wrapper itself.
- `Services/Session/MockCLI/Scenarios/*Scenario.swift` — each is
  `#if DEBUG ... #endif`-wrapped.
- `Services/Session/SessionRepository+InMemoryMock.swift` —
  DEBUG-only repo. (Same `MainType+Suffix.swift` shape.)

Other notes:
- **Set on the leaf element, not the outer container.** SwiftUI's
  container identifier propagates to every descendant and clobbers
  their own ids — *including* sibling ids set on inner elements. The
  a11y tree XCUITest sees will collapse to the container's id on
  every child, and `app.textFields["Foo.Field"]` / `.buttons["Foo.Bar"]`
  silently fail to match.

  ```swift
  // ❌ WRONG — outer `.testIdentifier("Foo")` overrides the inner ids
  HStack {
      Image(...)
      TextField(...).testIdentifier("Foo.Field")
      Button(...).testIdentifier("Foo.Btn")
  }
  .testIdentifier("Foo")

  // ✅ RIGHT — leave the container without an identifier
  HStack {
      Image(...)
      TextField(...).testIdentifier("Foo.Field")
      Button(...).testIdentifier("Foo.Btn")
  }
  ```

  Diagnosing this is non-obvious from the XCTAssert message alone
  ("element doesn't exist"). When that happens, dump the a11y tree:
  `print(app.debugDescription)` — and the same dump lives in every
  failure's xcresult bundle under "App UI hierarchy". Look for the
  leaf elements whose `identifier:` is the *container's* id.
- Plain `NSTextView` wrapped by `NSViewRepresentable` is not directly addressable via a11y queries — click the outer container to focus the `NSTextView`, then `app.typeText(...)`.
- **SwiftUI `Text` content lands in AX `value`, not `label`.** A
  `Text("1 / 2")` becomes an `AXStaticText` whose `AXValue` carries
  `"1 / 2"`; `AXLabel` is empty. In XCUITest, read via
  `staticText.value as? String`, not `.label`. `.label` returns "" and
  the equality check fails with no obvious cause from the assert
  message. The same applies to `Label` and `Text` rendered as decorative
  static text. (Buttons and TextFields behave normally — their `label`
  property is populated.)
- App-scope keyboard shortcuts (e.g. ⌘F) should route through a
  `Commands` menu item (`AppCommands`) and signal per-view state via
  an `@Observable` bus injected through `.environment(...)`. Hidden /
  zero-frame `Button.keyboardShortcut` and
  `NSEvent.addLocalMonitorForEvents` are both unreliable under
  XCUITest's `typeKey(_:modifierFlags:)`; menu-attached shortcuts route
  through the standard AppKit responder chain and deliver consistently.
  `NotificationCenter` is observed to drop deliveries when the
  subscriber lives behind a SwiftUI `.id(...)` boundary, so prefer
  the bus pattern.

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

### Keyboard input caveats

- `app.typeText(...)` / `app.typeKey(...)` go through `CGEventPost` (the system-level input stack). A non-English IME as the active input source can trigger the IME picker or System Settings dialog, contaminating the test environment. GitHub CI runners default to English; locally the active input source must be English / ABC.
- When a test does not need keyboard input, drive state through a mock CLI scenario rather than typing.

### Assertion style

- Expecting existence: `waitForExistence(timeout:)` + `XCTAssertTrue`.
- Expecting absence: `XCTAssertFalse(element.exists)` (no wait — UI mutations are visible synchronously).
- Assertion messages state **which invariant was violated**, not "X should be Y".

## Running tests

### Default: CI

Push to any PR branch → `.github/workflows/test.yml` runs `make test-all` automatically. Results are on the GitHub Actions page:
- Pass → green check.
- Fail → workflow log lists the failed case + assertion; the `xcresult` artifact is uploaded automatically and opens in Xcode with screenshots and video.

### Local reproduction

```bash
make test FILTER=InputBar2StopButtonUITests/testStopButtonCancelsRunningState   # single method
make test FILTER=InputBar2StopButtonUITests                                     # single class
make test-all                                                                   # full suite (takes focus)
```

Output is progressive: pass prints one line + the `xcresult` path; failure prints the key assertion, crash log, and three detail paths (summary / full log / xcresult). `open /tmp/ccterm-test-…/result.xcresult` loads the bundle (screenshots + video) in Xcode.

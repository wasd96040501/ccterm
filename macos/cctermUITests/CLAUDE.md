# UI tests

End-to-end XCUITest. There are no unit tests; this is the entire test suite.

**Run on CI, not locally, by default.** UI tests bring `ccterm.app` to the
foreground, take focus, and drive keyboard + mouse — running them locally
interrupts the desktop. Push to any PR branch and `.github/workflows/test.yml`
runs `make test-all`. Run locally only to reproduce a CI failure or to debug
the tests themselves. Each test takes 10–30s.

If you only have time to read one section, read **[Hard constraints](#hard-constraints)**.
Everything else assumes you respect those rules.

---

## Mental model

XCUITest does **not** see your SwiftUI view tree. It sees the macOS
**accessibility (AX) tree**, which is a *parallel* structure derived from
whatever toolkit drew each pixel. Same pixels, different shapes per backend.
Every test is three steps over that tree:

1. **Locate** — find the AX element you want (by id, label, type, position).
2. **Drive input** — mouse / keyboard, via `XCUIApplication`.
3. **Read output** — element existence, enablement, AX `value` / `label`.

Most "the test is flaky" / "the element doesn't exist" symptoms are failures
of step 1 because the AX shape doesn't match what the SwiftUI source code
suggests. The rest of this doc maps each SwiftUI/AppKit construct to its
AX shape so you can write step 1 correctly the first time.

### AX element vs. SwiftUI view

Per element, XCUITest exposes three independent fields:

| Field | What it is | Set from SwiftUI by |
|---|---|---|
| `identifier` | Developer-stable handle. Empty by default. | `.testIdentifier(_:)` (DEBUG only) |
| `label` | Human-readable description for VoiceOver. Defaults from the visible label of buttons/menu items/etc. | `.accessibilityLabel(_:)`, or inferred from `Button("Save")` / SF symbol name |
| `value` | Current dynamic content. | The element type — text fields carry the typed string, `Text` carries its content, sliders carry their number |

Three rules that catch most bugs:

- **Query by id when you can** — labels change with localization, value
  changes with state. `id` is the only stable handle. Always set one
  via `.testIdentifier(_:)`.
- **Read `Text` content from `.value`, not `.label`.** SwiftUI `Text` renders
  as `AXStaticText` whose `AXValue` carries the string; `AXLabel` is empty.
  `someStaticText.label` returns `""` and the equality check fails with no
  obvious cause from the assert message. Buttons and text fields behave
  normally — their `.label` is populated.
- **Identifier propagation: set on the leaf, not the container.** SwiftUI's
  `.accessibilityIdentifier(_:)` (and our `.testIdentifier(_:)` wrapper)
  *broadcasts* the id to every descendant element. If you put it on the
  outer `HStack`, every child element inherits it, *overwriting* their own
  ids. The AX tree collapses to one repeated id and `app.buttons["Foo.Send"]`
  silently returns nothing.

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

  Same applies to `_ConditionalContent` (the `if x { A } else { B }` shape) —
  the parent identifier sometimes leaks to one branch and not the other.
  Prefer an unconditional view with placeholder data over a branch swap when
  the children carry identifiers (see `thumbnailStrip` for the pattern).

---

## Locating elements

### Pick the right collection

Each AX element belongs to exactly one *type-bucketed* collection on
`XCUIApplication`. Using the wrong bucket is the most common "element doesn't
exist" cause. Use this table to pick first; if unsure, use `app.descendants(matching: .any)[id]` to be type-agnostic.

| Source construct | Type-specific query | Notes |
|---|---|---|
| `Button {} label: {…}` (SwiftUI leaf) | `app.buttons[id]` | Set id on `Button`, not the label closure |
| `Text("…")` | `app.staticTexts[id]` | Content lives in `.value`, not `.label` |
| `Image(systemName:)` standalone | `app.images[id]` | Decorative images may not be in the AX tree at all |
| `TextField` / `TextEditor` | `app.textFields[id]` | The actual typing target |
| `SecureField` | `app.secureTextFields[id]` | |
| `.searchable` (SwiftUI) | `app.searchFields.firstMatch` | Renders as a system search field; `id` not always preserved |
| `Menu { … } label: {…}` (SwiftUI) | `app.menuButtons[label]` | Activator swallows id on macOS 26 — query by `accessibilityLabel`. See [SwiftUI `Menu`](#swiftui-menu) |
| Items *inside* an open `Menu` | `app.menuItems[localizedLabel]` | Open menu first; identifier on inner `Button` is also swallowed; the only stable handle is the visible label |
| `Picker(…)` rendered as pop-up | `app.popUpButtons[id]` | |
| AppKit menu bar item | `app.menuBars.menus[…].menuItems[…]` | |
| `ToolbarItem` | `app.buttons.matching(identifier: id).firstMatch` | Toolbar wraps each item in *two* AX nodes with the same id (outer host + inner SwiftUI button). `.firstMatch` to avoid "multiple matches" throws |
| Sheet on a window | `window.sheets.firstMatch` | The sheet is on the *window* that hosts it |
| `NSOpenPanel` / `NSSavePanel` | `app.windows["open-panel"]` / `app.windows["save-panel"]` | **Not** `.dialogs`, **not** `.sheets`. Confirmed on macOS 26 by dumping `app.debugDescription` |
| Modal popover | `app.popovers.firstMatch` | |
| `NSPanel` | `app.windows[title or id]` | NSPanel surfaces as a regular window — dump the AX tree to find the handle |
| `NSViewRepresentable` wrapping `NSTextView` | Not directly addressable. Click a known sibling's coordinate to focus, then `app.typeText(...)` | See [Driving NSTextView](#driving-nstextview) |
| `NSViewRepresentable` wrapping `NSTableView` | `app.tables.firstMatch.cells` | Each row is a cell; cells expose their own AX children |

### Identifier shape & naming

- String form: `"ComponentName.ElementName"`. Examples in this codebase:
  `InputBar2.SendButton`, `ChatSearchBar.NextButton`, `ChatHistory.TopFadeScrim`.
- Set with `.testIdentifier(_:)` (defined in
  [`Extensions/View+TestIdentifier.swift`](../ccterm/Extensions/View+TestIdentifier.swift)).
  In DEBUG it forwards to `.accessibilityIdentifier(_:)`; in Release it's a
  no-op `self`-returning passthrough, so id strings live behind a `#if DEBUG`
  boundary at compile time and don't ship.
- **Never** call `.accessibilityIdentifier(_:)` directly in a production
  view body. The only sanctioned spelling is `.testIdentifier(_:)`.
- `.accessibilityLabel(_:)` is *production* code (it's what VoiceOver users
  hear). It is **not** a test-only escape hatch. Set it when the element
  genuinely needs a semantic label for accessibility users; tests may
  query off it as a side effect (e.g. `app.menuButtons["Attach image or file"]`).

### Diagnosis playbook ("element doesn't exist")

When `app.buttons["Foo"]`, `app.images["Foo"]`, etc. return `false`, don't
keep guessing at element types. Walk the playbook:

1. **Dump the live AX tree** from inside the failing test and read the CI log:

   ```swift
   print("=== full a11y tree ===")
   print(app.debugDescription)
   ```

   You'll see entries like
   `Button, 0x…, identifier: 'InputBar2.SendButton', {{x, y}, {w, h}}` and
   you can pick the matching element type directly. **Remove the diagnostic
   before merging.**

2. **Look for the propagation bug**: any leaf whose `identifier:` is the
   *container's* id. Fix by moving `.testIdentifier(...)` to the leaf.

3. **Check the type** (`Button` vs. `MenuButton` vs. `StaticText` vs.
   `Image`) — they live in different `app.<type>s` collections.

4. **Special-case the suspects** below ([Menu](#swiftui-menu),
   [NSOpenPanel](#nsopenpanel--system-dialogs),
   [NSTextView](#driving-nstextview), [Toolbar](#toolbar-double-node)).

5. **`xcresult` bundle**: the same `App UI hierarchy` dump is attached to
   every failure automatically. `open /tmp/ccterm-test-…/result.xcresult`
   in Xcode and click into the failed test → screenshots + the hierarchy.

If the playbook didn't solve it, **web-search a confirmed working recipe**
before iterating by intuition. XCUITest semantics shift across macOS
versions, and what worked on macOS 14 may not work on macOS 26 (e.g.
`NSOpenPanel` moved from `dialogs` → `windows`). Apple Developer Forums,
Swift Forums, and Stack Overflow are the usual sources; once you find
something that works, link it in the test file and add a one-liner here
under [Special cases](#special-cases) so the next person doesn't redo
the search.

---

## Driving input

### Mouse

- `element.click()`. If the element exists but isn't *hittable* (covered by
  another view, off-screen, animating in), the click silently succeeds and
  nothing happens. Wait for `isHittable` / `isEnabled` first, or just for
  `waitForExistence` then click — most cases settle by then.
- **Disabled buttons still accept clicks** under XCUITest, the action just
  doesn't fire. Assert `isEnabled` before assuming a click took effect.
- For elements that aren't AX-addressable (NSTextView, see below), click via
  a known sibling's coordinate:
  `sibling.coordinate(withNormalizedOffset: CGVector(dx: -10, dy: 0.5)).click()`.

### Keyboard

`app.typeText(...)` and `app.typeKey(...)` go through `CGEventPost`, the
system input stack. Implications:

- The app must be **frontmost** (which is true after `app.launch()`).
- The **active system input source must be English / ABC**. A non-English
  IME may trigger the IME picker or System Settings dialog and pollute
  the test environment. CI runners default to English; locally you must
  set it yourself.
- Modifier shortcuts:
  - `app.typeKey("\r", modifierFlags: .command)` → ⌘↩
  - `app.typeKey("g", modifierFlags: [.command, .shift])` → ⌘⇧G
  - `app.typeKey(.return, modifierFlags: [])` → ↩

If a test doesn't need keyboard input, drive state through a [mock CLI
scenario](#mock-cli-runtime) rather than typing.

### Driving NSTextView

`NSTextView` wrapped by `NSViewRepresentable` (used by `InputTextView` /
the message field) is not directly AX-addressable — there's no `id` to
query. Click a known sibling's frame to focus it, then `typeText`:

```swift
let sendButton = app.buttons["InputBar2.SendButton"]
let barCenter = sendButton.coordinate(withNormalizedOffset: CGVector(dx: -10, dy: 0.5))
barCenter.click()      // focuses InputTextView (its frame extends left of the send button)
app.typeText("hi")
app.typeKey("\r", modifierFlags: .command)
```

### App-level keyboard shortcuts (⌘F, ⌘N, ...)

Route through a `Commands` menu item (`AppCommands`) and signal per-view
state via an `@Observable` bus injected through `.environment(...)`.
**Don't** use hidden / zero-frame `Button.keyboardShortcut` or
`NSEvent.addLocalMonitorForEvents` — both are unreliable under XCUITest's
`typeKey(_:modifierFlags:)`. Menu-attached shortcuts route through the
standard AppKit responder chain and deliver consistently.
`NotificationCenter` is observed to drop deliveries when the subscriber
lives behind a SwiftUI `.id(...)` boundary, so prefer the bus pattern.

### Pasteboard for autocompleting fields

`typeText` is unreliable in fields with path / completion autocomplete
(`NSOpenPanel`'s Go-to-Folder, address fields, ...). The completion
inserts mid-stream and garbles the input. Use the pasteboard:

```swift
let pb = NSPasteboard.general
pb.clearContents()
pb.setString("/tmp/my-test-file.png", forType: .string)
field.click()
app.typeKey("a", modifierFlags: .command)
app.typeKey("v", modifierFlags: .command)
```

---

## Reading output

| What you want to check | How |
|---|---|
| Element appears | `XCTAssertTrue(el.waitForExistence(timeout: 5), msg)` |
| Element disappears (synchronous) | `XCTAssertFalse(el.exists, msg)` — UI mutations are visible immediately after the triggering action |
| Element disappears (animation pending) | `XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: el)` + `XCTWaiter().wait(...)` |
| Button is enabled | `XCTAssertTrue(button.isEnabled, msg)` |
| Button becomes enabled (e.g. after panel state settles) | `XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: button)` + `XCTWaiter().wait(...)` |
| Text content of a SwiftUI `Text` | `staticText.value as? String` (**not** `.label`) |
| Text content of a TextField | `textField.value as? String` |
| Button's visible label | `button.label` |

**Timeouts**: 3–10s. Avoid blind `sleep`. The first test of a class also pays
cold-launch latency on the CI VM — bump that one's timeout if needed (see
`TranscriptSearchUITests.launchAppAndSeedTranscript` for an example using 15s).

**Assertion messages** state *which invariant was violated*, not "X should be
Y". Compare:

- ❌ `"sendButton.isEnabled should be true"`
- ✅ `"send button should be enabled once an image is attached (image alone satisfies the canSend gate)"`

---

## Special cases

The cases here all have one thing in common: the AX shape doesn't match the
SwiftUI source code, so the obvious query fails. Each entry documents the
working recipe and links the source that confirmed it.

### SwiftUI `Menu`

A SwiftUI `Menu` on macOS 26 surfaces as a `MenuButton`. Two surprises:

1. The activator **swallows** `.accessibilityIdentifier(_:)` placed inside
   the label closure (or on the `Menu` itself). The only stable handle is
   `.accessibilityLabel(_:)` on the `Menu`, which sets the `MenuButton`'s
   AX label. Tests query `app.menuButtons["<the label>"]`.

   ```swift
   Menu {
       Button(String(localized: "Image")) { presentImagePicker() }
   } label: {
       Image(systemName: "plus")  // …styling
   }
   .accessibilityLabel(String(localized: "Attach image or file"))   // ← test handle
   ```

   ```swift
   // Test side:
   let attach = app.menuButtons["Attach image or file"]
   ```

   **Don't** add a "future-proofing" `.testIdentifier(...)` alongside the
   label — XCUITest doesn't honor it on `Menu` today, and dead identifiers
   that nothing queries are exactly the kind of speculative chrome we don't
   ship (see the [no-dead-code rule below](#production-code-forbidden-patterns)).
   When a future macOS starts honoring it, add it then — alongside the
   test that queries it.

2. The menu *items* also swallow identifiers — XCUITest does not surface
   `.accessibilityIdentifier(_:)` placed on a `Button` inside a `Menu`. The
   only stable handle for an item is its **visible localized label**:

   ```swift
   attachButton.click()
   let item = app.menuItems["Image"]   // localized label, NOT a testIdentifier
   item.click()
   ```

   Tests run with English as the active locale (the keyboard caveat applies),
   so use the English string.

### `NSOpenPanel` / system dialogs

On macOS 26, `NSOpenPanel.begin(...)` surfaces as a regular **window**,
not a `.dialog` and not a `.sheet`:

- Identifier: `'open-panel'`
- Title: `'Open'`

Older recipes from Apple Developer Forums use `app.dialogs.firstMatch`,
which silently doesn't match anymore. The element-type discovery comes from
dumping `app.debugDescription` on the CI runner.

Standard recipe for selecting a known absolute path:

```swift
let panel = app.windows["open-panel"]
XCTAssertTrue(panel.waitForExistence(timeout: 10))

// ⌘⇧G opens "Go to Folder" — a sheet on the panel with a single text field
// (NOT a comboBox as older recipes suggest).
app.typeKey("g", modifierFlags: [.command, .shift])
let goSheet = panel.sheets.firstMatch
XCTAssertTrue(goSheet.waitForExistence(timeout: 5))

let pathField = goSheet.textFields.firstMatch
XCTAssertTrue(pathField.waitForExistence(timeout: 5))

// Paste, don't type — autocomplete garbles typed paths
let pb = NSPasteboard.general
pb.clearContents()
pb.setString("/tmp/my-test-file.png", forType: .string)
pathField.click()
app.typeKey("a", modifierFlags: .command)
app.typeKey("v", modifierFlags: .command)
app.typeKey(.return, modifierFlags: [])   // macOS 26 hides the explicit Go button

let openButton = panel.buttons["Open"]
XCTAssertTrue(openButton.waitForExistence(timeout: 5))

// Wait for Open to *enable* — a disabled Open accepts the click but does
// nothing, so the test would pass and the file wouldn't open.
let enabled = NSPredicate(format: "isEnabled == true")
_ = XCTWaiter().wait(
    for: [XCTNSPredicateExpectation(predicate: enabled, object: openButton)],
    timeout: 5)
openButton.click()
```

The test runner writes a fixture to `/tmp` in `setUpWithError` and removes it
in `tearDownWithError`. Production code reads the file via the real
`Data(contentsOf:)` path, so the panel + filesystem branches both stay
covered.

Sources: [Apple Developer Forums — "How do we use NSOpenPanel in
XCUITests"](https://developer.apple.com/forums/thread/63275) (keyboard
flow; the element-type advice is now outdated). The `open-panel` window
identifier was confirmed by dumping `app.debugDescription` on the macOS 26
CI runner.

### Toolbar double-node

A `ToolbarItem` containing a SwiftUI button exposes **two** AX `Button`
elements with the same identifier — an outer host wrapper and the inner
SwiftUI button. Both proxy the same action and reflect the same enablement,
so either click works, but `app.buttons["Foo"]` throws *"multiple matching
elements"*. Always:

```swift
app.buttons.matching(identifier: "Foo").firstMatch
```

### Driving the search field (`.searchable`)

SwiftUI's `.searchable(text:)` renders as a system search field in the
toolbar's trailing slot. It's always mounted; there is no open / close cycle.
Tests query `app.searchFields.firstMatch`, click to focus, then type.

The result counter rendered as a `Text("\(n) / \(total)")` is an
`AXStaticText`; read with `.value as? String`.

---

## Mock CLI runtime

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

Test-mode wiring is **environment variables only** (`launchEnvironment`),
never command-line flags. See the [Hard
constraints](#hard-constraints) for why.

| Env var | Effect |
|---|---|
| `CCTERM_TEST_MODE=1` | Master switch. Required for the in-memory repo + mock CLI override to be installed. |
| `CCTERM_MOCK_CLI_SCENARIO=foo` | Which scenario the child process should run (see `MockCLIRegistry`). |
| `CCTERM_RUN_AS_MOCK_CLI=1` | Set by `AppState+TestMode` on the **child** spawn; tells `AppEntryPoint` to fork to `MockCLIRunner.run()` instead of `CCTermApp.main()`. Tests never set this directly. |

### Pieces

All under `Services/Session/`, all `#if DEBUG`-wrapped:

- **`InMemorySessionRepository`** (`SessionRepository+InMemoryMock.swift`) —
  Implements `SessionRepository` with in-memory storage. Same protocol as
  `CoreDataSessionRepository`. **Never writes to the main Core Data store**,
  so UI tests leave no residue.

- **`MockCLIBaseScenario`** (`MockCLI/MockCLIBaseScenario.swift`) — base
  class for almost every scenario. Provides default behavior that mirrors
  the real Claude CLI: `initialize` ack + `system.init`, `interrupt` ack +
  `result.error`, user echo + `result.success`, ack-everything for
  unrecognized `control_request` subtypes. A scenario only overrides the
  hook it actually cares about. Every "how mock claude behaves" decision
  is test-specific and lives on the scenario — the framework
  (`Runner` / `Sender` / `Parser`) is scaffolding only.

  Available hooks: `onStart`, `onInitialize`, `onInterrupt`, `onControlRequest`
  (other subtypes), `onUserMessage`, `onControlResponse`, `onUnknown`.

- **`MockCLIScenario`** (protocol) — implement directly only when you need
  fully custom routing or want to skip the default parser (e.g. chaos tests
  that read raw JSON and emit randomly). You own routing via two callbacks:
  `onStart` / `onIncoming`.

- **`MockCLISender`** (`MockCLI/MockCLIProtocol.swift`) — convenience handle
  for writing to stdout. Common messages have shortcuts:
  - `ackControlSuccess(requestId:response:)` / `ackControlError(...)` —
    respond to a host `control_request`
  - `sendSystemInit(sessionId:model:)` — system init signal
  - `echoUser(text:uuid:sessionId:)` — echo the user message (drives
    queued → confirmed matching)
  - `sendAssistantText(_:sessionId:messageId:)` — assistant text
  - `sendResultSuccess(...)` / `sendResultError(...)` — end of turn
  - `sendJSON(_:)` — arbitrary JSON (for edge cases)

- **`MockCLIRunner`** (`MockCLI/MockCLIRunner.swift`) — the child-process
  entry point. Reads stdin, parses, dispatches to the scenario. On EOF,
  `exit(0)` so `SessionHandle2.onProcessExit` sees a clean exit.

- **`MockCLIRegistry`** (`MockCLI/MockCLIRegistry.swift`) — `name → factory`
  lookup. **New scenarios must register here**, with a name matching the
  test's `CCTERM_MOCK_CLI_SCENARIO` value.

### Authoring a scenario

1. In `Services/Session/MockCLI/Scenarios/<Name>Scenario.swift`, write a
   class that **inherits `MockCLIBaseScenario`** and overrides only what
   your test cares about:

   ```swift
   #if DEBUG
   final class MyScenario: MockCLIBaseScenario {
       // Deviate from default: never end the turn — echo the user but
       // skip the result frame.
       override func onUserMessage(text: String, uuid: String?, send: MockCLISender) {
           if let uuid { send.echoUser(text: text, uuid: uuid, sessionId: sessionId) }
       }
       // Other hooks (initialize / interrupt / ...) keep the base
       // defaults; no override needed.
   }
   #endif
   ```

2. Register it in `MockCLIRegistry.scenarios`: `"myScenario": { MyScenario() }`.

3. In the test, set `launchEnvironment["CCTERM_MOCK_CLI_SCENARIO"] = "myScenario"`.

One scenario serves one test (or a set of related tests sharing the same
CLI deviation). Do not pile unrelated branches into a single scenario —
write multiple small ones, each overriding the one or two hooks it needs.

---

## Hard constraints

A single principle: **production code must not know that UI tests exist,
beyond a narrow set of dependency-injection seams.** All other "test pass"
problems are fixed *on the test side*.

### Production code: forbidden patterns

- ❌ **Don't swap a SwiftUI construct for a different one** because the
  test can't address one. Examples: replacing a `Menu` with a `Popover`,
  a `Window` with a `Sheet`, an `NSOpenPanel` with a custom file picker —
  all forbidden if the motivation is "the test can't click it". Use the
  [Special cases](#special-cases) recipes or web-search a working AX
  query instead.
- ❌ **Don't add hidden test-only buttons, menu items, or zero-frame
  controls** to expose state. The AX tree already exposes element state
  via `.exists` / `.isEnabled` / `.value` / `.label` — no extra surface
  is needed.
- ❌ **Don't gate user-visible behavior on `CCTERM_TEST_MODE`** (or any
  other env var). Test mode is the *injection seam* only — it swaps the
  repository and the CLI binary. Same UI, same flow, same observable
  semantics.
- ❌ **Don't add `forceXxxForTest()` / `simulateYyyForTest()` methods** to
  production types. To put a session into `isRunning == true`, the right
  answer is a scenario that withholds the result frame, not
  `handle.isRunning = true` from the test.
- ❌ **Don't read or write internal session state directly from a test**
  (`pendingTurnCount`, `status`, ...). Same reason — drive the real
  state machine via a scenario.
- ❌ **Don't use `launchArguments` to control test mode.** `launchArguments`
  is equivalent to `CommandLine.arguments` and leaks into production
  parsing. `launchEnvironment` is the isolated channel.
- ❌ **Don't add `#if DEBUG` branches inside real flows.** The only `#if
  DEBUG` allowed in production source is at the four [allowed seams](#allowed-debug-seams)
  below; never inside view bodies, state machines, or business logic.
- ❌ **Don't keep `public` / `internal` access wider than the file needs**
  with a comment like "for test hooks". Either the test actually calls
  it (then put the call site in a `+TestSupport.swift` file and add a
  real DEBUG seam) or it doesn't (then tighten the access). Stale
  "test hook" comments are forbidden.
- ❌ **Don't leave speculative test-hook chrome in production.** A
  `.testIdentifier(...)` that no current test queries, an
  `.accessibilityLabel(...)` added "just in case", a public method that
  exists only to keep a hypothetical future test convenient — all dead.
  Add them alongside the test that needs them, never ahead of one.
  This is the same "don't design for hypothetical future requirements"
  rule the project applies to production code generally — UI-test
  chrome doesn't get an exception.

### Allowed DEBUG seams

These four — and only these four — shapes are allowed:

1. **Dependency swap at construction** — `AppState.init` calls
   `applyTestModeIfNeeded()` to inject `InMemorySessionRepository` instead
   of the Core Data one. The handle and manager see the same
   `SessionRepository` protocol either way; no flow logic checks "am I in
   test mode?".

2. **CLI binary override** — `SessionHandle2.makeAgentConfig` reads
   `mockCLIOverride` and swaps `config.binaryPath` + `config.env`. AgentSDK
   launches whatever's in `config.binaryPath`; there is no other branching
   in the launch path.

3. **Process entry-point fork** — `AppEntryPoint.main` reads
   `CCTERM_RUN_AS_MOCK_CLI` and forks to `MockCLIRunner.run()`. The mock
   subprocess never imports SwiftUI / CoreData; it's a completely separate
   execution branch above `CCTermApp.main()`.

4. **`.testIdentifier(...)` wrapper** — in DEBUG forwards to
   `.accessibilityIdentifier(...)`, in Release is `self`. Identifier
   strings live in source but compile out of Release binaries.

Anything new must either reuse one of these shapes or extend the
collection. A new DEBUG seam needs three properties:

- **Pure injection** — swaps a dependency at construction, no behavior
  change inside the real flow.
- **One direction** — production code never reads "am I in test mode";
  it only consumes the injected dependency.
- **Isolated file** — lives in a `+TestSupport` / `+TestIdentifier` /
  `+TestMode` extension file, wrapped in `#if DEBUG`.

### File-layout rule

Anything UI-test-only — a11y identifiers, test-only modifiers, mock CLI
scenarios, in-memory repos — lives in a sibling extension file whose
name carries the suffix (`MainType+TestSupport.swift`,
`View+TestIdentifier.swift`, `AppState+TestMode.swift`, etc.), wrapped
in `#if DEBUG`. The boundary makes "what does this file ship in Release?"
auditable at a glance.

Examples in this codebase:

- [`Extensions/View+TestIdentifier.swift`](../ccterm/Extensions/View+TestIdentifier.swift) — the wrapper.
- [`App/AppState+TestMode.swift`](../ccterm/App/AppState+TestMode.swift) — test-mode injection.
- [`Services/Session/SessionRepository+InMemoryMock.swift`](../ccterm/Services/Session/SessionRepository+InMemoryMock.swift) — DEBUG-only repo.
- [`Services/Session/SessionHandle2/SessionHandle2+MockCLI.swift`](../ccterm/Services/Session/SessionHandle2/SessionHandle2+MockCLI.swift) — the `mockCLIOverride` storage.
- [`Services/Session/MockCLI/`](../ccterm/Services/Session/MockCLI/) — runner / protocol / registry / base scenario.
- [`Services/Session/MockCLI/Scenarios/*Scenario.swift`](../ccterm/Services/Session/MockCLI/Scenarios/) — each `#if DEBUG`-wrapped.

### When a real-UI path is genuinely impossible

If you've gone through the [diagnosis playbook](#diagnosis-playbook-element-doesnt-exist)
and web-searched a recipe and the element still isn't reachable through
the AX tree, the *very last* fallback is an isolated DEBUG injection
point in a `+TestSupport.swift` file. Before adding it, satisfy:

- A comment in the test file linking the constraint that forced it
  (Apple Developer Forums thread, radar number, etc.).
- The injection mutates a dependency / wraps a side effect; it does
  **not** change visible behavior or skip production logic.
- A line under [Special cases](#special-cases) documenting the pattern,
  so the next person finds it before re-inventing.

If you can't satisfy all three, the test isn't ready to ship — keep
working on the test side.

---

## Writing tests

### File organization

- One invariant per test method. Don't chain multiple user journeys.
- One invariant family per test class (stop button, send button, sidebar
  selection, ...).
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

### Waiting for elements

XCUI looks up elements lazily; wait with `waitForExistence(timeout:)`:

```swift
XCTAssertTrue(button.waitForExistence(timeout: 5), "button should appear after X")
```

Use a generous timeout (3–10s); avoid blind `sleep`. Before clicking, wait for
`isHittable` (or just `waitForExistence` + assert `isEnabled`):

```swift
_ = button.waitForExistence(timeout: 5)
button.click()
```

---

## Running tests

### Default: CI

Push to any PR branch → `.github/workflows/test.yml` runs `make test-all`
automatically. Results are on the GitHub Actions page:

- Pass → green check.
- Fail → workflow log lists the failed case + assertion; the `xcresult`
  artifact is uploaded automatically and opens in Xcode with screenshots
  and video.

### Local reproduction

```bash
make test FILTER=InputBar2StopButtonUITests/testStopButtonCancelsRunningState   # single method
make test FILTER=InputBar2StopButtonUITests                                     # single class
make test-all                                                                   # full suite (takes focus)
```

Output is progressive: pass prints one line + the `xcresult` path; failure
prints the key assertion, crash log, and three detail paths (summary / full
log / xcresult). `open /tmp/ccterm-test-…/result.xcresult` loads the bundle
(screenshots + video) in Xcode.

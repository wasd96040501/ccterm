# CCTerm

Native macOS client for Claude Code. SwiftUI + AppKit, minimum target macOS 14 (Sonoma).

## Architecture at a glance

- **UI framework — SwiftUI by default, AppKit by exception.** Reach for AppKit only when SwiftUI cannot meet the requirement (performance, lifecycle timing, or a missing capability). The current AppKit footprint is:
  - **Chat transcript** — `NSTableView` + Core Text self-drawn (`NativeTranscript2`). SwiftUI's `List` / `LazyVStack` cannot keep up with the row count, custom layout, and selection semantics.
  - **Main window root** — `MainWindowController` + `MainSplitViewController` + `DetailRouterViewController` + `ChatSessionViewController`. The transcript's mount and `frameDidChange` cascade must run in AppKit's source phase, not SwiftUI's commit pass. `ChatSessionViewController` keeps only "what the pane shows" (scrims, `restingBarHost`, `permissionCardHost`, focus, cutouts) and delegates the transcript build/settle/bind/`scrollToTail`/drop + same-session crossfade to `TranscriptSwapCoordinator` (`App/AppKit/`), which is the **single owner** of `currentSession` and of each per-attach scroll view + `Transcript2SheetPresenter`.
  - **Sidebar** — `SidebarViewController` on `NSOutlineView` (source-list style). SwiftUI's `.listStyle(.sidebar)` is itself an `NSOutlineView` under the hood, but going direct gives us folder drag-and-drop via the standard `pasteboardWriterForItem` / `validateDrop` / `acceptDrop` trio and built-in `expandItem(_:)` / `collapseItem(_:)` animations.
  - **Window toolbar** — `NSToolbar` + `NSSearchToolbarItem`; `.searchable` doesn't give the first-responder + ⌘F semantics the transcript search needs.
  - **App lifecycle** — `AppDelegate` (via `@NSApplicationDelegateAdaptor`) owns app-scope state and creates the main window in `applicationDidFinishLaunching`.

  Everything else — input bar, configurator, overlays, Settings / About windows, every reusable component — is SwiftUI, hosted via `NSHostingController` (full panes) or `NSHostingView` (toolbar items / overlays). New code lands in SwiftUI unless it fits one of the exceptions above; introducing a new AppKit surface needs an explicit reason (perf measurement, missing API, lifecycle ordering).

- **Entry point**: `@main CCTermApp` (SwiftUI `App`) → `@NSApplicationDelegateAdaptor(AppDelegate.self)` → `MainWindowController` → `MainSplitViewController` (sidebar item + detail item) → `DetailRouterViewController`, which mounts exactly one `DetailRouterChild` VC per selection (`ChatSessionViewController` for `.session(_)` / `.none`, `ComposeSessionViewController` for `.newSession`, `DraftSessionLandingViewController` for a `.session` that is still a draft, `ArchiveViewController` for `.archive`, demo VCs in DEBUG). Selection / draft state lives on `MainSelectionModel` (`@Observable`); the AppKit `SidebarViewController` writes it via `select(_:)`, and the router is its **sole structural observer** — `select(_:)` drives the detail-side transition synchronously, in the same source phase as the click. Settings / About remain SwiftUI `Window` scenes; their menu items + ⌘F binding come from `AppCommands` (a SwiftUI `Commands` block on the Settings scene) so cold-start clicks resolve `@Environment(\.openWindow)` cleanly.
- **Layers**:
  - **Model** — plain data, `struct` first, `Codable` where it crosses a boundary.
  - **View** — SwiftUI structs, declarative.
  - **Service** — `@Observable`, injected via initializer or `.environment()`. Views never construct services themselves.
  - **AppState** — process-scope container owned by `AppDelegate`, passed down by **initializer** (`AppDelegate` → `MainWindowController` → `MainSplitViewController`), not injected wholesale via `.environment(appState)`. `MainSplitViewController` unpacks its members: the sidebar's needs are bundled into a `SidebarContext`, and the four detail-scope services are bundled into a `DetailContext` that reaches SwiftUI children via `injectDetailEnvironment(_:)`. Holds `SessionManager`, `SyntaxHighlightEngine`, `RecentProjectsStore`, `InputDraftStore`, `SidebarSessionGroupOrderStore`, `AppActivationTracker`, `NotificationService`, `OpenInAppService`. (`TranscriptSearchBus` is **not** on `AppState` — it lives on `AppDelegate`, read by the toolbar search bridge + ⌘F command.)
  - **Deterministic teardown** — every `@MainActor @Observable` / VC type carries an empty `nonisolated deinit {}` (works around a macOS-26 `libswift_Concurrency` abort on the `@MainActor` deinit executor hop). Every `DetailRouterChild` implements `prepareForRemoval()` so the router releases per-attach resources (scroll view, sheet presenter, `isRunning` task) deterministically on swap rather than at ARC's leisure.

### Embedding SwiftUI in AppKit: host sizing

When you host a SwiftUI view in an `NSHostingView` / `NSHostingController`, the host's `sizingOptions` decides whether the SwiftUI content's size flows *up* into Auto Layout. There are two cases, and picking the wrong one collapses the window:

- **Fill-a-pane host → `sizingOptions = []`.** The hosted view *is* its container's content, pinned edge-to-edge; the container (split → window) must drive its size, not the reverse. The default options publish the body's `view.fittingSize` as an intrinsic size — with nothing else governing that dimension, it leaks up through the split's `view.fittingSize` into the window's constraint solver (`_changeWindowFrameFromConstraintsIfNecessary`) and **resizes / collapses the window**. `[]` severs that path; you then pin all four edges so layout sizes the host from the container. Examples: `ArchiveViewController`, `ComposeSessionViewController`, the permission-cards demo child.

- **Subordinate component → `sizingOptions = [.intrinsicContentSize]`.** The hosted view is a small piece whose *container* is sized by something else (a toolbar slot; or a bottom-anchored bar over a transcript that already fills the pane). Here you *want* the content to size itself: pin only its position and let the host's intrinsic content size supply the missing dimension(s). No window-collapse risk — the component isn't what governs its container's size. Examples: `ChatSessionViewController`'s input-bar host (centered, width-capped, height from intrinsic), the toolbar project chip / archive-filter (`MainWindowController`).

Rule of thumb: **does the host fill its container (→ `[]`, container drives size) or sit inside it as a component (→ `[.intrinsicContentSize]`, content drives size)?** Never hand-roll the height with `GeometryReader` + `PreferenceKey` + a manual height constraint — that was an earlier input-bar workaround and is exactly what `.intrinsicContentSize` does for free.

The full taxonomy (the question above decides between A/B; the rest close it):

- **A — fill-a-pane** (`NSHostingController`, `[]`, pin 4 edges). `ArchiveViewController`, `ComposeSessionViewController`, `DraftSessionLandingViewController`.
- **B — centered component** (`NSHostingView`, `[.intrinsicContentSize]`; `centerX` + `width≤cap`@required + `width==cap`@high + `leading≥`inset + `bottom==`). `ChatSessionViewController`'s `restingBarHost`.
- **B′ — toolbar slot** (`[.intrinsicContentSize]`, no constraints — `NSToolbar` auto-measures). `MainWindowController` project chip / archive filter.
- **B″ — floating overlay** (default sizing, position-only — **never 4-edge**, or its `fittingSize` escapes into the split). DEBUG demo overlays.
- **C — window-content** (default sizing — the window snaps to the content). Settings / About.
- **D — modal sheet** (default sizing; `beginSheet`). `Transcript2SheetPresenter`.
- **E — leaf-in-cell** (`[.intrinsicContentSize]`, feeds `heightOfRow`) — no production instance; the transcript is Core-Text self-drawn.

Two corollaries: the archive window-collapse is caused by the **sizing regime** (a default-`sizingOptions` fill-pane host leaking its `fittingSize`), **not** the two-way `Binding` — the binding only re-publishes the bad `fittingSize` on each write. A `Binding` crossing the boundary uses `[weak self]` in both closures, and an AppKit write reaches the SwiftUI body at the next beforeWaiting, not the same tick.

### SwiftUI rules

- `@Observable` for state shared across views (e.g. `Session`); `@State` for view-private UI state; `@Binding` for writable references from a parent.
- Put reusable SwiftUI components under `Components/`.
- If a `body` runs past ~40 lines, split it: child views with their own state become separate `View` structs (and usually their own files); pure layout becomes a computed property or `@ViewBuilder` helper.
- No expensive work inside `body`. Long lists use `NativeTranscript2`, never `List` / `LazyVStack`.
- `ForEach` ids must be stable.
- Load data with `.task { }`; react to dependency changes with `.task(id:)` or `.onChange(of:)`. Never trigger side effects from the body construction path.

### Data-flow rules

The chat area is ~90% one-way: AppKit shell + SwiftUI leaves. Keep it that way.

- **State lives at the lowest scope shared by all its readers.** Process → `AppState`; window selection → `MainSelectionModel`; one session → `Session`; transcript rows → `Transcript2Coordinator.blocks`; single-reader UI state → `@State` (never a model field).
- **`selectionObserver` is the ONE structural upward edge** and must fire in the click's source phase (`@Observable` re-eval lands a tick late at beforeWaiting and would tear a session swap across frames). Do **not** generalize it into a notification bus or a second observer slot — new "react structurally to selection" needs go through the router.
- **The only `@Observable` a view may construct are view-private interaction state machines** — `CompletionState`, `GitProbe`, `BackgroundTaskOutputStream` (each `@State`-owned). There is no session/transcript coordinating ViewModel.
- **An imperative call across the AppKit↔SwiftUI boundary is allowed only when correctness depends on a runloop-tick `@Observable` can't express**, and must be justified at the call site. The three cases: it must run in the click's source phase; it hands AppKit an exact delta instead of forcing a diff (`bridge.apply`, `setLoading`, `setTurnUsage`); or it must run above a teardown that would swallow a reactive `.onChange` (draft-clear on send).

## macOS runloop tick model

Most "why is this one tick off" puzzles in AppKit + SwiftUI code resolve once you remember the order AppKit, SwiftUI, and CoreAnimation share a single runloop iteration. Every invariant below the "must run in AppKit's source phase" / "races with SwiftUI's commit pass" wording in the architecture section above is written against this diagram:

```
┌─ source phase ─────────────── your code runs here ──────────┐
│  · NSEvent dispatch              (mouse / key / wheel)      │
│  · DispatchQueue.main.async      drained block-by-block     │
│  · Observation @MainActor Tasks  resumed                    │
│  · NotificationCenter posts                                 │
│  · Timer fires                                              │
│  · NSResponder selectors         (IBAction, performSelector)│
│                                                             │
│  setNeedsLayout / setNeedsDisplay / frame writes / bounds   │
│  writes land NOW — actual layout + draw + commit happen     │
│  in the next phase.                                         │
├─ beforeWaiting observer ─── AppKit + CoreAnimation flush ──┤
│  · SwiftUI body re-eval for invalidated views               │
│      (Observation registers a runloop observer here)        │
│  · NSWindow.update                                          │
│  · updateConstraints → layout → display walks the view tree │
│  · NSTableView's first display pass lazily queries          │
│    numberOfRows / heightOfRow and runs tile()               │
│  · CATransaction implicit commit → render server (IPC)      │
├─ sleep ──── thread blocks waiting for next event ───────────┤
│  render server animates on its own clock                    │
└─ afterWaiting ─ process the event that woke us → next tick ─┘
```

Load-bearing consequences:

- **Source-phase scroll / frame writes need the geometry they depend on already settled.** Anything in source phase that reads or writes lazy AppKit geometry (NSTableView row tile, NSClipView `constrainBoundsRect` against documentView.frame, NSScrollView tile) must have already triggered that geometry. Two ways to do that, in order of preference: (a) let the host's `view.layoutSubtreeIfNeeded()` size the subtree from its current frame — a size change to a freshly-attached scroll-host child cascades into the table and `NSTableView.tile()` runs inline **only if the table's `dataSource` is bound at that moment**; if `dataSource` is bound later (the transcript's actual attach pattern), the tile fires on the next `layoutSubtreeIfNeeded` to run with dataSource bound (in the transcript's case, `controller.scrollToTail()`'s internal `tableView.layoutSubtreeIfNeeded()`); (b) explicitly invalidate via `noteNumberOfRowsChanged` / `insertRows` / `reloadData(forRowIndexes:)` if no enclosing frame change is going to happen. Writing first and waiting hands you a one-frame visual glitch.
- **`view.layoutSubtreeIfNeeded()` flushes autolayout, AND that triggers a chain of side effects that look like "not autolayout."** NSTableView's row layout, for example, is not directly an autolayout product — but the table's tile is gated on FRAME changes, and autolayout drives frame changes, so flushing the parent's autolayout transitively drives the table's tile when the table's size changes. The fragile case is the one where the table's frame *doesn't* change (e.g. a sibling-only invalidation, or `tableView.layoutSubtreeIfNeeded()` called on a table that's already at the right size); there `layoutSubtreeIfNeeded` is a no-op for row geometry and you have to invalidate explicitly. The takeaway: don't assume the doc surface ("autolayout product") is the boundary — frame-change-triggered re-tiles are the dominant case.
- **`@Observable` writes don't reach SwiftUI bodies in the same tick.** Bodies re-evaluate in beforeWaiting. Reading `model.foo` from a SwiftUI view that observes the source-of-truth right after your AppKit code wrote it won't show the new value until the next display.
- **`.task { }` / `withObservationTracking` re-arm hops are async.** They post a Task that resumes on a future source phase — never inside the same tick as the change that fired them. Anything order-sensitive must be done inline, not through one of these hops.
- **Implicit CALayer animations commit at beforeWaiting too.** Multiple model writes during one source phase coalesce into one transaction; wrap them in `CATransaction.setDisableActions(true)` + `NSAnimationContext.allowsImplicitAnimation = false` if you need them composited without animation rather than crossfaded.

Two stack-trace aliases worth memorising:

- `__CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__` → you're inside a runloop observer (almost always CoreAnimation's beforeWaiting flush or SwiftUI's invalidation observer).
- `__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__` → source phase, draining `DispatchQueue.main`.

Subsystem-specific corollaries (e.g. the transcript's `clip.scroll` / NSTableView tile choreography) live next to the code; the diagram above is the only thing that's truly global.

## Where to read more

Detailed conventions live next to the code they govern. When you touch one of these areas, read its `CLAUDE.md` first.

| Area | Doc |
|---|---|
| Chat UI assembly (MainWindow / Detail router + VCs / transcript swap / InputBar) | [Content/Chat/CLAUDE.md](macos/ccterm/Content/Chat/CLAUDE.md) |
| Sidebar (outline VC / tree model / context menu / cells) | [Sidebar/CLAUDE.md](macos/ccterm/Sidebar/CLAUDE.md) |
| `Session` / `SessionRuntime` runtime, render-side comms, mutation rules | [Services/Session/CLAUDE.md](macos/ccterm/Services/Session/CLAUDE.md) |
| Native transcript internals (layouts, diff, tool rendering) | [Content/Chat/NativeTranscript2/CLAUDE.md](macos/ccterm/Content/Chat/NativeTranscript2/CLAUDE.md) |
| Unit test conventions (parallel safety, in-memory fixtures) | [cctermTests/CLAUDE.md](macos/cctermTests/CLAUDE.md) |

## Directory layout

```
ccterm/
├── macos/                    # macOS platform
│   ├── ccterm.xcodeproj/
│   ├── ccterm/               # App sources
│   │   ├── App/              # CCTermApp, AppState; AppKit/ holds AppDelegate + MainWindowController + split + detail VC
│   │   ├── Sidebar/          # SidebarViewController + cell views + group-order store
│   │   ├── Components/       # Reusable SwiftUI / AppKit components
│   │   │   └── Markdown/     # GFM parser → internal IR (consumed by NativeTranscript2)
│   │   ├── Content/          # Top-level content panes
│   │   │   ├── Chat/         # InputBarView2 / NewSessionConfigurator / InputBarControls / Completion
│   │   │   │   ├── NativeTranscript2/        # NSTableView-based transcript
│   │   │   │   └── NativeTranscript2Bridge/  # MessageEntry → Block translation
│   │   │   ├── TranscriptDemo/   # Offline demos and stress harness
│   │   │   ├── Settings/         # App settings
│   │   │   └── LogViewer/        # Log window
│   │   ├── Models/           # Data models (SyntaxToken, PermissionMode, ...)
│   │   ├── Services/         # Service layer
│   │   │   ├── Session/      # Session / SessionRuntime / SessionManager / SessionRepository / Worktree
│   │   │   └── Logging/      # AppLogger / MainThreadWatchdog
│   │   ├── Extensions/       # Foundation / AppKit extensions
│   │   └── Resources/        # Assets.xcassets and other resources
│   ├── AgentSDK/             # Swift SDK package
│   ├── Config.xcconfig
│   └── scripts/              # build.sh / test.sh / ...
├── thirdparty/
│   └── fzf/                  # git submodule
└── Makefile                  # Single build entry point
```

Organize by feature, not by file type. New feature → new directory.

The Xcode project uses filesystem-synced groups (`PBXFileSystemSynchronizedRootGroup`), so files added/removed/moved on disk show up in the build automatically. Never hand-edit `project.pbxproj` to register new files.

## Prerequisites

- **macOS 14 (Sonoma)** or newer.
- **Xcode** — after install, run `xcodebuild -runFirstLaunch` once to initialize command-line tools.
- **Go** — the `thirdparty/fzf` submodule is compiled from Go sources inside an Xcode build phase. `brew install go` or grab a tarball from <https://go.dev/dl/>.
- **swift-format** — `brew install swift-format`. Apple's official formatter; `make fmt` / `make fmt-check` invoke it via `PATH`. We don't use the Xcode-bundled copy because it requires Xcode 16+ (macOS 14.5+); brew works on any supported macOS.
- **Git submodules** — the first `make build` initializes them automatically; you can also run `git submodule update --init --recursive` manually.

## Build

Always go through `make`. Do not call `macos/scripts/*.sh` directly.

```bash
make build       # Debug build
make release     # Release build
make clean       # Wipe build artifacts
make fmt         # Format code (xcstrings, ...)
```

- Run `make fmt` before opening a PR.
- The scripts under `macos/scripts/` are already on the sandbox `excludedCommands` list, so `make` invocations do not need `dangerouslyDisableSandbox`.
- `make build` prints only success/failure plus two log paths (summary + full log). On failure, read the summary first; only fall back to the full log when the summary isn't enough. Don't `tail` / `cat` the full log blindly.

## Tests

**Unit tests only** — one target, `cctermTests`. Two kinds of tests
live there:

- **Logic tests** (default) — bridge dispatch, history parsing, block
  builder, `Session` / `SessionRuntime` state transitions. Run on every PR.
- **Snapshot tests** — render a real SwiftUI view offscreen via
  `NSHostingController` and write a PNG. **Skipped on the default
  suite and on CI**; opt-in only. For visual review and self-check
  after a view edit. Filename convention `*SnapshotTests.swift`.

There is no XCUITest target — click / keystroke / focus flows are
covered by driving the session / bridge / controller directly from a
logic test.

```bash
make test-unit                                                  # logic tests only (snapshots skipped)
make test-unit FILTER=MessageEntryBlockBuilderTests             # one logic class
make test-unit FILTER=TranscriptDemoSnapshotTests               # opt-in: run a snapshot
```

### Visually verifying a view change (LLM self-check workflow)

After editing a SwiftUI view, render it and look at the PNG:

1. Find or add a `*SnapshotTests` class for the view.
2. `make test-unit FILTER=<ClassName>`
3. `open /tmp/ccterm-screenshots/<ViewName>.png` and inspect.

**Inventory of existing snapshots, how to add a new one, allowed
production-code seams, and troubleshooting** all live in
[cctermTests/CLAUDE.md § Snapshot tests](macos/cctermTests/CLAUDE.md#snapshot-tests).
Read that before adding any view-rendering test.

Unit tests do not steal focus and are safe to run locally. Pushing to
any PR branch triggers `.github/workflows/test.yml` (`make test-unit`)
as the merge gate; `xcresult` artifacts upload on failure.

## CI

Two workflows run on every PR:

- **`fmt.yml`** — `make fmt-check` (swift-format + xcstrings).
- **`test.yml`** — `make test-unit`. This is the merge gate.

### Build cache

`test.yml` caches `macos/build/test-dd` (Xcode DerivedData) and `fmt.yml` caches the Homebrew `swift-format` bottle. The cache key is composed of `runner OS+arch + Xcode version + fzf submodule SHA + .github/cache-salt + source file hash`, with a `restore-keys` fallback that drops the source hash so a same-PR retry reuses the previous cache and only recompiles changed files.

**If incremental builds go bad** (stale `.swiftmodule` causing link errors that don't reproduce on a `make clean` build locally): bump `.github/cache-salt` — change the contents (any edit; bumping the integer is fine) and commit. The next CI run misses the cache, builds from scratch, and seeds a fresh cache for everyone.

## Logging

Use `appLog()` (`Services/Logging/AppLogger.swift`). Never `NSLog` or `print` directly.

```swift
appLog(.info, "SessionRuntime", "send() queued — status=\(status)")
```

| Level | Use for |
|---|---|
| `.debug` | Dev-time diagnostics; only useful when chasing a specific bug |
| `.info` | Normal flow events (session start/stop, navigation, status transitions) |
| `.warning` | Recoverable anomalies |
| `.error` | Failures that affect features |

- Category = class name without module prefix (`"SessionRuntime"`, `"TranscriptDetailVC"`).
- Never log secrets (tokens, passwords, API keys).
- Visible in Console.app (filter by subsystem `com.ccterm.app`). Live tail: `log stream --predicate 'subsystem == "com.ccterm.app"' --level debug`.

### Streaming logs from the terminal — `make logs`

`make logs` live-tails the unified log for **the build product of the current worktree only**. This matters because you'll often have the Release build plus one or more Debug builds (from other worktrees) running at once — they share a log subsystem, but `make logs` follows only the binary this checkout produces, so you never have to guess which window you're reading.

```bash
make logs                          # this worktree's Debug build, info level, all categories
make logs LEVEL=debug              # include .debug lines (default is info)
make logs CATEGORY=SessionRuntime  # only one os_log category
make logs CONFIG=release           # follow the Release build instead of Debug
make logs CONFIG=release CATEGORY=TranscriptDetailVC LEVEL=debug  # combine freely
```

`CONFIG` (`debug`/`release`), `CATEGORY` (any `appLog` category), and `LEVEL` (`default`/`info`/`debug`) are all optional and independent. Just build, launch the app, and run `make logs` in a second terminal; Ctrl-C to stop.

## Internationalization

Strings live in `Localizable.xcstrings`. Source language is English; `zh-Hans` is the translation. macOS locale switches automatically; English is the fallback.

**What needs localizing:**

| Localize | Do not localize |
|---|---|
| User-visible UI copy (buttons, titles, prompts, placeholders, menu items, empty states, confirmation dialogs) | Logs, assertion messages, internal identifiers |
| User-visible enum display names (e.g. `PermissionMode.title`) | Raw values / keys passed to the CLI or API |
| `NSOpenPanel.message`, `.help()` tooltips | Code comments, `#Preview` titles |

**How to write it — pick by context:**

| Context | Form |
|---|---|
| SwiftUI literals: `Text("…")`, `Button("…")`, `Label("…", systemImage:)`, `.navigationTitle("…")`, `.confirmationDialog("…")` | Write the English literal directly. The compiler infers `LocalizedStringKey` and looks it up in the catalog. |
| Computed `String` properties / call sites that take `String` | `String(localized: "…")` (e.g. `PermissionMode.title`) |
| With interpolation | `String(localized: "\(count) items")` — the xcstrings key becomes `"%lld items"` |
| Conditional expression passed as `String` | Wrap both branches: `state.isTempDir ? String(localized: "Temporary Session") : path` |

**Key conventions:**
- Keys are English source text, not snake-case IDs.
- Title case for titles/buttons (`"New Conversation"`); sentence case for descriptions (`"Select primary directory and additional directories"`).

**Adding a string:**
1. Write the English key in code (using the form from the table above).
2. Add the key + `zh-Hans` translation to `Localizable.xcstrings`.
3. Both steps must land together. Never ship a code change without the translation.

## Naming

Follow the Swift API Design Guidelines, plus: suffix `View` / `Service` / `Delegate` / `Coordinator` where the role applies. Data models carry no suffix. For AppKit view/control/layer/controller types specifically, see [§ AppKit component naming](#appkit-component-naming) below.

## AppKit component naming

The chat / transcript detail page is now AppKit-by-default (the SwiftUI compose chain, permission card, pickers, completion popup, sheets, and compose/draft surfaces were ported to `NSView` / `NSControl` / `NSViewController`). The page is dense with custom-drawn leaves and coordinator objects, so an honest suffix is the difference between a name that tells you the base class at the call site and one that lies about it. This rule governs every `NSView` / `NSControl` / `CALayer` / `NSViewController` across `Components/`, `Content/Chat/AppKit/`, `Sidebar/`, and `App/AppKit/`.

**The type suffix must name the honest AppKit base class or role — never a more impressive-sounding term, and never a filler word bolted on to dodge a name clash.**

| Base class / role | Suffix | Conforming example | Why |
|---|---|---|---|
| `NSView` subclass | `...View` | `AttachmentStripView`, `ChromeRowView`, `DotGridView`, `PermissionCardHostView` (`Content/Chat/AppKit/PermissionCard/PermissionCardHostView.swift`) | A layer-backed view that draws via `CALayer`s is still a *view*. |
| `NSControl` subclass (target/action, interactive role) | role word, **no** trailing `View` (`...Button`) | `SendStopButton`, `ChromeButton`, `AttachButton`, `PermissionDecisionButton` | A control is not a view-with-a-suffix; `...ButtonView` on an `NSControl` is wrong. |
| `CALayer` subclass | `...Layer` | (none on the chat page — see below) | `...Layer` is **reserved for actual `CALayer` subclasses**; never put it on an `NSView`. |
| `NSViewController` subclass | `...ViewController` (IS-A) | `AskUserQuestionCardViewController`, `ImagePreviewSheetViewController`, `ContextBreakdownContentViewController` | …**except** the established coordinator/owner set below. |
| Lifecycle / state-machine coordinator (owns a lifecycle, not a view tree) | bare `...Controller` | `InputBarController`, `PermissionCardController`, the picker controllers (`ChromePickerController` / `PermissionModePickerController` / `ModelEffortPickerController` / `ContextRingPickerController` / `BackgroundTaskPickerController` / `TodoPickerController`) | Sanctioned exception; coordinator first. `InputBarController` happens to subclass `NSViewController` but is named for its coordinator role, not its base class — do not "promote" it to `...ViewController`. |
| Pure-computation helper (no drawing surface, no `CALayer`) | `...Layout` / `...Geometry` / `...Metrics` / `...Format` | `CompletionListLayout`, `ContextBarLayout`, `BackgroundTaskFormat`, `GlassBackgroundGeometry` | Never name a pure-math helper with a `CALayer`/animation term like `...Layer`. |
| Coordinator / Presenter role | `...Coordinator` / `...Presenter` (as-is) | `TranscriptSwapCoordinator`, `Transcript2Coordinator`, `ImagePreviewPresenter`, `BackgroundTaskDetailPresenter`, `Transcript2SheetPresenter` | The role suffixes already sanctioned by `## Naming`. |
| Static-string / localized-copy provider | `...Strings` | `PermissionCardStrings` | Never bare `...Copy` — `Copy` reads as the clipboard verb / ⌘C, not "the prose strings." |

Three meta-rules behind the table:

- **`...Layer` is reserved for `CALayer` subclasses, full stop.** A layer-backed `NSView` that happens to draw via `CALayer`s is a *View*. (Worked: `ProgressRingLayer` → `ProgressRingView` and `TodoStatusGlyphLayer` → `TodoStatusGlyphView` were both `final class …: NSView` mis-suffixed `...Layer`; corrected homes are `Components/ProgressRingView.swift` and `Components/TodoStatusGlyphView.swift`.)
- **Don't add a filler word (`View`, `Impl`, `Box`, `Container`) just to dodge a clash with a symbol you're deleting in the same change.** Delete the dead symbol first, then take the clean name. (Worked: `PermissionDecisionButtonView` → `PermissionDecisionButton` and `AttachButtonView` → `AttachButton` — both `NSControl`s wore a `View` filler only to avoid colliding with the then-still-present SwiftUI structs, now deleted; corrected homes `…/PermissionCard/PermissionDecisionButton.swift` and `Content/Chat/AppKit/AttachButton.swift`. Also `PermissionCardLayerView` → `PermissionCardHostView`: it is the click-through full-pane host, not a `CALayer`, so the dishonest `LayerView` became the honest `HostView`.)
- **When a glass/translucent surface and an opaque surface co-exist as siblings, encode the material in the name** so the distinction is legible at the call site; when there's only one, the plain name is fine. (Worked: the glass `BarSurfaceView` → `GlassBackgroundView` — "BarSurface" alone doesn't say *glass*, and its opaque sibling `OpaqueCardBackgroundView`, documented "OPAQUE, not glass §4.4-1", makes the distinction load-bearing.)

These renames are descriptive of an applied ledger, not aspirational — every "before" above already existed in its violating form and was corrected in the AppKit-migration rename phase. Cite them as the worked shape of the rule; don't regress them, and don't propose renaming the sanctioned bare-`...Controller` coordinator set (that would contradict both the migration plan and `## Naming`).

## Workflow conventions

- **PR titles and bodies are English.**
- **Worktrees**: when working inside a git worktree, default to reading and writing files under the worktree path. Don't touch the main checkout unless asked.
- **Inline scripts**: any ad-hoc Bash / Python / JavaScript longer than 5 lines must be written to a file first (project root or `/tmp`, named like `tmp_analyze.py`), executed, and deleted. No long heredocs on the command line.
- **Debug / scratch downloads always go to `/tmp`, never the repo.** Tools that default to the current working directory will dump into the worktree and get swept into your next `git add -A`. Common offenders + the explicit flag to set:
  - `gh run download <run> --dir /tmp/<name>` (otherwise dumps `<artifact-name>/` into cwd — xcresult bundles are ~2000 binary files)
  - `curl -o /tmp/<file> …` (don't `curl` without `-o`)
  - `xcrun xcresulttool export … --output-path /tmp/<dir>`

  If a one-off artifact does land in the worktree, `rm -rf` it before staging — never let `git add -A` decide. As a safety net, `/tmp` style scratch dirs (e.g. `xcresult/`, `tmp_*/`) belong in `.gitignore`.
- **Waiting for a PR**: run `scripts/wait-for-pr.sh <pr#>` with `run_in_background: true`. It blocks until a terminal state (`READY` / `CHECKS_FAILED` / `CONFLICT` / `REVIEW_CHANGES_REQUESTED` / `MERGED` / `CLOSED` / `TIMEOUT` / `NO_CHECKS`) and prints a one-line summary + JSON. Never foreground-poll `gh pr checks` / `gh pr view` in a sleep loop.
- **Syncing a branch with `main`**: always use `git merge origin/main` (or `gh pr update-branch`). **Never `git rebase`** — rebase rewrites the PR branch's history, which breaks the GitHub review thread, invalidates existing review comments' line anchors, and forces every collaborator to reset their local branch. Conflict resolution happens on a merge commit instead. The squash-merge at the end collapses these merge commits anyway, so the `main` branch's history stays linear.
- **Squash-merging a PR**: always pass an explicit message (`gh pr merge <#> --squash --subject "…" --body "$(cat <<'EOF' … EOF)"`). The default GitHub message is the PR title + a list of every individual commit on the branch — noisy and unhelpful in `git log`. Write a clean single-purpose subject + body that mirror the PR description.
- **Killing the app**: only kill Debug builds of `ccterm`. Never kill a Release build — that is the user's daily-driver instance and may hold unsaved session state. Before any `kill` / `pkill` / `killall ccterm`, confirm the target PID belongs to a Debug build (e.g. `ps -o command= -p <pid>` shows a path under `macos/build/` / `DerivedData/`, not `/Applications/`). If you cannot prove it is Debug, do not kill it — ask the user.

## Engineering principles

- **Never compromise production code to make tests pass.** If a test can't reach a real production control, the fix is in the **test**, not the product. Forbidden patterns: gating real behavior on an env var to bypass logic, exposing internal state through `forceXxxForTest()` methods, widening access purely for a test hook. The right answer is to drive the public surface — call the handle method, fire the bridge event, feed the controller — and assert on the observable result.

### Explicitly not done

Deliberate non-goals — don't "clean these up" without re-reading the reasoning above:

- Don't make the router observe selection via `withObservationTracking` — it breaks the source-phase structural swap (#195). The router reads `model.selection` only through the synchronous `selectionObserver` callback.
- Don't introduce a global store / Redux / chat-area ViewModel — it would flatten the process / window / session scopes and force every transcript delta through a reducer.
- Don't inject `AppState` wholesale via `.environment` — `model` isn't on `AppState`; pass the `SidebarContext` / `DetailContext` bags instead.
- Keep `ModelStore` and the completion stores (`FileCompletionStore` / `SlashCommandStore`) as `.shared` — they're process / per-cwd caches (`ModelStore` spawns a CLI subprocess), not injected services.
- Don't merge `ComposeSessionViewController` + `DraftSessionLandingViewController` — distinct lifecycles.

# CCTerm

Native macOS client for Claude Code. SwiftUI + AppKit, minimum target macOS 14 (Sonoma).

## Architecture at a glance

- **UI framework — SwiftUI by default, AppKit by exception.** Reach for AppKit only when SwiftUI cannot meet the requirement (performance, lifecycle timing, or a missing capability). The current AppKit footprint is:
  - **Chat transcript** — `NSTableView` + Core Text self-drawn (`NativeTranscript2`). SwiftUI's `List` / `LazyVStack` cannot keep up with the row count, custom layout, and selection semantics.
  - **Main window root** — `MainWindowController` + `MainSplitViewController` + `TranscriptDetailViewController`. The transcript's mount and `frameDidChange` cascade must run in AppKit's source phase, not SwiftUI's commit pass.
  - **Window toolbar** — `NSToolbar` + `NSSearchToolbarItem`; `.searchable` doesn't give the first-responder + ⌘F semantics the transcript search needs.
  - **App lifecycle** — `AppDelegate` (via `@NSApplicationDelegateAdaptor`) owns app-scope state and creates the main window in `applicationDidFinishLaunching`.

  Everything else — sidebar, input bar, configurator, overlays, Settings / Logs / About windows, every reusable component — is SwiftUI, hosted via `NSHostingController` (full panes) or `NSHostingView` (toolbar items / overlays). New code lands in SwiftUI unless it fits one of the exceptions above; introducing a new AppKit surface needs an explicit reason (perf measurement, missing API, lifecycle ordering).

- **Entry point**: `@main CCTermApp` (SwiftUI `App`) → `@NSApplicationDelegateAdaptor(AppDelegate.self)` → `MainWindowController` → `MainSplitViewController` (sidebar item + detail item) → `TranscriptDetailViewController`. Selection / draft state lives on `MainSelectionModel` (`@Observable`), shared between the hosted `SidebarView2` and the AppKit detail VC. Settings / Logs / About remain SwiftUI `Window` scenes; their menu items + ⌘F binding come from `AppCommands` (a SwiftUI `Commands` block on the Settings scene) so cold-start clicks resolve `@Environment(\.openWindow)` cleanly.
- **Layers**:
  - **Model** — plain data, `struct` first, `Codable` where it crosses a boundary.
  - **View** — SwiftUI structs, declarative.
  - **Service** — `@Observable`, injected via initializer or `.environment()`. Views never construct services themselves.
  - **AppState** — process-scope container owned by `AppDelegate`, injected through `.environment()`. Currently holds `SessionManager`, `SyntaxHighlightEngine`, `RecentProjectsStore`, `InputDraftStore`, `AppActivationTracker`, `NotificationService`.

### SwiftUI rules

- `@Observable` for state shared across views (e.g. `Session`); `@State` for view-private UI state; `@Binding` for writable references from a parent.
- Put reusable SwiftUI components under `Components/`.
- If a `body` runs past ~40 lines, split it: child views with their own state become separate `View` structs (and usually their own files); pure layout becomes a computed property or `@ViewBuilder` helper.
- No expensive work inside `body`. Long lists use `NativeTranscript2`, never `List` / `LazyVStack`.
- `ForEach` ids must be stable.
- Load data with `.task { }`; react to dependency changes with `.task(id:)` or `.onChange(of:)`. Never trigger side effects from the body construction path.

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

- **Source-phase scroll / frame writes need the geometry they depend on already settled.** Anything in source phase that reads or writes lazy AppKit geometry (NSTableView row tile, NSClipView `constrainBoundsRect` against documentView.frame, NSScrollView tile) must have already triggered that geometry. Two ways to do that, in order of preference: (a) let the host's `view.layoutSubtreeIfNeeded()` size the subtree from its current frame — for a freshly-attached scroll-host child, the size change cascades into the table and `NSTableView.tile()` runs inline; (b) explicitly invalidate via `noteNumberOfRowsChanged` / `insertRows` / `reloadData(forRowIndexes:)` if no enclosing frame change is going to happen. Writing first and waiting hands you a one-frame visual glitch.
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
| Chat UI assembly (MainWindow / Sidebar / Detail VC / InputBar / pill) | [Content/Chat/CLAUDE.md](macos/ccterm/Content/Chat/CLAUDE.md) |
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
│   │   ├── Sidebar/          # SidebarView2
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

- Category = class name without module prefix (`"SessionRuntime"`, `"ChatHistoryView"`).
- Never log secrets (tokens, passwords, API keys).
- Live tail: Window → Logs (⌘⇧L). Also mirrored to `os.Logger`, visible in Console.app for history.

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

Follow the Swift API Design Guidelines, plus: suffix `View` / `Service` / `Delegate` / `Coordinator` where the role applies. Data models carry no suffix.

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

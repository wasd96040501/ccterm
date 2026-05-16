# CCTerm

Native macOS client for Claude Code. SwiftUI + AppKit, minimum target macOS 14 (Sonoma).

## Architecture at a glance

- **UI**: SwiftUI everywhere except the chat transcript, which is `NSTableView` + Core Text self-drawn. Bridged through `NSViewRepresentable` (e.g. `NativeTranscript2View`, `InputTextView`). No XIB / Storyboard / `NSHostingController`.
- **Entry point**: `@main CCTermApp` → `Window` scene → `RootView2` (a `NavigationSplitView`) → `SidebarView2` + detail. `RootView2` owns `selectedSessionId` / `draftSessionId` locally; there is no global router.
- **Layers**:
  - **Model** — plain data, `struct` first, `Codable` where it crosses a boundary.
  - **View** — SwiftUI structs, declarative.
  - **Service** — `@Observable`, injected via initializer or `.environment()`. Views never construct services themselves.
  - **AppState** — a thin global container that only holds `SessionManager2` and `SyntaxHighlightEngine`, injected through `.environment()`.

### SwiftUI rules

- `@Observable` for state shared across views (e.g. `SessionHandle2`); `@State` for view-private UI state; `@Binding` for writable references from a parent.
- Put reusable SwiftUI components under `Components/`.
- If a `body` runs past ~40 lines, split it: child views with their own state become separate `View` structs (and usually their own files); pure layout becomes a computed property or `@ViewBuilder` helper.
- No expensive work inside `body`. Long lists use `NativeTranscript2`, never `List` / `LazyVStack`.
- `ForEach` ids must be stable.
- Load data with `.task { }`; react to dependency changes with `.task(id:)` or `.onChange(of:)`. Never trigger side effects from the body construction path.

## Where to read more

Detailed conventions live next to the code they govern. When you touch one of these areas, read its `CLAUDE.md` first.

| Area | Doc |
|---|---|
| Chat UI assembly (RootView2 / Sidebar / ChatHistory / InputBar / pill) | [Content/Chat/CLAUDE.md](macos/ccterm/Content/Chat/CLAUDE.md) |
| `SessionHandle2` runtime, render-side comms, mutation rules | [Services/Session/CLAUDE.md](macos/ccterm/Services/Session/CLAUDE.md) |
| Native transcript internals (layouts, diff, tool rendering) | [Content/Chat/NativeTranscript2/CLAUDE.md](macos/ccterm/Content/Chat/NativeTranscript2/CLAUDE.md) |
| UI test infrastructure and writing conventions | [cctermUITests/CLAUDE.md](macos/cctermUITests/CLAUDE.md) |

## Directory layout

```
ccterm/
├── macos/                    # macOS platform
│   ├── ccterm.xcodeproj/
│   ├── ccterm/               # App sources
│   │   ├── App/              # CCTermApp, AppState, RootView2
│   │   ├── Sidebar/          # SidebarView2
│   │   ├── Components/       # Reusable SwiftUI / AppKit components
│   │   │   └── Markdown/     # GFM parser → internal IR (consumed by NativeTranscript2)
│   │   ├── Content/          # Top-level content panes
│   │   │   ├── Chat/         # ChatHistoryView / InputBarView2 / LoadingPillView2
│   │   │   │   ├── NativeTranscript2/        # NSTableView-based transcript
│   │   │   │   └── NativeTranscript2Bridge/  # MessageEntry → Block translation
│   │   │   ├── TranscriptDemo/   # Offline demos and stress harness
│   │   │   ├── Settings/         # App settings
│   │   │   └── LogViewer/        # Log window
│   │   ├── Models/           # Data models (SyntaxToken, PermissionMode, ...)
│   │   ├── Services/         # Service layer
│   │   │   ├── Session/      # SessionHandle2 / SessionManager2 / SessionRepository / Worktree
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

End-to-end via XCUITest. No unit tests (`cctermTests/` is a stub).

**Run on CI, not locally, by default.** UI tests grab focus on the foreground app and drive keyboard/mouse, which is disruptive on your desktop. Pushing a PR triggers the `ui-test` workflow (`.github/workflows/test.yml`) which runs the full suite. Logs and `xcresult` artifacts land on the Actions page.

Only run locally when you need to reproduce a CI failure or you're debugging the UI tests themselves:

```bash
make test FILTER=InputBar2StopButtonUITests/testStopButtonCancelsRunningState   # one method
make test FILTER=InputBar2StopButtonUITests                                     # one class
make test-all                                                                   # full suite (slow; pre-merge gut check only)
```

The full suite is slow (10–30s per test) and steals focus — never default to running it locally.

Full UI test infrastructure (mock CLI, in-memory session repo, scenario authoring, identifier conventions) is documented in [cctermUITests/CLAUDE.md](macos/cctermUITests/CLAUDE.md).

## Logging

Use `appLog()` (`Services/Logging/AppLogger.swift`). Never `NSLog` or `print` directly.

```swift
appLog(.info, "SessionHandle2", "send() queued — status=\(status)")
```

| Level | Use for |
|---|---|
| `.debug` | Dev-time diagnostics; only useful when chasing a specific bug |
| `.info` | Normal flow events (session start/stop, navigation, status transitions) |
| `.warning` | Recoverable anomalies |
| `.error` | Failures that affect features |

- Category = class name without module prefix (`"SessionHandle2"`, `"ChatHistoryView"`).
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

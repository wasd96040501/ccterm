# CCTerm

Native macOS client for Claude Code. Pure AppKit (Swift), programmatic, minimum target macOS 14 (Sonoma).

The app is a main window — a sidebar listing every session transcript on disk (`AgentSDK`'s `SessionDirectory`, grouped by project) beside a tabbed, splittable editor area that shows them read-only (`TranscriptKit`'s view and workspace) — plus Settings and About. Running a live session is not wired yet.

## Where to read more

This file holds repo-wide commands and workflow. Engineering conventions and area rules live next to the code — when you touch an area, read its `CLAUDE.md` first.

| Area | Doc |
|---|---|
| **AppKit conventions + runloop tick model** (layering, DI, containment, views, lists, concurrency) — applies to all Swift | [macos/CLAUDE.md](macos/CLAUDE.md) |
| The app's transcript tab — page model, run rows, documents beside | [macos/ccterm/Content/Transcript/CLAUDE.md](macos/ccterm/Content/Transcript/CLAUDE.md) |
| `TranscriptKit` package — the transcript view (API rules, internals, media, workspace, tests) | [macos/TranscriptKit/CLAUDE.md](macos/TranscriptKit/CLAUDE.md) |
| App unit tests (parallel safety, snapshots, measurement probes) | [cctermTests/CLAUDE.md](macos/cctermTests/CLAUDE.md) |
| AppKit verification harness (real-tree mount, geometry / animation / interaction probes) | [cctermTests/Harness/CLAUDE.md](macos/cctermTests/Harness/CLAUDE.md) |
| AgentSDK package + real-CLI smoke executables | [macos/AgentSDK/CLAUDE.md](macos/AgentSDK/CLAUDE.md) |

## Directory layout

```
ccterm/
├── macos/
│   ├── ccterm.xcodeproj/
│   ├── ccterm/               # App sources
│   │   ├── App/              # CCTermApp + menu commands; AppKit/ holds AppDelegate (composition root) + window controllers + main split
│   │   ├── Content/          # About/, Settings/, Sidebar/ (session outline), Transcript/ (a transcript tab)
│   │   ├── Library/          # LibraryStore — the session tree on disk, and reading one transcript
│   │   ├── Git/              # GitService — a folder's branch, live
│   │   ├── Logging/          # appLog, main-thread watchdog
│   │   └── Resources/
│   ├── cctermTests/          # The app's only test target
│   ├── TranscriptKit/        # Standalone SwiftPM package (own tests, own demo)
│   ├── AgentSDK/             # Swift SDK package over the claude CLI
│   ├── Config.xcconfig
│   └── scripts/              # build.sh / test.sh / … — invoked via make only
└── Makefile                  # Single build entry point
```

Organize by feature, not by file type; a new feature gets a new directory. The Xcode project uses filesystem-synced groups, so files added/moved on disk join the build automatically — never hand-edit `project.pbxproj` to register files.

## Prerequisites

- macOS 14+, Xcode (run `xcodebuild -runFirstLaunch` once after install).
- **swift-format** — `brew install swift-format` (not Xcode's bundled copy, which needs Xcode 16+).

## Commands

Always go through `make`; never call `macos/scripts/*.sh` directly. (Those scripts are on the sandbox `excludedCommands` list, so `make` needs no `dangerouslyDisableSandbox`.)

```bash
make build                           # Debug build
make release                         # Release build
make clean
make fmt / make fmt-check            # swift-format + xcstrings
make test-unit                       # app logic tests (snapshots skipped)
make test-unit FILTER=<Class>[/testMethod]   # one class/method; naming a *SnapshotTests class runs it
make test-kit [FILTER=<Class>]       # TranscriptKit package tests
make test-sdk [FILTER=<Class>]       # AgentSDK package tests
make demo-kit                        # TranscriptKit demo app (foreground; close window to stop)
make logs [CONFIG=release] [CATEGORY=X] [LEVEL=debug]   # tail unified log of THIS worktree's build
make appkit-doc SYMBOL=NSTableView   # Apple's DocC for an AppKit symbol
make arch [SCOPE=core|app|kit|sdk|<dir>|<unit>]   # architecture map → build/arch/ (what /arch-review reads)
```

`make build` prints success/failure plus two log paths. On failure read the summary log first; open the full log only if the summary isn't enough — don't `tail`/`cat` it blindly.

## Tests

Unit tests only — no XCUITest target. Three suites, all merge gates: `cctermTests` (`make test-unit`), TranscriptKit's own (`make test-kit`) and AgentSDK's own (`make test-sdk`); the package suites stay separate so each package is testable without the app. Click / keystroke / focus flows are tested by driving the session / bridge / controller directly. `*SnapshotTests.swift` files render a view to a PNG for **visual review**; they're skipped by default and on CI and run only when named with `FILTER`.

After editing a view, verify it visually: find or add its `*SnapshotTests` class, `make test-unit FILTER=<Class>`, then `open /tmp/ccterm-screenshots/<Name>.png` and look. Details in [cctermTests/CLAUDE.md](macos/cctermTests/CLAUDE.md).

## CI

Every PR runs `fmt.yml` (`make fmt-check`) and `test.yml` (three jobs: `test` → `make test-unit`, `test-kit` → `make test-kit`, `test-sdk` → `make test-sdk`; the package jobs need no Xcode project). `test.yml` caches DerivedData (`macos/build/test-dd`), keyed on runner + Xcode + `.github/cache-salt` + source hash. **If incremental CI builds go bad** (stale `.swiftmodule` link errors that don't reproduce after local `make clean`), edit `.github/cache-salt` and commit to force a cold build.

## Logging

Use `appLog()` (`Logging/AppLogger.swift`); never `NSLog` / `print`.

```swift
appLog(.info, "SessionRuntime", "send() queued — status=\(status)")
```

- Levels: `.debug` (bug-chasing only), `.info` (normal flow: start/stop, navigation, status transitions), `.warning` (recoverable), `.error` (feature-affecting failure).
- Category = class name without module prefix. Never log secrets.
- Subsystem `com.ccterm.app`. `make logs` follows only the binary this worktree built, so it never mixes with the Release build or other worktrees' Debug builds.

## Internationalization

Strings live in `Localizable.xcstrings`; source is English, `zh-Hans` is the translation.

- **Localize** user-visible copy: control titles, labels, menu items, placeholders, empty states, alerts, enum display names (`PermissionMode.title`), `NSOpenPanel.message`, tooltips. **Don't localize** logs, assertions, identifiers, raw values sent to the CLI/API.
- Form: `String(localized: "…")`; interpolation `String(localized: "\(count) items")` → key `"%lld items"`; a conditional wraps both branches.
- Keys are the English text. Title Case for titles/buttons, sentence case for descriptions.
- The code change and its `zh-Hans` entry land in the same commit — never one without the other.

## Workflow conventions

- PR titles and bodies are English.
- In a worktree, read and write under the worktree path; don't touch the main checkout unless asked.
- Ad-hoc scripts longer than 5 lines go to a file (`/tmp/tmp_*.py` etc.), run, then delete — no long heredocs on the command line.
- Scratch downloads go to `/tmp`, never the repo: `gh run download <run> --dir /tmp/<name>`, `curl -o /tmp/<file>`, `xcrun xcresulttool export … --output-path /tmp/<dir>`. If an artifact lands in the worktree, `rm -rf` it before staging.
- Waiting for a PR: `scripts/wait-for-pr.sh <pr#>` with `run_in_background: true`; it returns on a terminal state. Never foreground-poll `gh pr checks`.
- Squash-merge with an explicit message: `gh pr merge <#> --squash --subject "…" --body "…"` mirroring the PR description, not GitHub's commit list.
- **Killing the app:** only Debug builds of `ccterm` (`ps -o command= -p <pid>` shows a path under `macos/build/` / `DerivedData/`). Never kill a Release build (`/Applications/`) — it's the user's daily driver. If you can't prove it's Debug, ask.

## PR workflow

- **Branch first.** Before the first edit: `git fetch origin && git checkout -b <semantic-name> origin/main`. The worktree's session-id branch name says nothing about the work.
- **Commit as you go**, one complete semantic change per commit (a fix + its test; a refactor that leaves the suite green).
- **History is append-only, on every branch.** Integrate with `git merge origin/main` (or `gh pr update-branch`), never `git rebase`. Never collapse a branch's commits (`reset --soft`, `rebase -i`) — the squash merge does that. Never `git push --force`; if a push is rejected, merge `origin/<branch>` and push again.
- **Open the PR only when it's ready to merge.** Pushing a branch without a PR runs no workflow (free backup); once a PR exists every push buys a full CI run (~25 min macOS). Draft PRs bill the same.
- **All gates green locally before opening:** `make fmt-check`, `make test-unit`, `make test-kit`, `make test-sdk` (`make fmt` auto-fixes). Re-run every gate after every fix. A test failure is a real bug — never skip it to get green.
- **Red CI:** a job that ran no steps is a billing failure — read the annotation (`gh run view <id>`), not the colour. A job that ran and failed is real: `gh run download <run> --dir /tmp/<name>`, reproduce locally, push the verified fix — no speculative commits.
- **After a squash merge the branch is spent.** `git fetch origin && git checkout -B <fresh-name> origin/main`, delete the old branch locally and remotely. Never `git pull` to "fix" the divergence.

## Engineering principles

- **Never compromise production code to make tests pass.** If a test can't reach a real production control, fix the **test**: drive the public surface (call the handle method, fire the bridge event, feed the controller) and assert on the observable result. Forbidden: env-var-gated behavior, `forceXxxForTest()` methods, widening access purely for a test hook.
- **CLAUDE.md files record current rules and indexes, not history.** Write the rule and a one-line why; no "used to be", "was tried and removed", bug numbers, or measurement narratives. Anything that belongs to one type goes in that type's doc comment.

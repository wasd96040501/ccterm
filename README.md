# CCTerm

A native macOS app for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — a real Mac client instead of a terminal tab.

You get a proper sidebar of sessions (group them into folders, drag to reorder), a transcript that scrolls instantly even when the conversation gets long, responses that stream in live, and native permission prompts when Claude wants to run something. Built in SwiftUI + AppKit; runs on macOS 14 (Sonoma) and up.

## Install

Grab the latest signed, notarized `.dmg` from the [Releases](../../releases) page, open it, and drag CCTerm to your Applications folder.

Prefer to build it yourself? Read on.

## Build from source

You'll need:

- **macOS 14+** and **Xcode 26.3+** — run `xcodebuild -runFirstLaunch` once after installing.
- **Go** — the bundled `fzf` submodule is compiled during the build (`brew install go`).
- **Bun** — used to build the JavaScript bundles (`brew install oven-sh/bun/bun`, or see [bun.sh](https://bun.sh)).

Clone it (submodules and all):

```bash
git clone --recurse-submodules https://github.com/wasd96040501/ccterm.git
cd ccterm
```

Point the build at your signing identity — copy the template and drop in your Apple Developer Team ID (Xcode → Settings → Accounts):

```bash
cp macos/Local.xcconfig.template macos/Local.xcconfig
# then edit macos/Local.xcconfig:  DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Then build:

```bash
make build        # Debug build
make release      # Release build
make install      # build Release and copy it to /Applications
make clean        # wipe build artifacts
```

Always go through `make` — don't call the scripts under `macos/scripts/` directly. Forgot `--recurse-submodules`? The first `make build` initializes submodules for you.

## Develop

```bash
make test-unit                       # run the unit tests
make test-unit FILTER=<ClassName>    # run a single test class
make fmt                             # format sources (needs `brew install swift-format`)
make logs                            # tail this build's logs live
```

Run `make fmt` before opening a PR. Architecture and conventions live in [CLAUDE.md](CLAUDE.md), with more detailed notes in the per-area `CLAUDE.md` files next to the code they cover.

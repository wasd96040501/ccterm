# CCTerm

> WIP: This README is a work in progress.

A native macOS client for [Claude Code](https://docs.anthropic.com/en/docs/claude-code), built with SwiftUI.

## Prerequisites

- macOS 14 (Sonoma) or later
- Xcode 26.3+
- [Bun](https://bun.sh/) (for web frontend build)
- [Go](https://go.dev/dl/) (for fzf build)

## Getting Started

```bash
git clone --recursive https://github.com/wasd96040501/ccterm.git
cd ccterm
```

### Configure Code Signing

```bash
cp macos/Local.xcconfig.template macos/Local.xcconfig
```

Edit `macos/Local.xcconfig` and set your Apple Development Team ID:

```
DEVELOPMENT_TEAM = YOUR_TEAM_ID_HERE
```

> Find your Team ID: Xcode → Settings → Accounts → your account → Team ID column

### Build

```bash
make build
```

## Project Structure

```
ccterm/
├── macos/          # macOS app (SwiftUI)
├── web/            # Shared web frontend (React, rendered in WebView)
├── protocol/       # Cross-platform bridge protocol definitions
├── thirdparty/     # Third-party dependencies (fzf)
└── Makefile        # Build entry point
```

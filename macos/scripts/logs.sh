#!/bin/bash
# Stream unified logs for *this worktree's* ccterm build product only.
#
# Why a dedicated target: a developer commonly has the Release build
# (/Applications) plus one or more Debug builds from different worktrees
# running at once. They all share the same bundle id / log subsystem, so
# `log stream --predicate 'subsystem == "com.ccterm.app"'` would mix them.
# The one thing that *is* unique per worktree is the build product's path
# on disk — Xcode derives a per-project-path DerivedData directory, so the
# executable image path under `…/DerivedData/ccterm-<hash>/Build/Products/`
# differs for every checkout. We resolve that path the same way build.sh
# does (`xcodebuild -showBuildSettings`) and pin the stream to it via the
# `processImagePath` field, so `make logs` follows exactly the binary this
# checkout produces and nothing else.
#
# Usage (driven by the Makefile `logs` target):
#   ./scripts/logs.sh                       # Debug product, level info, all categories
#   CONFIG=release ./scripts/logs.sh        # Release product instead
#   CATEGORY=SessionRuntime ./scripts/logs.sh   # only one os_log category
#   LEVEL=debug ./scripts/logs.sh           # include .debug lines (default: info)

set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="ccterm"

# Normalize configuration: accept debug/Debug/release/Release.
CONFIGURATION="Debug"
case "$(echo "${CONFIG:-}" | tr '[:upper:]' '[:lower:]')" in
  release) CONFIGURATION="Release" ;;
  debug|"") CONFIGURATION="Debug" ;;
  *) echo "Unknown CONFIG='$CONFIG' (use debug|release)" >&2; exit 2 ;;
esac

LEVEL="${LEVEL:-info}"
case "$LEVEL" in
  default|info|debug) ;;
  *) echo "Unknown LEVEL='$LEVEL' (use default|info|debug)" >&2; exit 2 ;;
esac

CATEGORY="${CATEGORY:-}"

# Resolve this worktree's product image path (mirrors build.sh).
BUILD_SETTINGS=$(xcodebuild \
  -project ccterm.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null || true)

if [ -z "$BUILD_SETTINGS" ]; then
  echo "error: could not read build settings (is Xcode set up?)" >&2
  exit 1
fi

_DIR=$(echo "$BUILD_SETTINGS" | grep -m1 '^[[:space:]]*BUILT_PRODUCTS_DIR' | sed 's/.*= //')
_EXE=$(echo "$BUILD_SETTINGS" | grep -m1 '^[[:space:]]*EXECUTABLE_PATH' | sed 's/.*= //')
_BID=$(echo "$BUILD_SETTINGS" | grep -m1 '^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER' | sed 's/.*= //')

if [ -z "$_DIR" ] || [ -z "$_EXE" ]; then
  echo "error: could not determine product image path from build settings" >&2
  exit 1
fi

IMAGE_PATH="$_DIR/$_EXE"

# Pin to this product's process. Add the subsystem clause when we know the
# bundle id, to drop framework noise emitted from inside the process.
PREDICATE="processImagePath == \"$IMAGE_PATH\""
if [ -n "$_BID" ]; then
  PREDICATE="$PREDICATE AND subsystem == \"$_BID\""
fi
if [ -n "$CATEGORY" ]; then
  PREDICATE="$PREDICATE AND category == \"$CATEGORY\""
fi

echo "Streaming $CONFIGURATION logs (level=$LEVEL${CATEGORY:+, category=$CATEGORY})"
echo "  image: $IMAGE_PATH"
echo "  (Ctrl-C to stop)"
echo

exec log stream --predicate "$PREDICATE" --level "$LEVEL" --style compact

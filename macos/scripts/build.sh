#!/bin/bash
# Build ccterm macOS app.
# Usage:
#   ./scripts/build.sh                    # build ccterm (Debug)
#   ./scripts/build.sh debug|release      # build with specified configuration
#   ./scripts/build.sh SomeScheme         # build a specific scheme (Debug)
#   ./scripts/build.sh SomeScheme release # build a specific scheme with configuration

set -euo pipefail

cd "$(dirname "$0")/.."

# Parse arguments: detect debug/release as configuration
SCHEME="ccterm"
CONFIGURATION="Debug"

for arg in "$@"; do
  case "$(echo "$arg" | tr '[:upper:]' '[:lower:]')" in
    debug)   CONFIGURATION="Debug" ;;
    release) CONFIGURATION="Release" ;;
    *)       SCHEME="$arg" ;;
  esac
done

# --- Prerequisites ---

# Initialize git submodules (fzf) if needed
if [ ! -f ../thirdparty/fzf/main.go ]; then
  echo "Initializing git submodules..."
  git -C .. submodule update --init --recursive
fi

# Check bun is available (needed for WebReact build phase)
if ! command -v bun &>/dev/null; then
  echo "Error: bun is required but not installed."
  echo "Install via: curl -fsSL https://bun.sh/install | bash"
  exit 1
fi

# Install web dependencies if needed
if [ ! -d ../web/node_modules ]; then
  echo "Installing web dependencies..."
  (cd ../web && bun install)
fi

# --- Build ---

BUILD_LOG="/tmp/ccterm-build-$$.log"
BUILD_SUMMARY="/tmp/ccterm-build-$$-summary.log"

echo "Building $SCHEME ($CONFIGURATION)..."

# Query product path (single call, best-effort — don't fail if unavailable)
PRODUCT_APP=""
BUILD_SETTINGS=$(xcodebuild \
  -project ccterm.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null || true)

if [ -n "$BUILD_SETTINGS" ]; then
  _DIR=$(echo "$BUILD_SETTINGS" | grep -m1 '^\s*BUILT_PRODUCTS_DIR' | sed 's/.*= //')
  _NAME=$(echo "$BUILD_SETTINGS" | grep -m1 '^\s*FULL_PRODUCT_NAME' | sed 's/.*= //')
  if [ -n "$_DIR" ] && [ -n "$_NAME" ]; then
    PRODUCT_APP="$_DIR/$_NAME"
  fi
fi

START_TIME=$(date +%s)

BUILD_EXIT=0
xcodebuild \
  -project ccterm.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  SWIFT_STRICT_CONCURRENCY=complete \
  build \
  > "$BUILD_LOG" 2>&1 || BUILD_EXIT=$?

ELAPSED=$(( $(date +%s) - START_TIME ))

# Extract summary: errors and warnings with 1 line of context before
grep -B 1 -E '(error:|warning:|BUILD FAILED|BUILD SUCCEEDED|linker command failed)' "$BUILD_LOG" > "$BUILD_SUMMARY" 2>/dev/null || true

if [ "$BUILD_EXIT" -ne 0 ]; then
  echo ""
  echo "BUILD FAILED (${ELAPSED}s)"
  echo ""
  echo "Summary:  $BUILD_SUMMARY"
  echo "Full log: $BUILD_LOG"
  exit "$BUILD_EXIT"
fi

echo "Build succeeded (${ELAPSED}s)"
if [ -n "$PRODUCT_APP" ]; then
  echo "Product: $PRODUCT_APP"
fi

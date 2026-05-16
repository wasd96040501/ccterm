#!/bin/bash
# Shared test build. Produces a derivedData that both unit tests (cctermTests)
# and UI tests (cctermUITests) can run against with `test-without-building`,
# avoiding a full rebuild per test target.
#
# Usage:
#   ./scripts/build-for-testing.sh                       # Debug, default derivedData
#   DERIVED_DATA_PATH=/tmp/dd ./scripts/build-for-testing.sh
#
# Exit codes:
#   0 success / non-zero on build failure (xcodebuild's exit code is propagated).

set -uo pipefail

cd "$(dirname "$0")/.."

SCHEME="ccterm"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/build/test-dd}"

mkdir -p "$DERIVED_DATA_PATH"

# Initialize git submodules (fzf) if missing
if [ ! -f ../thirdparty/fzf/main.go ]; then
  echo "Initializing git submodules..."
  git -C .. submodule update --init --recursive
fi

BUILD_LOG="/tmp/ccterm-bft-$$.log"
BUILD_SUMMARY="/tmp/ccterm-bft-$$-summary.log"

echo "build-for-testing $SCHEME ($CONFIGURATION)"
echo "DerivedData: $DERIVED_DATA_PATH"

START_TIME=$(date +%s)

BUILD_EXIT=0
xcodebuild \
  -project ccterm.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  SWIFT_STRICT_CONCURRENCY=complete \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  build-for-testing \
  > "$BUILD_LOG" 2>&1 || BUILD_EXIT=$?

ELAPSED=$(( $(date +%s) - START_TIME ))

grep -B 1 -E '(error:|warning:|BUILD FAILED|BUILD SUCCEEDED|linker command failed)' "$BUILD_LOG" > "$BUILD_SUMMARY" 2>/dev/null || true

if [ "$BUILD_EXIT" -ne 0 ]; then
  echo ""
  echo "build-for-testing FAILED (${ELAPSED}s)"
  echo "Summary:  $BUILD_SUMMARY"
  echo "Full log: $BUILD_LOG"
  exit "$BUILD_EXIT"
fi

echo "build-for-testing succeeded (${ELAPSED}s)"
echo "$DERIVED_DATA_PATH" > /tmp/ccterm-test-dd-path

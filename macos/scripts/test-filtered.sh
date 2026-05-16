#!/bin/bash
# test-filtered.sh — run an arbitrary set of xcodebuild test IDs against the
# shared DerivedData populated by build-for-testing.sh. Invoked from the
# workflow_dispatch debug workflow (.github/workflows/test-debug.yml) so a
# single CI run can target whichever unit / UI tests a change touches.
#
# Usage:
#   FILTER="cctermUITests/Foo/testBar,cctermTests/Baz" ./macos/scripts/test-filtered.sh
#   ./macos/scripts/test-filtered.sh "cctermUITests/Foo"
#
# Exit codes:
#   0 success / 1 test failure / 3 usage error.

set -uo pipefail

cd "$(dirname "$0")/.."

SCHEME="ccterm"
DESTINATION='platform=macOS,arch=arm64'
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/build/test-dd}"

FILTER_RAW="${1:-${FILTER:-}}"
if [ -z "$FILTER_RAW" ]; then
  echo "error: FILTER required — comma-separated <Target>/<Class>[/method] IDs" >&2
  exit 3
fi

# Split on comma, trim whitespace, validate target prefix.
ONLY_TESTING_ARGS=()
IFS=',' read -ra ITEMS <<< "$FILTER_RAW"
for raw in "${ITEMS[@]}"; do
  id="$(echo "$raw" | xargs)"
  [ -z "$id" ] && continue
  case "$id" in
    cctermTests/*|cctermUITests/*) ;;
    *)
      echo "error: invalid test ID '$id' — must start with 'cctermTests/' or 'cctermUITests/'" >&2
      exit 3
      ;;
  esac
  ONLY_TESTING_ARGS+=(-only-testing:"$id")
done

if [ "${#ONLY_TESTING_ARGS[@]}" -eq 0 ]; then
  echo "error: FILTER resolved to empty list" >&2
  exit 3
fi

STAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR="/tmp/ccterm-debug-$STAMP-$$"
mkdir -p "$LOG_DIR"
RAW_LOG="$LOG_DIR/raw.log"
XCRESULT="$LOG_DIR/result.xcresult"

XCB_ARGS=(
  -project ccterm.xcodeproj
  -scheme "$SCHEME"
  -configuration Debug
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -resultBundlePath "$XCRESULT"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=-
  DEVELOPMENT_TEAM=
  "${ONLY_TESTING_ARGS[@]}"
  test-without-building
)

echo "Running filtered tests:"
for arg in "${ONLY_TESTING_ARGS[@]}"; do echo "  $arg"; done
echo "DerivedData: $DERIVED_DATA_PATH"
echo "Logs: $LOG_DIR"
echo ""

START=$(date +%s)
# Stream xcodebuild output to both the job log and raw.log for post-mortem.
xcodebuild "${XCB_ARGS[@]}" 2>&1 | tee "$RAW_LOG"
TEST_EXIT=${PIPESTATUS[0]}
ELAPSED=$(( $(date +%s) - START ))

if [ "$TEST_EXIT" -eq 0 ]; then
  PASSED=$(grep -ciE "^Test [Cc]ase .* passed" "$RAW_LOG" 2>/dev/null || echo 0)
  echo ""
  echo "✓ TESTS PASSED (${ELAPSED}s, $PASSED test cases)"
  echo "xcresult: $XCRESULT"
  exit 0
fi

echo ""
echo "✗ TESTS FAILED (exit=$TEST_EXIT, ${ELAPSED}s)"
FAILED=$(grep -E "Test [Cc]ase .* failed" "$RAW_LOG" 2>/dev/null | head -10)
if [ -n "$FAILED" ]; then
  echo "Failed cases:"
  echo "$FAILED" | sed 's/^/  /'
fi
echo "xcresult: $XCRESULT"
exit 1

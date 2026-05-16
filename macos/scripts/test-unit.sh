#!/bin/bash
# Unit-test runner. Runs cctermTests against the shared derivedData built by
# `build-for-testing.sh`. Parallel by default — each XCTestCase class runs in
# its own process, so they must not share global state (see
# cctermTests/CLAUDE.md).
#
# Usage:
#   ./scripts/test-unit.sh                       # all unit tests (parallel)
#   ./scripts/test-unit.sh ClassName             # one class
#   ./scripts/test-unit.sh ClassName/method      # one method
#   SKIP_BUILD=1 ./scripts/test-unit.sh          # CI mode: use existing derivedData
#
# When SKIP_BUILD=1, DERIVED_DATA_PATH must be set or the script falls back to
# the standard path used by build-for-testing.sh.
#
# Exit codes:
#   0 success / 1 test failure / 2 build failure.

set -uo pipefail

cd "$(dirname "$0")/.."

SCHEME="ccterm"
DESTINATION='platform=macOS,arch=arm64'
TEST_TARGET="cctermTests"
FILTER="${1:-}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/build/test-dd}"

STAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR="/tmp/ccterm-utest-$STAMP-$$"
mkdir -p "$LOG_DIR"
RAW_LOG="$LOG_DIR/raw.log"
SUMMARY_LOG="$LOG_DIR/summary.log"
XCRESULT="$LOG_DIR/result.xcresult"

XCB_ARGS=(
  -project ccterm.xcodeproj
  -scheme "$SCHEME"
  -configuration Debug
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -resultBundlePath "$XCRESULT"
  -parallel-testing-enabled YES
  -parallel-testing-worker-count 4
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=-
  DEVELOPMENT_TEAM=
)

# By default, restrict to the unit test target. With FILTER, allow ClassName or
# ClassName/method scoping.
if [ -n "$FILTER" ]; then
  XCB_ARGS+=(-only-testing:"$TEST_TARGET/$FILTER")
else
  XCB_ARGS+=(-only-testing:"$TEST_TARGET")
fi

# Action: with SKIP_BUILD=1, expect derivedData populated by a prior
# build-for-testing run; just run the tests. Otherwise: build + test in one
# invocation (xcodebuild handles incremental builds).
if [ "${SKIP_BUILD:-0}" = "1" ]; then
  XCB_ARGS+=(test-without-building)
else
  XCB_ARGS+=(test)
fi

echo "Running unit tests: filter=${FILTER:-<all>} skip-build=${SKIP_BUILD:-0}"
echo "DerivedData: $DERIVED_DATA_PATH"
echo "Logs: $LOG_DIR"

START_TIME=$(date +%s)
TEST_EXIT=0
xcodebuild "${XCB_ARGS[@]}" > "$RAW_LOG" 2>&1 || TEST_EXIT=$?
ELAPSED=$(( $(date +%s) - START_TIME ))

grep -iE "(Test Case .* (failed|passed)|Test Suite .* (failed|passed)|^\s*error:|FAILED|\*\* TEST .* \*\*|XCTAssertion|fatal error)" "$RAW_LOG" > "$SUMMARY_LOG" 2>/dev/null || true

if [ "$TEST_EXIT" -eq 0 ]; then
  # Xcode 26 prints "Test case ..." (lowercase c) while older versions used "Test Case".
  # Match both to keep the counter accurate across toolchain versions.
  PASSED=$(grep -ciE "^Test case|^Test Case" "$RAW_LOG" 2>/dev/null | head -n1 || echo 0)
  echo ""
  echo "✓ UNIT TESTS PASSED (${ELAPSED}s, $PASSED test cases)"
  echo ""
  echo "xcresult: $XCRESULT"
  exit 0
fi

echo ""
echo "✗ UNIT TESTS FAILED (exit=$TEST_EXIT, ${ELAPSED}s)"
echo ""

FAILED_CASES=$(grep -E "Test Case .* failed" "$SUMMARY_LOG" 2>/dev/null | head -10)
if [ -n "$FAILED_CASES" ]; then
  echo "Failed cases:"
  echo "$FAILED_CASES" | sed 's/^/  /'
  echo ""
fi

ASSERTIONS=$(grep -E "(XCTAssertion|XCTFail|fatal error|error:)" "$RAW_LOG" 2>/dev/null | head -10)
if [ -n "$ASSERTIONS" ]; then
  echo "Key errors (first 10):"
  echo "$ASSERTIONS" | sed 's/^/  /'
  echo ""
fi

echo "Detail logs:"
echo "  summary:  $SUMMARY_LOG"
echo "  full log: $RAW_LOG"
echo "  xcresult: $XCRESULT"

exit 1

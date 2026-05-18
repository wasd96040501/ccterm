#!/bin/bash
# Unit-test runner. Builds (incrementally) and runs cctermTests in one
# xcodebuild invocation. Parallel by default — each XCTestCase class runs
# in its own process, so they must not share global state (see
# cctermTests/CLAUDE.md).
#
# Usage:
#   ./scripts/test-unit.sh                       # all unit tests (parallel)
#   ./scripts/test-unit.sh ClassName             # one class
#   ./scripts/test-unit.sh ClassName/method      # one method
#
# DerivedData is cached under macos/build/test-dd by default; override with
# DERIVED_DATA_PATH if needed. CI restores the same path from cache so the
# first run after a cache hit is incremental.
#
# Exit codes:
#   0 success / 1 test failure / 2 build failure.

set -uo pipefail

cd "$(dirname "$0")/.."

SCHEME="ccterm"
DESTINATION='platform=macOS,arch=arm64'
TEST_TARGET="cctermTests"
FILTER="${1:-}"
# DerivedData must live outside the project tree. If a checkout sits inside
# `~/Documents`, an in-tree DerivedData puts the test bundle under the TCC
# "Documents" boundary; the host app's `Bundle.main` reads (e.g.
# SyntaxHighlightEngine loading `hljs-jscore.js` from AppState.init) then
# prompt for "ccterm 要访问文档" on every rebuild — the codesign hash changes
# each Debug build so the consent never sticks. CI overrides this to
# `macos/build/test-dd` (see .github/workflows/test.yml) so the cache action
# can pick it up.
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${HOME}/Library/Caches/ccterm-test-dd}"

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

# Propagate `CI` into the test process. xcodebuild scrubs the env when
# spawning XCTRunner, but any var prefixed `TEST_RUNNER_` is forwarded
# with the prefix stripped. Tests that need to detect CI (e.g. to
# `XCTSkip` cases that hang on the Xcode 26 CI image) read it via
# `ProcessInfo.processInfo.environment["CI"]`.
[ -n "${CI:-}" ] && export TEST_RUNNER_CI="$CI"

# By default, restrict to the unit test target. With FILTER, allow ClassName or
# ClassName/method scoping.
#
# Snapshot tests (files named `*SnapshotTests.swift`) are review-only — they
# render real views via `NSHostingController` and exist to attach PNGs to the
# xcresult for human inspection, not as a CI gate. They are skipped on the
# default-all run (locally and on CI) and only execute when FILTER explicitly
# names them, e.g. `FILTER=TranscriptDemoSnapshotTests`. See
# `cctermTests/CLAUDE.md` § Snapshot tests.
if [ -n "$FILTER" ]; then
  XCB_ARGS+=(-only-testing:"$TEST_TARGET/$FILTER")
else
  XCB_ARGS+=(-only-testing:"$TEST_TARGET")
  while IFS= read -r snapshot_file; do
    class_name=$(basename "$snapshot_file" .swift)
    XCB_ARGS+=(-skip-testing:"$TEST_TARGET/$class_name")
  done < <(find "$TEST_TARGET" -name '*SnapshotTests.swift' -type f 2>/dev/null)
fi

XCB_ARGS+=(test)

echo "Running unit tests: filter=${FILTER:-<all>}"
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

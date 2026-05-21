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
# DerivedData defaults to ~/Library/Caches/ccterm-test-dd-<worktree-hash>;
# the hash on the path means sibling git worktrees don't share a build
# database (which would deadlock concurrent xcodebuild invocations). CI
# overrides DERIVED_DATA_PATH to a stable workspace-relative location so
# the GitHub Actions cache can save/restore it across runs.
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
#
# The default path is also suffixed with a per-worktree hash so two
# `make test-unit` runs from sibling worktrees don't fight for the
# same DerivedData. xcodebuild takes an exclusive lock on the build
# database; two instances against the same path will *deadlock* between
# "build done" and "spawn test runner" — both processes go 0% CPU and
# the test phase never starts. Hashing on the worktree root keeps each
# checkout isolated while still letting repeated runs from the *same*
# worktree reuse the incremental swiftmodule cache.
if [ -z "${DERIVED_DATA_PATH:-}" ]; then
  WORKTREE_ROOT="$(cd .. && pwd -P)"
  WORKTREE_HASH=$(printf '%s' "$WORKTREE_ROOT" | shasum -a 256 | cut -c1-8)
  DERIVED_DATA_PATH="${HOME}/Library/Caches/ccterm-test-dd-${WORKTREE_HASH}"
fi

STAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR="/tmp/ccterm-utest-$STAMP-$$"
mkdir -p "$LOG_DIR"
RAW_LOG="$LOG_DIR/raw.log"
SUMMARY_LOG="$LOG_DIR/summary.log"
XCRESULT="$LOG_DIR/result.xcresult"

# Parallel testing is *off* locally by default. The test host is the full
# ccterm.app — every XCTRunner worker reboots the @main entry point, which
# in turn launches a `claude` CLI subprocess. With 4 parallel workers, the
# workers race on TCC, the claude CLI's lockfile under `~/.claude`, and
# LaunchServices registration; the slow ones hang for minutes between
# `RegisterWithLaunchServices` and the first `Test Suite started` event
# while their host bundle blocks on subprocess startup.
#
# CI sets `PARALLEL_TESTING=YES` to keep the suite throughput it depends
# on — CI runners are clean per-job VMs, so the subprocess race doesn't
# trigger there. Locally, set the env var to opt back in for a one-off.
if [ "${PARALLEL_TESTING:-NO}" = "YES" ]; then
  PARALLEL_ARGS=(-parallel-testing-enabled YES -parallel-testing-worker-count 4)
else
  PARALLEL_ARGS=(-parallel-testing-enabled NO)
fi

XCB_ARGS=(
  -project ccterm.xcodeproj
  -scheme "$SCHEME"
  -configuration Debug
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -resultBundlePath "$XCRESULT"
  "${PARALLEL_ARGS[@]}"
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
# `*SnapshotTests.swift` files are skipped on the default-all run (locally and
# on CI) — review-only PNG renders via `NSHostingController`, see
# `cctermTests/CLAUDE.md` § Snapshot tests. They stay compiled (bit-rot fails
# at build time) but are not executed.
#
# Smoke tests (real `claude` CLI) live as `executableTarget`s in
# `macos/AgentSDK` (DumpSmoke / InterruptSmoke / SmokeTest) — NOT XCTests.
# Run them with `cd macos/AgentSDK && swift run <name>`.
if [ -n "$FILTER" ]; then
  XCB_ARGS+=(-only-testing:"$TEST_TARGET/$FILTER")
else
  XCB_ARGS+=(-only-testing:"$TEST_TARGET")
  while IFS= read -r skip_file; do
    class_name=$(basename "$skip_file" .swift)
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

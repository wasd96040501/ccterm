#!/bin/bash
# Run unit tests for ccterm.
# Usage:
#   ./scripts/run-tests.sh                      # run all unit tests
#   ./scripts/run-tests.sh cctermTests           # run a specific test target
#   ./scripts/run-tests.sh cctermTests/testFoo   # run a specific test case
#
# Note: this script is excluded from Claude Code sandbox via settings.local.json

set -euo pipefail

cd "$(dirname "$0")/.."

TARGET="${1:-cctermTests}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TEST_LOG="/tmp/ccterm-test-${TIMESTAMP}-$$.log"
TEST_SUMMARY="/tmp/ccterm-test-${TIMESTAMP}-$$-summary.log"

echo "Testing: ${TARGET}"

TEST_EXIT=0
xcodebuild test \
  -project ccterm.xcodeproj \
  -scheme ccterm \
  -destination 'platform=macOS' \
  "-only-testing:${TARGET}" \
  -parallel-testing-enabled NO \
  > "$TEST_LOG" 2>&1 || TEST_EXIT=$?

# Extract summary: test results, errors, failures, and NSLog output
grep -E '(^Test |^	 Executed|\*\* TEST|error:.*\.swift|Testing failed|failed -|XCTAssert|ccterm\[.*\] ===)' "$TEST_LOG" > "$TEST_SUMMARY" 2>/dev/null || true

if [ "$TEST_EXIT" -ne 0 ]; then
  echo ""
  cat "$TEST_SUMMARY"
  echo ""
  echo "TEST FAILED (exit code: $TEST_EXIT)"
  echo "Full log:    $TEST_LOG"
  echo "Summary:     $TEST_SUMMARY"
  exit "$TEST_EXIT"
fi

cat "$TEST_SUMMARY"
echo ""
echo "Test succeeded: ${TARGET}"
echo "Full log:    $TEST_LOG"
echo "Summary:     $TEST_SUMMARY"

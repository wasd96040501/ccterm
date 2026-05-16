#!/bin/bash
# 在一个预编译好的 test bundle 上跑一个 shard。
# CI 用法:
#   ./scripts/test-shard.sh <xctestrun> <filter>
# 例如:
#   ./scripts/test-shard.sh build/DD/Build/Products/ccterm_macOS.xctestrun \
#       InputBar2StopButtonUITests
#
# filter:
#   ClassName              只跑一个 class
#   ClassName/methodName   只跑一个 method
#
# 退出码: 0 通过 / 1 失败 / 3 参数错误

set -uo pipefail

cd "$(dirname "$0")/.."

XCTESTRUN="${1:-}"
FILTER="${2:-}"

if [ -z "$XCTESTRUN" ] || [ -z "$FILTER" ]; then
  cat <<'EOF' >&2
usage: test-shard.sh <xctestrun-path> <filter>

  xctestrun  build-tests.sh 产出的 .xctestrun 文件
  filter     ClassName 或 ClassName/methodName (不带 target 前缀)

example:
  ./scripts/test-shard.sh build/DD/Build/Products/ccterm_macOS.xctestrun \
      InputBar2StopButtonUITests
EOF
  exit 3
fi

if [ ! -f "$XCTESTRUN" ]; then
  echo "error: xctestrun not found: $XCTESTRUN" >&2
  exit 3
fi

TEST_TARGET="cctermUITests"
DESTINATION='platform=macOS,arch=arm64'

STAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR="/tmp/ccterm-test-$STAMP-$$"
mkdir -p "$LOG_DIR"
RAW_LOG="$LOG_DIR/raw.log"
XCRESULT="$LOG_DIR/result.xcresult"

echo "Running shard: $FILTER"
echo "xctestrun: $XCTESTRUN"
echo "logs:      $LOG_DIR"

START_TIME=$(date +%s)

TEST_EXIT=0
xcodebuild test-without-building \
  -xctestrun "$XCTESTRUN" \
  -destination "$DESTINATION" \
  -only-testing:"$TEST_TARGET/$FILTER" \
  -resultBundlePath "$XCRESULT" \
  > "$RAW_LOG" 2>&1 || TEST_EXIT=$?

ELAPSED=$(( $(date +%s) - START_TIME ))

# 任何情况都把 xcodebuild 输出回放出来,CI 日志要能看到。
cat "$RAW_LOG"

if [ "$TEST_EXIT" -eq 0 ]; then
  PASSED=$(grep -cE "Test Case .* passed" "$RAW_LOG" 2>/dev/null || echo 0)
  echo ""
  echo "✓ SHARD PASSED ($FILTER, ${ELAPSED}s, $PASSED test cases)"
  echo "xcresult: $XCRESULT"
  exit 0
fi

echo ""
echo "✗ SHARD FAILED ($FILTER, exit=$TEST_EXIT, ${ELAPSED}s)"

FAILED_CASES=$(grep -E "Test Case .* failed" "$RAW_LOG" 2>/dev/null | head -5)
if [ -n "$FAILED_CASES" ]; then
  echo ""
  echo "Failed cases:"
  echo "$FAILED_CASES" | sed 's/^/  /'
fi

echo ""
echo "xcresult: $XCRESULT  (uploaded as CI artifact on failure)"
exit 1

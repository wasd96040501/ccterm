#!/bin/bash
# UI 测试 runner。LLM 友好的渐进式输出:
# - 成功:一行结果 + xcresult 路径
# - 失败:核心结论 + 关键 detail 路径(crash log / xcresult / 完整 log)
#
# 用法:
#   ./scripts/test.sh                       # 必须带 FILTER (CLAUDE.md 规范)
#   ./scripts/test.sh ClassName             # 只跑一个 class
#   ./scripts/test.sh ClassName/methodName  # 只跑一个 method
#   ALLOW_FULL_RUN=1 ./scripts/test.sh ""   # 全量跑(谨慎,UI test 慢)
#
# 退出码:
#   0 成功 / 1 测试失败 / 2 build/setup 失败 / 3 参数错误

set -uo pipefail

cd "$(dirname "$0")/.."

SCHEME="ccterm"
DESTINATION='platform=macOS,arch=arm64'
TEST_TARGET="cctermUITests"
FILTER="${1:-}"

# --- 参数守卫 ---
if [ -z "$FILTER" ] && [ "${ALLOW_FULL_RUN:-0}" != "1" ]; then
  cat <<'EOF' >&2
error: UI test 必须针对性跑。请指定 FILTER:
  make test FILTER=InputBar2StopButtonUITests
  make test FILTER=InputBar2StopButtonUITests/testStopButtonCancelsRunningState

  跑全部(慎用,UI test 慢):
  ALLOW_FULL_RUN=1 make test FILTER=""
EOF
  exit 3
fi

# --- 日志路径 ---
STAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR="/tmp/ccterm-test-$STAMP-$$"
mkdir -p "$LOG_DIR"
RAW_LOG="$LOG_DIR/raw.log"
SUMMARY_LOG="$LOG_DIR/summary.log"
CRASH_LOG="$LOG_DIR/crashes.log"
XCRESULT="$LOG_DIR/result.xcresult"

# 记录 test 开始时刻(后面据此筛 DiagnosticReports)
TEST_START_EPOCH=$(date +%s)

# --- 拼 xcodebuild 命令 ---
XCB_ARGS=(
  -project ccterm.xcodeproj
  -scheme "$SCHEME"
  -configuration Debug
  -destination "$DESTINATION"
  -resultBundlePath "$XCRESULT"
  # 忽略签名:UI test 不需要分发,本地/CI 都不依赖开发者证书。
  # `DEVELOPMENT_TEAM=` 覆盖 Local.xcconfig 里可能设的值。
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=-
  DEVELOPMENT_TEAM=
)
if [ -n "$FILTER" ]; then
  XCB_ARGS+=(-only-testing:"$TEST_TARGET/$FILTER")
fi
XCB_ARGS+=(test)

echo "Running UI test: filter=${FILTER:-<all>}"
echo "Logs: $LOG_DIR"

# --- 跑测试 ---
TEST_EXIT=0
xcodebuild "${XCB_ARGS[@]}" > "$RAW_LOG" 2>&1 || TEST_EXIT=$?

ELAPSED=$(( $(date +%s) - TEST_START_EPOCH ))

# --- 提取 summary(errors / test results / 关键失败) ---
# Test Case '-[Class method]' failed / passed 都抓
grep -E "(Test Case .* (failed|passed)|Test Suite .* (failed|passed)|^\s*error:|FAILED|\*\* TEST .* \*\*|XCTAssertion|fatal error)" "$RAW_LOG" > "$SUMMARY_LOG" 2>/dev/null || true

# --- 提取 crash logs(测试开始之后新生成的 ips,匹配 ccterm) ---
{
  for dir in "$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports"; do
    [ -d "$dir" ] || continue
    find "$dir" -maxdepth 1 -type f \( -name '*.ips' -o -name '*.crash' \) -newer "$RAW_LOG.start-marker" 2>/dev/null || true
    # 备用:按 mtime epoch 过滤(更兼容)
    find "$dir" -maxdepth 1 -type f \( -name 'ccterm-*' -o -name 'cctermUITests-*' \) 2>/dev/null \
      | while read -r f; do
        f_epoch=$(stat -f %m "$f" 2>/dev/null || echo 0)
        if [ "$f_epoch" -ge "$TEST_START_EPOCH" ]; then echo "$f"; fi
      done
  done
} | sort -u > "$CRASH_LOG" 2>/dev/null || true

# --- 输出 ---
if [ "$TEST_EXIT" -eq 0 ]; then
  PASSED=$(grep -cE "Test Case .* passed" "$SUMMARY_LOG" 2>/dev/null || echo 0)
  echo ""
  echo "✓ TEST PASSED (${ELAPSED}s, $PASSED test cases)"
  echo ""
  echo "xcresult: $XCRESULT"
  exit 0
fi

# --- 失败分支 ---
echo ""
echo "✗ TEST FAILED (exit=$TEST_EXIT, ${ELAPSED}s)"
echo ""

# 1) 失败的 Test Case(最关键的信息,先给)
FAILED_CASES=$(grep -E "Test Case .* failed" "$SUMMARY_LOG" 2>/dev/null | head -5)
if [ -n "$FAILED_CASES" ]; then
  echo "Failed cases:"
  echo "$FAILED_CASES" | sed 's/^/  /'
  echo ""
fi

# 2) 关键断言失败行
ASSERTIONS=$(grep -E "(XCTAssertion|XCTFail|fatal error|error:)" "$RAW_LOG" 2>/dev/null | head -5)
if [ -n "$ASSERTIONS" ]; then
  echo "Key errors (first 5):"
  echo "$ASSERTIONS" | sed 's/^/  /'
  echo ""
fi

# 3) crash logs
if [ -s "$CRASH_LOG" ]; then
  echo "Crash reports (open these for symbolicated stack traces):"
  while read -r crash; do
    echo "  $crash"
  done < "$CRASH_LOG"
  echo ""
fi

# 4) detail 文件路径(LLM 想看更多自己读)
echo "Detail logs:"
echo "  summary:  $SUMMARY_LOG"
echo "  full log: $RAW_LOG"
echo "  xcresult: $XCRESULT  (open in Xcode for screenshots / videos)"
echo "  crashes:  $CRASH_LOG"

exit 1

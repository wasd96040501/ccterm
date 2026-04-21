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

TEST_LOG="/tmp/ccterm-test-$$.log"
TEST_SUMMARY="/tmp/ccterm-test-$$-summary.log"
CRASH_LOG="/tmp/ccterm-test-$$-crashes.log"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"

echo "Testing: ${TARGET}..."

# Snapshot the DiagnosticReports directory *before* the run so we can diff
# afterwards. This is more precise than mtime filtering — it ignores any
# pre-existing .ips with a future mtime (clock skew) and captures crashes of
# any procName (XCTRunner-*, SwiftUI-*, ...) without needing a name allowlist.
DIAG_BEFORE=$(mktemp -t cctermtest-before)
if [ -d "$CRASH_DIR" ]; then
  (cd "$CRASH_DIR" && ls -1 2>/dev/null) > "$DIAG_BEFORE" || true
fi
trap 'rm -f "$DIAG_BEFORE"' EXIT

START_TIME=$(date +%s)

TEST_EXIT=0
xcodebuild test \
  -project ccterm.xcodeproj \
  -scheme ccterm \
  -destination 'platform=macOS' \
  "-only-testing:${TARGET}" \
  -parallel-testing-enabled NO \
  > "$TEST_LOG" 2>&1 || TEST_EXIT=$?

ELAPSED=$(( $(date +%s) - START_TIME ))

# Extract summary: test results, errors, failures, and NSLog output
grep -E '(^Test |^	 Executed|\*\* TEST|error:.*\.swift|Testing failed|failed -|XCTAssert|ccterm\[.*\] ===)' "$TEST_LOG" > "$TEST_SUMMARY" 2>/dev/null || true

# Collect crash reports produced during this run.
# - Directory diff against $DIAG_BEFORE snapshot → only ips files created during the run.
# - Filter each candidate by procPath matching our DerivedData build product, so crashes
#   from unrelated processes (e.g. another ccterm instance the user has open) are dropped.
# - Headline (short) → summary log. Full parsed backtrace → $CRASH_LOG (separate file).
collect_crash_reports() {
  local snapshot=$1
  [ -d "$CRASH_DIR" ] || return 0
  [ -f "$snapshot" ] || return 0

  local after
  after=$(mktemp -t cctermtest-after)
  (cd "$CRASH_DIR" && ls -1 2>/dev/null) > "$after"
  local new_names
  new_names=$(comm -13 <(sort "$snapshot") <(sort "$after"))
  rm -f "$after"
  [ -n "$new_names" ] || return 0

  # Keep only crashes of our build product. procPath in the .ips body is the
  # absolute path of the crashed executable — DerivedData hash makes it unique
  # per-build so it won't false-match other ccterm instances.
  local ours=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    local ips="$CRASH_DIR/$name"
    [ -f "$ips" ] || continue
    if /usr/bin/python3 - "$ips" <<'PY'
import json, sys, fnmatch
try:
    with open(sys.argv[1]) as fh:
        parts = fh.read().split('\n', 1)
    body = json.loads(parts[1]) if len(parts) == 2 else {}
except Exception:
    sys.exit(1)
patterns = [
    '*/Library/Developer/Xcode/DerivedData/ccterm-*/Build/Products/*/ccterm.app/*',
    '*/Library/Developer/Xcode/DerivedData/ccterm-*/Build/Products/*/cctermTests*',
]
p = body.get('procPath') or ''
sys.exit(0 if any(fnmatch.fnmatchcase(p, pat) for pat in patterns) else 1)
PY
    then
      ours+="$ips"$'\n'
    fi
  done <<< "$new_names"

  [ -n "$ours" ] || return 0

  : > "$CRASH_LOG"
  echo "" >> "$TEST_SUMMARY"
  echo "=== Crash Reports (headlines; full backtrace in $CRASH_LOG) ===" >> "$TEST_SUMMARY"

  printf '%s' "$ours" | while IFS= read -r ips; do
    [ -n "$ips" ] || continue
    echo "" >> "$CRASH_LOG"
    echo "========== $(basename "$ips") ==========" >> "$CRASH_LOG"
    # python writes the short headline to $TEST_SUMMARY (append) and the full
    # parsed backtrace to stdout (→ $CRASH_LOG). Keeping the full stack out of
    # stdout avoids dumping it into Claude's context on every failure.
    /usr/bin/python3 - "$ips" "$TEST_SUMMARY" "$(basename "$ips")" >> "$CRASH_LOG" <<'PY' || echo "(failed to parse $ips)" >> "$CRASH_LOG"
"""Render a .ips crash report.

- headline (1-4 lines) appended to the summary file given as argv[2]
- full, trimmed backtrace written to stdout (caller redirects to CRASH_LOG)
"""
import json, sys, os

ips_path = sys.argv[1]
summary_path = sys.argv[2]
ips_name = sys.argv[3] if len(sys.argv) > 3 else os.path.basename(ips_path)

try:
    with open(ips_path) as fh:
        raw = fh.read()
except OSError as e:
    print(f"(open failed: {e})")
    sys.exit(0)
parts = raw.split('\n', 1)
if len(parts) != 2:
    print(raw[:4000]); sys.exit(0)
try:
    body = json.loads(parts[1])
except Exception as e:
    print(f"(json parse failed: {e})"); print(raw[:2000]); sys.exit(0)

images = body.get('usedImages') or []
def binary_name(idx):
    if idx is None or idx < 0 or idx >= len(images): return '?'
    return images[idx].get('name') or os.path.basename(images[idx].get('path') or '') or '?'

TAIL_NOISE = {
    'start', '_pthread_start', 'thread_start',
    '_CFRunLoopRun', '_CFRunLoopRunSpecificWithOptions', 'CFRunLoopRun',
    '__CFRunLoopRun', '__CFRunLoopDoSource0', '__CFRunLoopDoSource1',
    '__CFRunLoopDoSources0', '__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__',
    '__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE1_PERFORM_FUNCTION__',
    '__CFMachPortPerform', '__CFRunLoopServiceMachPort',
    'RunCurrentEventLoopInMode', 'ReceiveNextEventCommon',
    '_BlockUntilNextEventMatchingListInMode', '_DPSBlockUntilNextEventMatchingListInMode',
    '_DPSNextEvent', 'NSApplicationMain',
}

def trim_tail(frames):
    i = len(frames)
    while i > 0 and (frames[i-1].get('symbol') or '') in TAIL_NOISE:
        i -= 1
    return frames[:i]

def fmt_frame(fr):
    sym = fr.get('symbol') or f"0x{fr.get('imageOffset',0):x}"
    loc = fr.get('symbolLocation', 0)
    img = binary_name(fr.get('imageIndex'))
    src = fr.get('sourceFile'); line = fr.get('sourceLine')
    src_str = f"  [{src}:{line}]" if src and line else ""
    return f"{img:<28} {sym} + {loc}{src_str}"

exc = body.get('exception') or {}
term = body.get('termination') or {}
asi = body.get('asi') or {}

# --- full version → stdout → CRASH_LOG -----------------------------------
print(f"proc: {body.get('procName')}  pid: {body.get('pid')}")
print(f"exc:  {exc.get('type')} / signal={exc.get('signal')}  codes={exc.get('codes')}")
if term.get('indicator'):
    print(f"term: {term.get('indicator')}")
for k, v in asi.items():
    for line in v:
        print(f"asi[{k}]: {line}")
for key in ('lastExceptionBacktrace', 'ktriageinfo'):
    if body.get(key):
        print(f"{key}: {json.dumps(body[key])[:500]}")

threads = body.get('threads') or []
crashed = next((t for t in threads if t.get('triggered')), threads[0] if threads else None)
if not crashed:
    sys.exit(0)
frames = trim_tail(crashed.get('frames') or [])

system_bases = ('/usr/lib/', '/System/', '/Library/Apple/', '/Library/Developer/')
def is_project(fr):
    idx = fr.get('imageIndex')
    if idx is None or idx < 0 or idx >= len(images):
        return False
    p = images[idx].get('path') or ''
    return p and not any(p.startswith(b) for b in system_bases)
top_user = next((fr for fr in frames if is_project(fr)), None)

if top_user:
    print(f"crashed at (top project frame): {fmt_frame(top_user)}")
q = crashed.get('queue')
print(f"backtrace (queue={q}):" if q else "backtrace:")
for i, fr in enumerate(frames[:30]):
    print(f"  {i:3d}  {fmt_frame(fr)}")
if len(frames) > 30:
    print(f"  ... ({len(frames)-30} more frames trimmed)")

# --- headline → summary file (append) -----------------------------------
with open(summary_path, 'a') as s:
    s.write(f"\n  {ips_name}\n")
    s.write(f"    signal={exc.get('signal')} term={term.get('indicator') or '-'}\n")
    if top_user:
        s.write(f"    top project: {fmt_frame(top_user)}\n")
    asi_line = None
    for k, v in asi.items():
        if v:
            asi_line = v[0]; break
    if asi_line:
        s.write(f"    asi: {asi_line}\n")
PY
  done
}

if [ "$TEST_EXIT" -ne 0 ]; then
  collect_crash_reports "$DIAG_BEFORE"
  echo ""
  cat "$TEST_SUMMARY"
  echo ""
  echo "TEST FAILED (${ELAPSED}s)"
  echo ""
  echo "Summary:  $TEST_SUMMARY"
  echo "Full log: $TEST_LOG"
  exit "$TEST_EXIT"
fi

cat "$TEST_SUMMARY"
echo ""
echo "Test succeeded (${ELAPSED}s)"

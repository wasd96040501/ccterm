#!/bin/bash
# Tests clean.sh against throwaway directories: a fake DerivedData, a fake
# /tmp and fake checkouts, all under one mktemp root. Every case checks what
# must go AND what must stay. Nothing outside the root is touched.

set -uo pipefail

CLEAN="$(cd "$(dirname "$0")" && pwd)/clean.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ccterm-clean-test.XXXXXX")"
ROOT="$(cd "$ROOT" && pwd -P)"
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf -- "$ROOT"' EXIT

export CCTERM_DERIVED_DATA="$ROOT/DerivedData"
export CCTERM_TMP="$ROOT/tmp"
FAILURES=0

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAILURES=$((FAILURES + 1)); }
gone() { if [ -e "$1" ] || [ -L "$1" ]; then fail "removed: ${1#"$ROOT"/}"; else pass "removed: ${1#"$ROOT"/}"; fi; }
kept() { if [ -e "$1" ] || [ -L "$1" ]; then pass "kept:    ${1#"$ROOT"/}"; else fail "kept:    ${1#"$ROOT"/}"; fi; }

# A checkout with build products in every place clean.sh looks.
make_checkout() {
  local c="$1"
  mkdir -p "$c/macos/ccterm.xcodeproj" "$c/macos/ccterm" "$c/macos/build/logs" "$c/build/arch" \
    "$c/macos/PkgA/.build/debug" "$c/macos/tools/PkgB/.build"
  touch "$c/Makefile" "$c/macos/ccterm/App.swift" "$c/macos/PkgA/Package.swift" \
    "$c/macos/tools/PkgB/Package.swift" "$c/macos/PkgA/Sources.swift"
}

# A DerivedData folder Xcode would make: ccterm-<28 letters>/info.plist.
make_dd() {
  local name="$1" workspace="$2" dir="$CCTERM_DERIVED_DATA/$1"
  mkdir -p "$dir/Build"
  if [ -n "$workspace" ]; then
    plutil -create xml1 "$dir/info.plist"
    plutil -insert WorkspacePath -string "$workspace" "$dir/info.plist"
  fi
  echo "$dir"
}

letters() { printf '%s' "$1" | head -c 28; }
A=$(letters aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
B=$(letters bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
C=$(letters cccccccccccccccccccccccccccccccc)
D=$(letters dddddddddddddddddddddddddddddddd)
E=$(letters eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee)
F=$(letters ffffffffffffffffffffffffffffffff)
G=$(letters gggggggggggggggggggggggggggggggg)
H=$(letters hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh)

echo "clean: one checkout"
W1="$ROOT/work trees/one"; W2="$ROOT/work trees/two"
make_checkout "$W1"; make_checkout "$W2"
outside="$ROOT/outside"; mkdir -p "$outside"; touch "$outside/keep.txt"
rm -rf "$W1/build"; ln -s "$outside" "$W1/build"   # a symlink is unlinked, not followed
dd1=$(make_dd "ccterm-$A" "$W1/macos/ccterm.xcodeproj")
dd2=$(make_dd "ccterm-$B" "$W2/macos/ccterm.xcodeproj")
"$CLEAN" clean "$W1" >/dev/null
gone "$dd1"; gone "$W1/macos/build"; gone "$W1/build"; gone "$W1/macos/PkgA/.build"; gone "$W1/macos/tools/PkgB/.build"
kept "$outside/keep.txt"; kept "$W1/macos/ccterm/App.swift"; kept "$W1/macos/PkgA/Package.swift"
kept "$W1/macos/PkgA/Sources.swift"; kept "$W1/macos/ccterm.xcodeproj"; kept "$W1/Makefile"
kept "$dd2"; kept "$W2/macos/build"; kept "$W2/build"; kept "$W2/macos/PkgA/.build"

echo "clean: refuses what is not a checkout"
notcheckout="$ROOT/plain"; mkdir -p "$notcheckout/macos/build" "$notcheckout/build"
if "$CLEAN" clean "$notcheckout" >/dev/null 2>&1; then fail "exit status"; else pass "exit status"; fi
kept "$notcheckout/macos/build"; kept "$notcheckout/build"
if "$CLEAN" clean "$ROOT/missing" >/dev/null 2>&1; then fail "missing dir exit status"; else pass "missing dir exit status"; fi

echo "clean: DRY_RUN deletes nothing"
dd2_out=$(DRY_RUN=1 "$CLEAN" clean "$W2")
kept "$dd2"; kept "$W2/macos/build"; kept "$W2/macos/PkgA/.build"
case "$dd2_out" in *"would remove: $dd2"*) pass "lists DerivedData" ;; *) fail "lists DerivedData" ;; esac

echo "prune: DerivedData"
rm -rf "$CCTERM_DERIVED_DATA"; mkdir -p "$CCTERM_DERIVED_DATA"
live=$(make_dd "ccterm-$A" "$W2/macos/ccterm.xcodeproj")
orphan=$(make_dd "ccterm-$B" "$ROOT/deleted/macos/ccterm.xcodeproj")
noplist=$(make_dd "ccterm-$C" "")
other_project=$(make_dd "ccterm-$D" "$ROOT/deleted/Other.xcodeproj")
volume=$(make_dd "ccterm-$E" "/Volumes/ccterm-test-not-mounted/macos/ccterm.xcodeproj")
other_app=$(make_dd "Other-$F" "$ROOT/deleted/macos/ccterm.xcodeproj")
odd_name=$(make_dd "ccterm-short" "$ROOT/deleted/macos/ccterm.xcodeproj")
locked_dir="$ROOT/locked"; mkdir -p "$locked_dir/repo/macos/ccterm.xcodeproj"
unreadable=$(make_dd "ccterm-$G" "$locked_dir/repo/macos/ccterm.xcodeproj")
chmod 000 "$locked_dir"   # exists but can't be looked into: not provably gone
plain_file="$CCTERM_DERIVED_DATA/ccterm-$H"; touch "$plain_file"
DRY_RUN=1 "$CLEAN" prune >/dev/null
kept "$orphan"
"$CLEAN" prune >/dev/null
gone "$orphan"
kept "$live"; kept "$noplist"; kept "$other_project"; kept "$volume"; kept "$other_app"
kept "$odd_name"; kept "$unreadable"; kept "$plain_file"
chmod 755 "$locked_dir"

echo "prune: old /tmp logs"
mkdir -p "$CCTERM_TMP"
old_utest="$CCTERM_TMP/ccterm-utest-20260101-120000-123"; mkdir -p "$old_utest"; touch "$old_utest/raw.log"
new_utest="$CCTERM_TMP/ccterm-utest-20260102-120000-456"; mkdir -p "$new_utest"
old_build="$CCTERM_TMP/ccterm-build-789.log"; old_summary="$CCTERM_TMP/ccterm-build-789-summary.log"
new_build="$CCTERM_TMP/ccterm-build-790.log"
old_screens="$CCTERM_TMP/ccterm-screenshots"; mkdir -p "$old_screens"
old_cache="$CCTERM_TMP/appkit-docs-cache"; mkdir -p "$old_cache"
old_named="$CCTERM_TMP/ccterm-utest-notes"; mkdir -p "$old_named"
old_file_like_dir="$CCTERM_TMP/ccterm-utest-20260101-120000-999"; touch "$old_file_like_dir"
old_dir_like_log="$CCTERM_TMP/ccterm-build-111.log"; mkdir -p "$old_dir_like_log"
touch "$old_build" "$old_summary" "$new_build"
for p in "$old_utest" "$old_build" "$old_summary" "$old_screens" "$old_cache" "$old_named" \
  "$old_file_like_dir" "$old_dir_like_log"; do
  touch -t 202601010000 "$p"
done
# Just inside the day: kept until it is a day old.
touch -t "$(date -v-23H +%Y%m%d%H%M)" "$new_utest" "$new_build"
"$CLEAN" prune >/dev/null
gone "$old_utest"; gone "$old_build"; gone "$old_summary"
kept "$new_utest"; kept "$new_build"; kept "$old_screens"; kept "$old_cache"; kept "$old_named"
kept "$old_file_like_dir"; kept "$old_dir_like_log"

echo "usage"
if "$CLEAN" >/dev/null 2>&1; then fail "no argument exits non-zero"; else pass "no argument exits non-zero"; fi

echo
if [ "$FAILURES" -eq 0 ]; then echo "clean.sh: all checks passed"; else echo "clean.sh: $FAILURES check(s) failed"; exit 1; fi

#!/bin/zsh
# Seal a case: write the edit as <case-dir>/patch.diff (paths relative to the repo
# root, so `patch -p1` applies it to a copy of the base) and drop the work copy.
#   case_seal.sh <case-dir>
set -euo pipefail
BASE=${ARCH_EVAL_BASE:-${0:A:h:h:h:h:h}/build/arch-eval/base}
cd "$1"
( cd work && diff -ruN "$BASE/macos" macos || true ) \
  | sed -e "s|^--- $BASE/macos|--- a/macos|" -e "s|^+++ macos|+++ b/macos|" \
        -e "s|^diff -ruN $BASE/macos/\([^ ]*\) macos/.*|diff -ruN a/macos/\1 b/macos/\1|" > patch.diff
if [[ ! -s patch.diff ]]; then echo "no change in work/ — nothing sealed" >&2; exit 1; fi
# Prove it applies before throwing the work copy away.
tmp=$(mktemp -d); cp -cR "$BASE/macos" "$tmp/macos"
patch -s -p1 -d "$tmp" < patch.diff
rm -rf "$tmp" work
echo "sealed: $(grep -c '^+++ ' patch.diff) file(s), $(grep -c '^[+-][^+-]' patch.diff) changed line(s)"

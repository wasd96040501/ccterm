#!/bin/zsh
# Start a case: a private copy of the base sources to edit.
#   case_init.sh <case-dir>          → <case-dir>/work/macos
set -euo pipefail
BASE=${ARCH_EVAL_BASE:-${0:A:h:h:h:h:h}/build/arch-eval/base}
mkdir -p "$1/work"
cp -cR "$BASE/macos" "$1/work/macos"
echo "edit $1/work/macos, then run case_seal.sh $1"

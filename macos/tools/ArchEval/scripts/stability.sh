#!/bin/zsh
# Diff stability: build the map of each commit's sources with the CURRENT ArchMap and
# compare consecutive maps against consecutive source diffs. An implementation-only
# change should move the map little; a structural one should move it locally.
#
#   stability.sh <out-dir> <scope> <sha>...     (oldest first)
set -euo pipefail
ROOT=${0:A:h:h:h:h:h}            # repo root
OUT=$1; SCOPE=$2; shift 2
BIN=$ROOT/macos/tools/ArchMap/.build/release/ArchMap
swift build -c release --package-path "$ROOT/macos/tools/ArchMap" >/dev/null
mkdir -p "$OUT"
prev=""
printf "%-10s %-10s %8s %8s %8s %8s\n" from to src+ src- map+ map-
for sha in "$@"; do
  src=$OUT/src-$sha
  if [[ ! -d $src ]]; then
    mkdir -p "$src"
    git -C "$ROOT" archive "$sha" macos | tar -x -C "$src"
  fi
  "$BIN" "$src/macos" "$OUT/map-$sha" "$SCOPE" "" >/dev/null
  if [[ -n $prev ]]; then
    s=$(git -C "$ROOT" diff --numstat "$prev" "$sha" -- 'macos/*.swift' | awk '{a+=$1; d+=$2} END {print a+0, d+0}')
    m=$({ diff -r "$OUT/map-$prev" "$OUT/map-$sha" || true; } | awk '/^>/ {a++} /^</ {d++} END {print a+0, d+0}')
    printf "%-10s %-10s %8s %8s %8s %8s\n" "$prev" "$sha" ${=s} ${=m}
  fi
  prev=$sha
done

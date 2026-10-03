#!/bin/bash
# Removes what a checkout leaves outside itself, and what it builds inside.
#
# Usage:
#   ./scripts/clean.sh clean [<checkout>]   # one checkout (default: this one)
#   ./scripts/clean.sh prune                # what no checkout owns any more
#   DRY_RUN=1 ./scripts/clean.sh …          # print, delete nothing
#
# clean: the checkout's DerivedData (the one whose info.plist names its
#   ccterm.xcodeproj), macos/build, build/ and each SwiftPM package's .build.
# prune: DerivedData whose project no longer exists, and the logs older
#   scripts wrote to /tmp (ccterm-utest-*, ccterm-build-*.log) once a day old.
#
# A removed worktree takes its own build products with it; prune is what
# reclaims the rest, so the SessionStart hook in .claude/settings.json runs it.
# (Not a WorktreeRemove hook: that event replaces Claude Code's own removal.)
#
# Every deletion is matched by name and by owner; anything that can't be
# proven to belong to a ccterm checkout is left alone. CCTERM_DERIVED_DATA and
# CCTERM_TMP move the two roots (for clean-test.sh).

set -uo pipefail

DERIVED_DATA="${CCTERM_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData}"
TMP_ROOT="${CCTERM_TMP:-/tmp}"
DRY_RUN="${DRY_RUN:-}"
SELF_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"

remove() {
  if [ -n "$DRY_RUN" ]; then
    echo "would remove: $1"
  else
    echo "remove: $1"
    # No trailing slash: a symlink is unlinked, never followed.
    rm -rf -- "$1"
  fi
}

# A ccterm checkout: the directory holding macos/ccterm.xcodeproj.
is_checkout() {
  [ -d "$1/macos/ccterm.xcodeproj" ] && [ -f "$1/Makefile" ]
}

# The project a DerivedData folder was built from, or nothing.
workspace_of() {
  /usr/libexec/PlistBuddy -c 'Print WorkspacePath' "$1/info.plist" 2>/dev/null
}

# Xcode's own folders for this app: ccterm-<28 lowercase letters>.
ccterm_derived_data() {
  [ -d "$DERIVED_DATA" ] || return 0
  find -H "$DERIVED_DATA" -mindepth 1 -maxdepth 1 -type d -name 'ccterm-*' \
    | grep -E '/ccterm-[a-z]{28}$'
}

clean_checkout() {
  local root
  root="$(cd "$1" 2>/dev/null && pwd -P)" || { echo "clean: no such directory: $1" >&2; return 1; }
  if ! is_checkout "$root"; then
    echo "clean: not a ccterm checkout: $root" >&2
    return 1
  fi
  echo "Cleaning $root"

  # Xcode records the project path as it was opened; match it either way.
  local project="$root/macos/ccterm.xcodeproj" logical="${1%/}/macos/ccterm.xcodeproj"
  local dd path
  while IFS= read -r dd; do
    path="$(workspace_of "$dd")"
    if [ "$path" = "$project" ] || [ "$path" = "$logical" ]; then remove "$dd"; fi
  done < <(ccterm_derived_data)

  [ -e "$root/macos/build" ] || [ -L "$root/macos/build" ] && remove "$root/macos/build"
  [ -e "$root/build" ] || [ -L "$root/build" ] && remove "$root/build"
  local manifest
  while IFS= read -r manifest; do
    local pkg_build
    pkg_build="$(dirname "$manifest")/.build"
    [ -e "$pkg_build" ] || [ -L "$pkg_build" ] && remove "$pkg_build"
  done < <(find "$root/macos" -maxdepth 3 -name Package.swift -not -path '*/.build/*')
  return 0
}

# True when the path is provably absent: the nearest directory above it that
# exists can be listed. A folder privacy (TCC) or permissions keep us out of
# reads as "missing" too, and that must not count.
is_gone() {
  [ -e "$1" ] || [ -L "$1" ] && return 1
  local dir
  dir="$(dirname "$1")"
  while [ ! -e "$dir" ]; do dir="$(dirname "$dir")"; done
  ls -- "$dir" >/dev/null 2>&1
}

prune() {
  echo "== prune $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Pruning DerivedData under $DERIVED_DATA"
  local dd path
  while IFS= read -r dd; do
    path="$(workspace_of "$dd")"
    # Only a ccterm project, gone from a disk that is there to look at: a
    # missing info.plist, another project's name, or an unmounted volume all
    # keep the folder.
    case "$path" in
      */ccterm.xcodeproj) ;;
      *) continue ;;
    esac
    case "$path" in
      /Volumes/*) continue ;;
    esac
    is_gone "$path" && remove "$dd"
  done < <(ccterm_derived_data)

  echo "Pruning old logs under $TMP_ROOT"
  # A day old: no build or test run lasts that long, so none is still writing.
  find -H "$TMP_ROOT" -mindepth 1 -maxdepth 1 -user "$(id -u)" -mtime +0 \
    \( \( -type d -name 'ccterm-utest-[0-9]*-[0-9]*-[0-9]*' \) \
    -o \( -type f -name 'ccterm-build-[0-9]*.log' \) \) 2>/dev/null \
    | while IFS= read -r stale; do remove "$stale"; done
  return 0
}

case "${1:-}" in
  clean) clean_checkout "${2:-$SELF_ROOT}" ;;
  prune) prune ;;
  *)
    echo "usage: $0 clean [<checkout>] | prune" >&2
    exit 2
    ;;
esac

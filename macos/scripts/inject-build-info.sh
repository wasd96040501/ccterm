#!/bin/bash
# Stamp the bundled Info.plist with the current git short hash so the
# custom About panel can show it. Invoked from an Xcode Run Script
# build phase, after Resources have been copied.
#
# Reads:  $SRCROOT (Xcode), points at macos/
# Writes: $TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Info.plist key
#         CCGitCommit (string)

set -euo pipefail

REPO_ROOT="$SRCROOT/.."

COMMIT=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  if ! git -C "$REPO_ROOT" diff-index --quiet HEAD -- 2>/dev/null; then
    COMMIT="${COMMIT}-dirty"
  fi
fi

PLIST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Info.plist"
if [ ! -f "$PLIST" ]; then
  echo "warning: Info.plist not found at $PLIST — skipping git stamp"
  exit 0
fi

/usr/libexec/PlistBuddy -c "Set :CCGitCommit $COMMIT" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CCGitCommit string $COMMIT" "$PLIST"

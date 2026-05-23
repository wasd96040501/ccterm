#!/bin/bash
# Install the Release build of ccterm.app to a destination directory.
# Invoked by `make install`. Default destination is /Applications.
#
# Overwriting a running CCTerm.app is safe on macOS: rm unlinks the bundle
# while the running process keeps using the old executable's inode, and the
# fresh files are written into place. The next launch picks up the new app.

set -euo pipefail

cd "$(dirname "$0")/.."

PREFIX="${1:-/Applications}"
SCHEME="ccterm"
CONFIGURATION="Release"

BUILD_SETTINGS=$(xcodebuild \
  -project ccterm.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null)

BUILT_DIR=$(echo "$BUILD_SETTINGS" | grep -m1 '^\s*BUILT_PRODUCTS_DIR' | sed 's/.*= //')
PRODUCT_NAME=$(echo "$BUILD_SETTINGS" | grep -m1 '^\s*FULL_PRODUCT_NAME' | sed 's/.*= //')

if [ -z "$BUILT_DIR" ] || [ -z "$PRODUCT_NAME" ]; then
  echo "error: could not resolve build product path from xcodebuild -showBuildSettings" >&2
  exit 1
fi

SRC="$BUILT_DIR/$PRODUCT_NAME"
DEST="$PREFIX/$PRODUCT_NAME"

if [ ! -d "$SRC" ]; then
  echo "error: build product not found at $SRC" >&2
  echo "Run 'make release' first." >&2
  exit 1
fi

if [ ! -d "$PREFIX" ]; then
  echo "error: install prefix $PREFIX does not exist" >&2
  exit 1
fi

if [ ! -w "$PREFIX" ]; then
  echo "error: $PREFIX is not writable — retry with: sudo make install" >&2
  exit 1
fi

echo "Installing $PRODUCT_NAME"
echo "  from: $SRC"
echo "  to:   $DEST"

rm -rf "$DEST"
cp -R "$SRC" "$PREFIX/"

if [ ! -d "$DEST" ]; then
  echo "error: install failed — $DEST not present after copy" >&2
  exit 1
fi

INFO_PLIST="$DEST/Contents/Info.plist"
VERSION=$(defaults read "$INFO_PLIST" CFBundleShortVersionString 2>/dev/null || echo "unknown")
BUILD_NUM=$(defaults read "$INFO_PLIST" CFBundleVersion 2>/dev/null || echo "unknown")

echo ""
echo "Installed: $DEST"
echo "Version:   $VERSION ($BUILD_NUM)"

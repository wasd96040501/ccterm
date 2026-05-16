#!/bin/bash
# Wake cctermtest's Aqua session manually. Only needed if you ran setup with
# --no-autologin; otherwise cctermtest's session is created at boot.
#
# Effect: opens the macOS login picker. You select "CCTerm UI Test" and enter
# its password. Once cctermtest's autoswitch agent fires (~3 seconds after its
# desktop appears), screen flips back to you. Total disruption: ~10 seconds.

set -uo pipefail

UITEST_USER="${UITEST_USER:-cctermtest}"

if ! id -u "$UITEST_USER" >/dev/null 2>&1; then
    echo "error: user $UITEST_USER does not exist — run \`make uitest-setup\` first" >&2
    exit 1
fi

# Already alive? cctermtest's Dock means its Aqua session is up.
if pgrep -u "$UITEST_USER" -x Dock >/dev/null 2>&1; then
    echo "$UITEST_USER session already alive — nothing to do."
    exit 0
fi

cat <<EOF
Switching to the login window in 2s.
Pick "CCTerm UI Test" and enter its password ($UITEST_USER).
Autoswitch flips back to your account ~3s after cctermtest logs in.
EOF
sleep 2

# macOS 14+ : User.menu / CGSession is gone. Use the loginwindow apple-event.
if osascript -e 'tell application "loginwindow" to «event aevtsclk»' 2>/dev/null; then
    exit 0
fi

# Fallback: lock screen via keystroke (requires Accessibility for osascript).
osascript -e 'tell application "System Events" to keystroke "q" using {control down, command down}'

#!/bin/bash
# Runs at every cctermtest Aqua login. Gets the screen off cctermtest's desktop
# so the main user can log in / resume without seeing it.
#
# macOS 14 (Sonoma) and earlier had CGSession -suspend; macOS 15 and 26 removed
# both the binary and the User.menu bundle that hosted it. The modern path is
# an AppleScript apple-event to loginwindow («aevtsclk» — "show login click"),
# with Cmd+Ctrl+Q (lock screen) as a fallback.
#
# Both methods require TCC consent on first run:
#   - "loginwindow" event   → Automation permission for the script
#   - Cmd+Ctrl+Q keystroke  → Accessibility permission for the script
# first-run.sh walks the user through granting both.

set -uo pipefail

STATE_DIR="$HOME/.ccterm-uitest"
SKIP_FILE="$STATE_DIR/skip-autoswitch"
LOG="$STATE_DIR/autoswitch.log"

mkdir -p "$STATE_DIR"
echo "=== autoswitch $(date '+%Y-%m-%d %H:%M:%S') macOS=$(sw_vers -productVersion 2>/dev/null) ===" >> "$LOG"

# Mute audio first — even if every method below fails, no XCUITest beep can
# escape to the main user's speakers.
osascript -e 'set volume with output muted' 2>>"$LOG" || true

if [ -f "$SKIP_FILE" ]; then
    echo "skip sentinel present at $SKIP_FILE — staying foreground" >> "$LOG"
    exit 0
fi

# Give the Aqua session a couple of seconds to wire up WindowServer +
# AppleEvent dispatch. Calling loginwindow too early no-ops.
sleep 3

try_loginwindow_event() {
    osascript -e 'tell application "loginwindow" to «event aevtsclk»' 2>>"$LOG"
}

try_lock_screen_shortcut() {
    osascript -e 'tell application "System Events" to keystroke "q" using {control down, command down}' 2>>"$LOG"
}

# Method 1 — clean: opens the full FUS login picker, no UI scripting needed.
if try_loginwindow_event; then
    echo "OK: loginwindow «aevtsclk» event accepted" >> "$LOG"
    exit 0
fi
echo "WARN: loginwindow event method failed, trying keystroke fallback" >> "$LOG"

# Method 2 — fallback: Cmd+Ctrl+Q locks the screen. User picks their account
# from the lock screen's switch-user UI.
if try_lock_screen_shortcut; then
    echo "OK: locked screen via Cmd+Ctrl+Q" >> "$LOG"
    exit 0
fi

echo "ERROR: every method to leave cctermtest foreground failed" >> "$LOG"
echo "Inspect TCC permissions for /usr/bin/osascript in:" >> "$LOG"
echo "  System Settings → Privacy & Security → Accessibility (for keystroke)" >> "$LOG"
echo "  System Settings → Privacy & Security → Automation (for loginwindow)" >> "$LOG"
exit 1

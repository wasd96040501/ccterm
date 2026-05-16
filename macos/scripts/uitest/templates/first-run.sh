#!/bin/bash
# Runs ONCE inside cctermtest the first time the user logs into it manually.
# Goals:
#   1. Prune unneeded per-user daemons (saves ~500MB-1GB RAM, kills periodic CPU)
#   2. Disable Spotlight indexing on cctermtest's home
#   3. Mute system audio
#   4. Remove the autoswitch skip sentinel
#   5. Trigger the macOS TCC prompt for osascript→loginwindow control, so
#      future automatic logins don't pop a dialog.
#
# After this completes, the screen will jump to the login window — switch back
# to your main account from there. cctermtest's session stays alive in the bg.
#
# Re-running is safe (idempotent).

set -uo pipefail

if [ "$(id -un)" != "cctermtest" ]; then
    echo "ERROR: first-run.sh must be run AS cctermtest (you are $(id -un))"
    echo ""
    echo "Switch to the cctermtest user via the Apple menu → switch user,"
    echo "open Terminal there, then run:"
    echo "  ~/.ccterm-uitest/first-run.sh"
    exit 1
fi

UID_NUM=$(id -u)
STATE_DIR="$HOME/.ccterm-uitest"
LOG="$STATE_DIR/first-run.log"
mkdir -p "$STATE_DIR"

echo "=== first-run $(date '+%Y-%m-%d %H:%M:%S') ===" | tee -a "$LOG"
echo "uid=$UID_NUM home=$HOME macOS=$(sw_vers -productVersion)" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# 1. Mute audio
# ---------------------------------------------------------------------------
osascript -e 'set volume with output muted' 2>/dev/null || true
echo "muted system audio" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# 2. Disable Spotlight indexing on this user's home
# ---------------------------------------------------------------------------
echo "disabling Spotlight indexing on $HOME (passwordless sudo)" | tee -a "$LOG"
sudo mdutil -i off "$HOME" 2>&1 | tee -a "$LOG" || true
sudo mdutil -E "$HOME" 2>&1 | tee -a "$LOG" || true

# ---------------------------------------------------------------------------
# 3. Boot out unneeded per-user LaunchAgents.
# ---------------------------------------------------------------------------
AGENTS_TO_DISABLE=(
    # Siri / suggestions
    com.apple.assistantd
    com.apple.Siri.agent
    com.apple.suggestd
    com.apple.parsecd
    com.apple.knowledge-agent
    com.apple.knowledgeconstructiond
    # iCloud / continuity
    com.apple.bird
    com.apple.cloudphotod
    com.apple.cloudpaird
    com.apple.protectedcloudstorage.protectedcloudkeysyncing
    com.apple.icloud.fmfd
    com.apple.icloud.findmydeviced.findmydevice-user-agent
    com.apple.icloud.searchpartyuseragent
    com.apple.iCloudHelper
    com.apple.iCloudUserNotificationsd
    com.apple.security.cloudkeychainproxy3
    com.apple.itunescloudd
    # Photos / Media
    com.apple.photolibraryd
    com.apple.photoanalysisd
    com.apple.MediaLibraryService
    com.apple.amp.mediasharingd
    # Location
    com.apple.CoreLocationAgent
    com.apple.weatherd
    # Game Center / Apple TV / Music
    com.apple.gamed
    com.apple.appleaccountd
    # Family / Calendar / Reminders extras
    com.apple.familycircled
    com.apple.familycontrols.useragent
    com.apple.CalendarAgent
    com.apple.remindd
    # Misc
    com.apple.helpd
    com.apple.AOSPushRelay
    com.apple.passd
)

for agent in "${AGENTS_TO_DISABLE[@]}"; do
    if launchctl print "gui/$UID_NUM/$agent" >/dev/null 2>&1; then
        launchctl bootout "gui/$UID_NUM/$agent" 2>&1 | tee -a "$LOG" || true
        echo "  booted out $agent" | tee -a "$LOG"
    fi
done

# ---------------------------------------------------------------------------
# 4. Disarm the skip sentinel so future logins auto-switch back to main user.
# ---------------------------------------------------------------------------
SKIP_FILE="$STATE_DIR/skip-autoswitch"
if [ -f "$SKIP_FILE" ]; then
    rm "$SKIP_FILE"
    echo "removed skip sentinel — future cctermtest logins will auto-switch" | tee -a "$LOG"
fi

# ---------------------------------------------------------------------------
# 5. Trigger TCC prompt for osascript → loginwindow Automation by actually
#    invoking the apple event. macOS will pop a dialog the first time. After
#    you click Allow, the screen jumps to the login window — pick your main
#    account to come back. This is the ONLY interactive moment.
# ---------------------------------------------------------------------------

cat <<'EOF'

────────────────────────────────────────────────────────────────────────────
NEXT: macOS is about to ask if osascript may control "loginwindow".
Click "Allow" on the dialog.

After you click Allow, the screen will jump to the macOS login picker.
Select YOUR main account and log back in. cctermtest's session stays alive
in the background — that's exactly what we want.

(If you see the dialog and click Don't Allow, autoswitch will not work and
you'll need to grant the permission manually in
 System Settings → Privacy & Security → Automation → osascript → loginwindow)

Press ENTER when ready…
────────────────────────────────────────────────────────────────────────────
EOF

read -r _

osascript -e 'tell application "loginwindow" to «event aevtsclk»' 2>>"$LOG" || {
    echo "osascript loginwindow event failed — see $LOG"
    echo "you can switch back manually via Apple menu → switch user → <your account>"
}

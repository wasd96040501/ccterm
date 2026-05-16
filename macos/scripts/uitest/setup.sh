#!/bin/bash
# One-time setup for running CCTerm UI tests in a hidden second user account.
# See macos/scripts/uitest/README.md for the full design.
#
# Re-running is safe (each step is idempotent).
#
# Environment overrides:
#   UITEST_USER     test account short name        (default: cctermtest)
#   UITEST_PASS     test account password          (default: ccterm-uitest)
#   UITEST_FULLNAME human-readable display name    (default: "CCTerm UI Test")
#
# Flags:
#   --no-autologin  skip setting auto-login (use `make uitest-wake` after each reboot)

set -uo pipefail

# --- repo locations ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

# --- knobs ---
UITEST_USER="${UITEST_USER:-cctermtest}"
UITEST_PASS="${UITEST_PASS:-ccterm-uitest}"
UITEST_FULLNAME="${UITEST_FULLNAME:-CCTerm UI Test}"
ENABLE_AUTOLOGIN=1

for arg in "$@"; do
    case "$arg" in
        --no-autologin) ENABLE_AUTOLOGIN=0 ;;
        -h|--help)
            sed -n '2,15p' "$0"
            exit 0
            ;;
        *)
            echo "unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

# --- output helpers ---
BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
step()  { echo ""; echo "${BOLD}==> $*${RESET}"; }
ok()    { echo "    ${GREEN}✓${RESET} $*"; }
skip()  { echo "    ${DIM}· $* (already done)${RESET}"; }
warn()  { echo "    ${YELLOW}!${RESET} $*"; }
err()   { echo "    ${RED}✗${RESET} $*" >&2; }
fatal() { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

if [ "$(id -u)" -eq 0 ]; then
    fatal "run setup.sh as your normal user, not root. The script will sudo when needed."
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    fatal "xcodebuild not found — install Xcode first."
fi

MAIN_USER="$(whoami)"
MAIN_UID="$(id -u)"

# Find an SSH pubkey, generate one if missing
SSH_PUBKEY=""
for candidate in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
    if [ -f "$candidate" ]; then
        SSH_PUBKEY="$candidate"
        break
    fi
done
if [ -z "$SSH_PUBKEY" ]; then
    warn "no SSH pubkey found in ~/.ssh — generating an ed25519 key now"
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
    SSH_PUBKEY="$HOME/.ssh/id_ed25519.pub"
fi

echo "${BOLD}CCTerm local UI-test setup${RESET}"
echo "  main user:    $MAIN_USER (uid $MAIN_UID)"
echo "  test user:    $UITEST_USER"
echo "  test pass:    $UITEST_PASS"
echo "  repo root:    $REPO_ROOT"
echo "  ssh pubkey:   $SSH_PUBKEY"
echo "  auto-login:   $([ "$ENABLE_AUTOLOGIN" = 1 ] && echo yes || echo no)"
echo ""
read -r -p "Proceed? [y/N] " ans
case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "aborted."; exit 0 ;;
esac

# Cache sudo creds once; subsequent sudo calls won't re-prompt for a while.
sudo -v || fatal "sudo failed"

# ---------------------------------------------------------------------------
# Step 1: create cctermtest user
# ---------------------------------------------------------------------------

step "Step 1: create user '$UITEST_USER'"

if id -u "$UITEST_USER" >/dev/null 2>&1; then
    skip "user already exists"
else
    sudo sysadminctl -addUser "$UITEST_USER" \
        -password "$UITEST_PASS" \
        -fullName "$UITEST_FULLNAME" \
        -home "/Users/$UITEST_USER" \
        -shell /bin/zsh
    if ! id -u "$UITEST_USER" >/dev/null 2>&1; then
        fatal "user creation failed"
    fi
    ok "created $UITEST_USER (uid $(id -u "$UITEST_USER"))"
fi

UITEST_UID="$(id -u "$UITEST_USER")"

# ---------------------------------------------------------------------------
# Step 2: enable Fast User Switching
# ---------------------------------------------------------------------------

step "Step 2: enable Fast User Switching"

current="$(sudo defaults read /Library/Preferences/.GlobalPreferences MultipleSessionEnabled 2>/dev/null || echo 0)"
if [ "$current" = "1" ]; then
    skip "MultipleSessionEnabled = 1"
else
    sudo defaults write /Library/Preferences/.GlobalPreferences MultipleSessionEnabled -bool YES
    ok "set MultipleSessionEnabled = YES"
fi

# ---------------------------------------------------------------------------
# Step 3: enable Remote Login (sshd) + SSH access list
# ---------------------------------------------------------------------------

step "Step 3: enable Remote Login and add $UITEST_USER to ssh access group"

manual_remote_login_msg() {
    cat <<EOF
    ${YELLOW}!${RESET} sshd is not listening on :22 and \`systemsetup\` is blocked by TCC.

      Enable Remote Login manually:
        System Settings → General → Sharing → Remote Login → toggle ON
        ⟶ "Allow access for"  →  "Only these users"
        ⟶ click + and add only "CCTerm UI Test"
              (do NOT add your main account — we don't want it SSH-reachable)

      The sshd protocol-level AllowUsers drop-in we install in step 4b enforces
      the same restriction independently, but matching the System Settings UI
      keeps things tidy.

      Then re-run \`make uitest-setup\` — already-done steps will skip.
EOF
}

# Detect whether sshd is actually accepting connections, bypassing systemsetup's
# TCC restriction (`systemsetup -getremotelogin` requires Full Disk Access on
# macOS 13+ even just to READ the toggle's state).
if nc -z -G 2 127.0.0.1 22 2>/dev/null; then
    skip "sshd is listening on :22 (Remote Login is on)"
else
    # Not listening — try to enable via systemsetup; if that's blocked, fall
    # through to manual guidance.
    set_output="$(sudo systemsetup -setremotelogin on 2>&1 || true)"
    if echo "$set_output" | grep -qi 'Full Disk Access'; then
        manual_remote_login_msg
        exit 1
    fi
    # Give launchd a moment to start sshd, then re-check.
    sleep 1
    if nc -z -G 2 127.0.0.1 22 2>/dev/null; then
        ok "Remote Login enabled"
    else
        err "systemsetup said: ${set_output:-<no output>}"
        manual_remote_login_msg
        exit 1
    fi
fi

# Add cctermtest to `com.apple.access_ssh` so it shows up in the Sharing UI.
# (sshd protocol-level AllowUsers in step 4b is what actually gates access;
# this group is just for the System Settings UI consistency.)
if dseditgroup -o checkmember -m "$UITEST_USER" com.apple.access_ssh 2>/dev/null | grep -q 'yes'; then
    skip "$UITEST_USER already in com.apple.access_ssh"
else
    sudo dseditgroup -o edit -a "$UITEST_USER" -t user com.apple.access_ssh 2>/dev/null || true
    ok "added $UITEST_USER to com.apple.access_ssh"
fi

# Intentionally do NOT touch the main user's group membership — the AllowUsers
# whitelist in the sshd drop-in (step 4b) rejects every non-cctermtest login
# attempt at the protocol level, so group membership is irrelevant to security.
# If a previous (buggy) run added the main user, you can leave it — it's inert.

# ---------------------------------------------------------------------------
# Step 4: trust main user's SSH pubkey on cctermtest
# ---------------------------------------------------------------------------

step "Step 4: install SSH pubkey for $UITEST_USER"

UITEST_HOME="/Users/$UITEST_USER"
AUTHORIZED="$UITEST_HOME/.ssh/authorized_keys"
PUBKEY_CONTENT="$(cat "$SSH_PUBKEY")"

sudo install -d -m 700 -o "$UITEST_USER" -g staff "$UITEST_HOME/.ssh"

if [ -f "/tmp/uitest-authkey-check.$$" ]; then rm -f "/tmp/uitest-authkey-check.$$"; fi
if sudo test -f "$AUTHORIZED" && sudo grep -qxF "$PUBKEY_CONTENT" "$AUTHORIZED"; then
    skip "pubkey already in $AUTHORIZED"
else
    # Append, do not clobber.
    echo "$PUBKEY_CONTENT" | sudo tee -a "$AUTHORIZED" >/dev/null
    sudo chown "$UITEST_USER:staff" "$AUTHORIZED"
    sudo chmod 600 "$AUTHORIZED"
    ok "appended pubkey to $AUTHORIZED"
fi

# Trust localhost host key so `ssh cctermtest@localhost` doesn't prompt
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
mkdir -p "$HOME/.ssh"
touch "$KNOWN_HOSTS"
if ! ssh-keygen -F localhost >/dev/null 2>&1; then
    ssh-keyscan -t ed25519,rsa,ecdsa -H localhost 2>/dev/null >> "$KNOWN_HOSTS" || true
    ok "added localhost host keys to $KNOWN_HOSTS"
else
    skip "localhost already in known_hosts"
fi

# ---------------------------------------------------------------------------
# Step 4b: lock cctermtest SSH to loopback + pubkey only
# ---------------------------------------------------------------------------

step "Step 4b: harden sshd — $UITEST_USER reachable only from loopback, pubkey only"

SSHD_DROPIN="/etc/ssh/sshd_config.d/99-ccterm-uitest.conf"
SSHD_DROPIN_DIR="$(dirname "$SSHD_DROPIN")"

# Ensure the drop-in directory exists and is Included by the main config.
if ! sudo test -d "$SSHD_DROPIN_DIR"; then
    sudo mkdir -p "$SSHD_DROPIN_DIR"
fi

# Verify Include is wired in /etc/ssh/sshd_config (default on macOS 13+).
if ! sudo grep -qE "^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/" /etc/ssh/sshd_config 2>/dev/null; then
    warn "/etc/ssh/sshd_config has no Include for sshd_config.d/ — adding"
    echo "Include /etc/ssh/sshd_config.d/*" | sudo tee -a /etc/ssh/sshd_config >/dev/null
fi

# `sshd -t` validation needs hostkeys, but macOS only generates them on first
# sshd run. Pre-generate any missing default hostkeys so validation passes.
if ! sudo test -f /etc/ssh/ssh_host_ed25519_key; then
    warn "sshd hostkeys missing — generating defaults via \`ssh-keygen -A\`"
    sudo ssh-keygen -A 2>&1 | sed 's/^/        /' || true
fi

sudo install -m 644 -o root -g wheel "$TEMPLATES_DIR/sshd-config-ccterm-uitest.conf" "$SSHD_DROPIN"

# Validate the resulting config — sshd -t exits non-zero on any error.
sshd_test_output="$(sudo /usr/sbin/sshd -t -f /etc/ssh/sshd_config 2>&1 || true)"
if [ -z "$sshd_test_output" ]; then
    ok "installed $SSHD_DROPIN (sshd config validates)"
elif echo "$sshd_test_output" | grep -qi 'no hostkeys available'; then
    # Even after ssh-keygen -A, validation may still complain if /etc/ssh perms
    # got hosed. Install anyway — the file's syntax is trivial and we already
    # eyeballed it. Tell the user how to re-validate later.
    warn "sshd -t reports: $sshd_test_output"
    warn "installing drop-in anyway (syntax is trivial); validate later with:"
    warn "    sudo /usr/sbin/sshd -t"
    ok "installed $SSHD_DROPIN (deferred validation)"
else
    err "sshd config failed validation: $sshd_test_output"
    sudo rm -f "$SSHD_DROPIN"
    fatal "sshd refused our drop-in. inspect $TEMPLATES_DIR/sshd-config-ccterm-uitest.conf"
fi

# macOS sshd is socket-activated via launchd — new connections re-read config
# on accept(), so no explicit reload is needed. The change takes effect for
# the very next ssh attempt.

# ---------------------------------------------------------------------------
# Step 5: grant cctermtest read+exec ACL on the repo
# ---------------------------------------------------------------------------

step "Step 5: grant '$UITEST_USER' read access to $REPO_ROOT"

# Add traversal (execute,search) on every parent so cctermtest can descend.
p="$REPO_ROOT"
while [ "$p" != "/" ] && [ -n "$p" ]; do
    sudo chmod +a "user:$UITEST_USER allow execute,search,readattr,readextattr,list" "$p" 2>/dev/null || true
    p="$(dirname "$p")"
done

# Full read + inherit on the repo root itself.
sudo chmod -R +a "user:$UITEST_USER allow read,execute,readattr,readextattr,readsecurity,list,search,file_inherit,directory_inherit" "$REPO_ROOT" 2>/dev/null || true

# Verify the test user can in fact read a key file.
if sudo -u "$UITEST_USER" test -r "$REPO_ROOT/Makefile"; then
    ok "$UITEST_USER can read $REPO_ROOT/Makefile"
else
    err "$UITEST_USER cannot read repo files — ACL grant may have failed"
fi

# Initialize git submodules (e.g. thirdparty/fzf) as the main user — cctermtest
# only has read access to the repo, so it cannot run `git submodule update`
# itself. build.sh's auto-init code path would fail.
if [ -f "$REPO_ROOT/.gitmodules" ] && ! [ -f "$REPO_ROOT/thirdparty/fzf/main.go" ]; then
    echo "    initializing git submodules in $REPO_ROOT…"
    if git -C "$REPO_ROOT" submodule update --init --recursive 2>&1 | sed 's/^/      /'; then
        ok "git submodules initialized"
    else
        warn "git submodule update returned non-zero — check $REPO_ROOT/thirdparty/"
    fi
else
    skip "git submodules already initialized (or no .gitmodules)"
fi

# Tell cctermtest's git that this checkout is safe to operate on (it's owned
# by another user; git refuses to touch such repos by default since 2022).
# xcodebuild's SPM resolution shells out to git, so this matters even without
# explicit git commands.
if sudo -u "$UITEST_USER" git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$REPO_ROOT"; then
    skip "$UITEST_USER already trusts $REPO_ROOT as a safe.directory"
else
    sudo -u "$UITEST_USER" git config --global --add safe.directory "$REPO_ROOT"
    ok "added $REPO_ROOT to $UITEST_USER's git safe.directory list"
fi

# ---------------------------------------------------------------------------
# Step 5b: share main user's Go module cache (optional, but skips re-downloads)
# ---------------------------------------------------------------------------
# The fzf submodule is built from Go sources inside an Xcode Run Script phase.
# When cctermtest builds for the first time, `go build` tries to fetch modules
# from proxy.golang.org — which is unreachable from some networks (notably
# behind the Great Firewall). If the host user already has those modules
# cached, share that cache read-only so cctermtest's builds avoid the network.

step "Step 5b: share main user's Go module cache with $UITEST_USER (optional)"

MAIN_GOMODCACHE=""
if command -v go >/dev/null 2>&1; then
    MAIN_GOMODCACHE="$(go env GOMODCACHE 2>/dev/null || true)"
fi

if [ -z "$MAIN_GOMODCACHE" ] || [ ! -d "$MAIN_GOMODCACHE" ]; then
    skip "no Go module cache to share (go env GOMODCACHE empty or path missing)"
    skip "  cctermtest will fetch from proxy.golang.org on first build — fine if your network allows it"
else
    ok "found Go module cache: $MAIN_GOMODCACHE"
    # Traversal ACLs walking parent → /
    p="$MAIN_GOMODCACHE"
    while [ "$p" != "/" ] && [ -n "$p" ]; do
        sudo chmod +a "user:$UITEST_USER allow execute,search,readattr,readextattr,list" "$p" 2>/dev/null || true
        p="$(dirname "$p")"
    done
    sudo chmod -R +a "user:$UITEST_USER allow read,execute,readattr,readextattr,readsecurity,list,search,file_inherit,directory_inherit" "$MAIN_GOMODCACHE" 2>/dev/null || true

    # Write a managed block to cctermtest's ~/.zshenv. Sentinels let us replace
    # cleanly on re-run and let uninstall.sh strip it.
    UITEST_ZSHENV="/Users/$UITEST_USER/.zshenv"
    TMP_ZSHENV="$(mktemp)"
    if sudo test -f "$UITEST_ZSHENV"; then
        sudo cat "$UITEST_ZSHENV" | sed '/# ccterm-uitest-begin/,/# ccterm-uitest-end/d' > "$TMP_ZSHENV"
    fi
    {
        echo "# ccterm-uitest-begin (managed by macos/scripts/uitest/setup.sh — do not edit by hand)"
        echo "# Shares the host user's Go module cache (read-only) so xcodebuild's fzf"
        echo "# build phase doesn't try to fetch from proxy.golang.org."
        echo "export GOMODCACHE=\"$MAIN_GOMODCACHE\""
        echo "export GOFLAGS=\"-mod=readonly\""
        echo "# ccterm-uitest-end"
    } >> "$TMP_ZSHENV"

    sudo install -m 644 -o "$UITEST_USER" -g staff "$TMP_ZSHENV" "$UITEST_ZSHENV"
    rm -f "$TMP_ZSHENV"
    ok "wrote managed GOMODCACHE block to $UITEST_ZSHENV"
fi

# ---------------------------------------------------------------------------
# Step 6: install state dir, autoswitch agent, first-run script
# ---------------------------------------------------------------------------

step "Step 6: install autoswitch LaunchAgent and helper scripts"

STATE_DIR="$UITEST_HOME/.ccterm-uitest"
LA_DIR="$UITEST_HOME/Library/LaunchAgents"
LA_PLIST="$LA_DIR/com.ccterm.uitest.autoswitch.plist"

sudo install -d -m 755 -o "$UITEST_USER" -g staff "$STATE_DIR"
sudo install -d -m 700 -o "$UITEST_USER" -g staff "$LA_DIR"

# Copy templates
sudo install -m 755 -o "$UITEST_USER" -g staff "$TEMPLATES_DIR/autoswitch.sh"  "$STATE_DIR/autoswitch.sh"
sudo install -m 755 -o "$UITEST_USER" -g staff "$TEMPLATES_DIR/first-run.sh"   "$STATE_DIR/first-run.sh"
sudo install -m 644 -o "$UITEST_USER" -g staff "$TEMPLATES_DIR/com.ccterm.uitest.autoswitch.plist" "$LA_PLIST"

# Drop the skip sentinel: the FIRST cctermtest login won't auto-switch.
# This lets the user run first-run.sh and accept TCC prompts in peace.
# first-run.sh removes this sentinel as its last step.
sudo touch "$STATE_DIR/skip-autoswitch"
sudo chown "$UITEST_USER:staff" "$STATE_DIR/skip-autoswitch"

ok "installed $LA_PLIST"
ok "installed $STATE_DIR/autoswitch.sh"
ok "installed $STATE_DIR/first-run.sh"
ok "armed skip sentinel for first cctermtest login"

# ---------------------------------------------------------------------------
# Step 7: allow cctermtest passwordless sudo for the few commands first-run needs
# ---------------------------------------------------------------------------

step "Step 7: grant cctermtest passwordless sudo for mdutil (Spotlight disable)"

SUDOERS_DROPIN="/etc/sudoers.d/ccterm-uitest"
# Tightly-scoped: only the two exact commands first-run.sh actually runs.
# No wildcards, no path glob — sudoers does string-equality argument matching.
SUDOERS_CONTENT="# Installed by macos/scripts/uitest/setup.sh.
# Allows cctermtest to disable Spotlight indexing on its own home without
# a password prompt. Two precise command signatures — no shell, no glob.
$UITEST_USER ALL=(root) NOPASSWD: /usr/bin/mdutil -i off /Users/$UITEST_USER, /usr/bin/mdutil -E /Users/$UITEST_USER"

if sudo test -f "$SUDOERS_DROPIN" && sudo grep -qF "$SUDOERS_CONTENT" "$SUDOERS_DROPIN"; then
    skip "sudoers drop-in already present and matches expected content"
else
    # Write to a temp location, validate, then move into place.
    TMP_SUDOERS="$(mktemp)"
    echo "$SUDOERS_CONTENT" > "$TMP_SUDOERS"
    if sudo visudo -cf "$TMP_SUDOERS" >/dev/null; then
        sudo install -m 440 -o root -g wheel "$TMP_SUDOERS" "$SUDOERS_DROPIN"
        rm -f "$TMP_SUDOERS"
        ok "wrote $SUDOERS_DROPIN (restricted to 2 exact mdutil invocations)"
    else
        rm -f "$TMP_SUDOERS"
        fatal "sudoers drop-in failed visudo validation"
    fi
fi

# ---------------------------------------------------------------------------
# Step 8: enable auto-login to cctermtest
# ---------------------------------------------------------------------------

AUTOLOGIN_ACTIVE=0

if [ "$ENABLE_AUTOLOGIN" = "1" ]; then
    step "Step 8: set auto-login to $UITEST_USER"

    current_autologin="$(sudo defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
    if [ "$current_autologin" = "$UITEST_USER" ]; then
        skip "auto-login already targets $UITEST_USER"
        AUTOLOGIN_ACTIVE=1
    else
        autologin_out="$(sudo sysadminctl -autologin set -userName "$UITEST_USER" -password "$UITEST_PASS" 2>&1 || true)"
        if echo "$autologin_out" | grep -qi 'FileVault'; then
            warn "auto-login disabled by macOS because FileVault is enabled"
            warn "after each reboot you'll need: \`make uitest-wake\` to bring up cctermtest"
            warn "(this is a macOS security policy — disable FileVault if you really want autologin)"
        elif sudo defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null | grep -qx "$UITEST_USER"; then
            ok "auto-login set to $UITEST_USER (you still type your own password to enter $MAIN_USER)"
            AUTOLOGIN_ACTIVE=1
        else
            warn "auto-login set silently failed. sysadminctl said:"
            echo "$autologin_out" | sed 's/^/      /'
            warn "you'll need \`make uitest-wake\` after each reboot."
        fi
    fi
else
    step "Step 8: auto-login (skipped per --no-autologin)"
    skip "after each reboot, run \`make uitest-wake\` to bring up the test session"
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------

cat <<EOF

${GREEN}${BOLD}Setup complete.${RESET}

EOF

if [ "$AUTOLOGIN_ACTIVE" = "1" ]; then
    cat <<EOF
${YELLOW}${BOLD}⚠ Do not reboot until you've completed the two manual steps below.${RESET}
${YELLOW}   Auto-login is active. If you reboot now, the Mac will land on cctermtest's
   desktop (with the skip sentinel keeping it foreground). Recovering is easy
   (Apple menu → Log Out cctermtest → log in to $MAIN_USER), but better to
   finish the two steps now.${RESET}

EOF
else
    cat <<EOF
${DIM}Auto-login is NOT active (FileVault or otherwise). After each reboot you'll
run ${BOLD}make uitest-wake${RESET}${DIM} to bring up cctermtest's session — ~10s of screen
switching, then back to your account.${RESET}

EOF
fi

cat <<EOF
${BOLD}Next — two manual steps you cannot script (TCC requires interactive consent):${RESET}

  1. ${BOLD}Switch to $UITEST_USER:${RESET}
        Apple menu → switch user → $UITEST_FULLNAME
        password: $UITEST_PASS
     (autoswitch is ARMED with a skip sentinel — cctermtest will stay foreground this one time)

  2. ${BOLD}Open Terminal inside cctermtest, then run:${RESET}
        ~/.ccterm-uitest/first-run.sh
        cd $REPO_ROOT
        make test FILTER=InputBar2StopButtonUITests
     Click Allow on every macOS permission dialog. Then log out of cctermtest.

After that, your existing ${BOLD}make test FILTER=…${RESET} workflow runs UI tests with
zero visible disturbance — the test runner auto-detects this setup and
forwards through SSH. CI is unaffected (the auto-detect only activates when
the setup is present).

Full guide: macos/scripts/uitest/README.md
EOF

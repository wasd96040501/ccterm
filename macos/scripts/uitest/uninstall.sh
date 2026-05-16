#!/bin/bash
# Reverse macos/scripts/uitest/setup.sh.
#
# Defaults to keeping the cctermtest account intact (so you don't lose its
# DerivedData cache). Pass --delete-user to remove the account entirely.

set -uo pipefail

UITEST_USER="${UITEST_USER:-cctermtest}"
DELETE_USER=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

for arg in "$@"; do
    case "$arg" in
        --delete-user) DELETE_USER=1 ;;
        -h|--help)
            echo "usage: $0 [--delete-user]"
            exit 0
            ;;
    esac
done

BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
step()  { echo ""; echo "${BOLD}==> $*${RESET}"; }
ok()    { echo "    ${GREEN}✓${RESET} $*"; }
skip()  { echo "    ${DIM}· $*${RESET}"; }
warn()  { echo "    ${YELLOW}!${RESET} $*"; }

if [ "$(id -u)" -eq 0 ]; then
    echo "run as your normal user, not root" >&2; exit 1
fi

sudo -v || exit 1

step "1. disable auto-login"
current="$(sudo defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
if [ -n "$current" ]; then
    sudo sysadminctl -autologin off
    ok "auto-login disabled (was: $current)"
else
    skip "auto-login already off"
fi

step "2. remove sudoers drop-in"
SUDOERS="/etc/sudoers.d/ccterm-uitest"
if sudo test -f "$SUDOERS"; then
    sudo rm -f "$SUDOERS"
    ok "removed $SUDOERS"
else
    skip "$SUDOERS not present"
fi

step "2b. remove sshd drop-in"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-ccterm-uitest.conf"
if sudo test -f "$SSHD_DROPIN"; then
    sudo rm -f "$SSHD_DROPIN"
    ok "removed $SSHD_DROPIN (effective on next ssh connection)"
else
    skip "$SSHD_DROPIN not present"
fi

step "3. strip cctermtest ACLs from $REPO_ROOT and its parents"

# Removes ACEs that mention `user:$UITEST_USER `. Uses ls -lde + chmod -a# by
# numeric index. Loops because indices renumber after each removal.
strip_user_aces() {
    local path="$1" user="$2" max_iters=20
    local i=0 idx
    while [ "$i" -lt "$max_iters" ]; do
        idx="$(/bin/ls -lde "$path" 2>/dev/null | awk -v u="$user" '
            $0 ~ ("user:" u " ") {
                sub(/:.*/, "")
                sub(/^ +/, "")
                print
                exit
            }')"
        [ -z "$idx" ] && return 0
        sudo chmod -a# "$idx" "$path" 2>/dev/null || return 0
        i=$((i + 1))
    done
}

if [ -d "$REPO_ROOT" ]; then
    # Walk every file/dir under the repo
    while IFS= read -r -d '' path; do
        strip_user_aces "$path" "$UITEST_USER"
    done < <(sudo find "$REPO_ROOT" -print0 2>/dev/null)

    # Walk parents up to /
    p="$REPO_ROOT"
    while [ "$p" != "/" ] && [ -n "$p" ]; do
        p="$(dirname "$p")"
        strip_user_aces "$p" "$UITEST_USER"
    done

    ok "stripped cctermtest ACLs (verify with \`ls -lde $REPO_ROOT\`)"
else
    skip "$REPO_ROOT not found"
fi

step "4. delete cctermtest user state"
if id -u "$UITEST_USER" >/dev/null 2>&1; then
    if [ "$DELETE_USER" = "1" ]; then
        # `sysadminctl -deleteUser` also removes the home by default
        sudo sysadminctl -deleteUser "$UITEST_USER"
        ok "deleted user $UITEST_USER and its home"
    else
        # Just remove our installed files; keep the account.
        sudo rm -rf "/Users/$UITEST_USER/.ccterm-uitest"
        sudo rm -f "/Users/$UITEST_USER/Library/LaunchAgents/com.ccterm.uitest.autoswitch.plist"
        # Strip our managed block from cctermtest's ~/.zshenv (leave any user-added content)
        if sudo test -f "/Users/$UITEST_USER/.zshenv"; then
            TMP_ZSHENV="$(mktemp)"
            sudo cat "/Users/$UITEST_USER/.zshenv" \
                | sed '/# ccterm-uitest-begin/,/# ccterm-uitest-end/d' > "$TMP_ZSHENV"
            if [ -s "$TMP_ZSHENV" ]; then
                sudo install -m 644 -o "$UITEST_USER" -g staff "$TMP_ZSHENV" "/Users/$UITEST_USER/.zshenv"
            else
                sudo rm -f "/Users/$UITEST_USER/.zshenv"
            fi
            rm -f "$TMP_ZSHENV"
        fi
        ok "removed CCTerm artifacts from /Users/$UITEST_USER (account kept)"
        warn "to delete the account too: $0 --delete-user"
    fi
else
    skip "user $UITEST_USER does not exist"
fi

step "5. (Remote Login & Fast User Switching left enabled — disable manually if you want)"
echo "    Remote Login: sudo systemsetup -setremotelogin off"
echo "    Fast User Switching: System Settings → Control Center → Fast User Switching"

echo ""
echo "${GREEN}${BOLD}Uninstall complete.${RESET}"

# Local UI Test Setup (run XCUITest without losing focus)

> **TL;DR** — one-time `make uitest-setup` (asks for your sudo password). After that, `make test FILTER=…` transparently routes through a hidden second user account. Your foreground session is never disturbed. CI is unaffected (the routing only activates when the test account is set up).

CCTerm's UI tests are XCUITest-based. By default they steal keyboard / mouse focus, which makes local runs painful — that's why [CLAUDE.md](../CLAUDE.md) tells you to push to CI.

The setup below uses a second macOS user account (`cctermtest`) kept alive in the background via Fast User Switching. Because each macOS user has its own isolated Aqua session (WindowServer, HID dispatch, pasteboard, NotificationCenter), the test runner's events stay inside that hidden session. You keep using your machine normally.

`macos/scripts/test.sh` (i.e. `make test`) auto-detects the setup: if `cctermtest` exists and its session is alive, it forwards via SSH transparently. If not, it falls back to running locally just like before. No code change for CI; opt out at runtime with `UITEST_FORCE_LOCAL=1 make test FILTER=…` if you need to.

---

## How it works

```
┌────────────────────────┐          ┌──────────────────────────────┐
│  Your account (front)  │          │  cctermtest (hidden, FUS bg) │
│  ─────────────────     │          │  ──────────────────────────  │
│  • You browse / code   │          │  • Aqua session is alive     │
│  • Terminal opens here │  ssh →   │  • xcodebuild test runs here │
│                        │          │  • Synthetic clicks, focus,  │
│  Screen, keyboard,     │          │    pasteboard all isolated   │
│  pasteboard, audio:    │          │                              │
│  YOURS, untouched      │          │  CPU / fans: shared (sorry)  │
└────────────────────────┘          └──────────────────────────────┘
```

Boundary guarantees come straight from macOS:

- **Screen / cursor**: each user has its own WindowServer instance. The hidden user's screen is composited but not shown.
- **Keyboard / mouse**: HID events route to the foreground session only.
- **Clipboard, NotificationCenter, Dock**: per-session, isolated.
- **Audio**: ⚠ shared. Setup script mutes `cctermtest` to avoid surprise beeps.
- **CPU / disk / fans / battery**: ⚠ physical, can't isolate. Test runs heat the machine.

---

## What gets installed

| Artifact | Path | Purpose |
|---|---|---|
| User account | `/Users/cctermtest` | Standard (non-admin) user, runs the tests |
| ACL on repo | `/Users/<you>/.../ccterm` | Read+execute for `cctermtest` (no write) |
| SSH authorized_keys | `/Users/cctermtest/.ssh/authorized_keys` | Lets you `ssh cctermtest@localhost` without a password |
| sshd drop-in | `/etc/ssh/sshd_config.d/99-ccterm-uitest.conf` | Restricts cctermtest SSH to loopback + pubkey-only |
| Sudoers drop-in | `/etc/sudoers.d/ccterm-uitest` | Allows cctermtest to disable its own Spotlight without a password (exact-match `mdutil` only) |
| LaunchAgent | `/Users/cctermtest/Library/LaunchAgents/com.ccterm.uitest.autoswitch.plist` | On login, switches back to your account so you don't see cctermtest's desktop |
| Daemon pruner | `/Users/cctermtest/.ccterm-uitest/first-run.sh` | Run once inside cctermtest to disable Spotlight, Siri, iCloud daemons, etc. |
| Auto-login | `/etc/kcpassword` | Boots straight into `cctermtest` (which immediately switches back to you) |

Everything is reversed by `make uitest-uninstall`.

---

## System changes (so you know what's happening)

Setup will:

1. **Create user** `cctermtest` (standard, password `ccterm-uitest` by default — override with `UITEST_USER` / `UITEST_PASS`).
2. **Enable Fast User Switching** (`MultipleSessionEnabled` in global prefs).
3. **Enable Remote Login** (`systemsetup -setremotelogin on`) and add `cctermtest` to `com.apple.access_ssh`.
4. **Add your SSH pubkey** (`~/.ssh/id_ed25519.pub` or `id_rsa.pub`) to cctermtest's `authorized_keys`.
5. **Grant `cctermtest` read+execute ACLs** on this repo's path so it can compile and run tests against your working tree.
6. **Install an autoswitch LaunchAgent** in cctermtest's home that does `CGSession -suspend` shortly after login.
7. **Set auto-login** to `cctermtest` so the hidden session always exists after a reboot.

If you don't want auto-login (e.g. you encrypt your disk and prefer FileVault gating), pass `--no-autologin`. You'll then run `make uitest-wake` manually after each reboot (10-second screen flicker).

---

## One-time setup

```bash
# From the repo root, on your main user:
make uitest-setup
```

You'll be prompted for your `sudo` password.

After the script finishes, you have **two unavoidable manual steps** because TCC permissions can't be granted by script when SIP is on:

### Manual step 1 — log into `cctermtest` once

Open the Apple menu → switch user → pick **CCTerm UI Test** → enter password (default `ccterm-uitest`).

> The autoswitch agent only takes effect *after* this first login completes the user's home initialization. The setup script leaves a sentinel file that tells the agent to skip the switch on this first run.

### Manual step 2 — run first-run.sh and accept TCC prompts (inside cctermtest)

First-time login will run through macOS's SetupAssistant (region, appearance, etc.). Skip Apple ID, skip Touch ID, skip Migration — pick anything reasonable for the rest. This takes ~30 seconds.

Once you reach cctermtest's desktop, open Terminal and run:

```bash
~/.ccterm-uitest/first-run.sh
```

The script:

- Disables Spotlight indexing on cctermtest's home (saves persistent CPU + disk).
- Boots out unneeded LaunchAgents (Siri, Photos, iCloud, etc.) — saves ~500 MB–1 GB RAM.
- Mutes system audio.
- Pauses, then triggers the autoswitch's macOS TCC prompt — a dialog will appear asking *"osascript wants to control loginwindow"*. **Click Allow.**

After Allow, the screen jumps to the macOS login picker. Pick your main account, type your password, and you're back. cctermtest's Aqua session stays alive in the background — that's the whole point.

Later, when you run a UI test for the first time, you'll get another TCC dialog (Accessibility / Automation for the XCUITest runner). Same drill — click Allow. Permissions are remembered after that.

> macOS Sequoia 15+ asks for Screen Recording reconfirmation monthly — you'll get one extra click once a month. No workaround short of an MDM profile.

---

## Daily use

```bash
# Run one test class
make test FILTER=InputBar2StopButtonUITests

# Run one method
make test FILTER=InputBar2StopButtonUITests/testStopButtonCancelsRunningState

# Force local execution (focus theft, like before setup) — useful for CI:
UITEST_FORCE_LOCAL=1 make test FILTER=…
```

`make test` automatically detects the setup. When `cctermtest` exists *and* its session is alive *and* SSH works, the script transparently `ssh`'s into cctermtest and runs `xcodebuild test` there. Logs and `.xcresult` are written to `/tmp/ccterm-test-…` (cctermtest's side; `/tmp` is shared, so they're readable from your main account).

When the setup isn't present (e.g. on CI or a fresh dev machine), `make test` falls back to running locally — same behavior as before this doc existed. No CI changes needed.

### What you see during a run

- A burst of fan noise / CPU activity. **That's it.**
- No window flicker, no cursor jumping, no focus theft.
- If you alt-tab into a sound-emitting app you'll notice nothing.

### After a reboot

- If you use FileVault (very common): macOS disables auto-login. Run `make uitest-wake` once after each reboot — ~10 seconds of screen switching to bring `cctermtest`'s session back up.
- If auto-login was enabled at setup time (no FileVault): the machine boots into cctermtest for ~3 seconds, then the autoswitch agent flips you to the login window. Enter your main password as normal.

---

## Troubleshooting

### `make test` reports "running locally (will steal focus)"

Either cctermtest's Aqua session isn't alive or sshd can't be reached. Quick diagnostics:

```bash
# Is cctermtest's session running?
pgrep -u cctermtest -x Dock

# Does sshd answer?
nc -z 127.0.0.1 22

# Can we ssh in?
ssh cctermtest@127.0.0.1 echo ok
```

Common causes:
- After a reboot with FileVault → run `make uitest-wake`.
- Remote Login got turned off → System Settings → General → Sharing → Remote Login → ON.
- The host's IP changed and `known_hosts` is stale → `ssh-keygen -R 127.0.0.1 && ssh-keyscan 127.0.0.1 >> ~/.ssh/known_hosts`.

### Tests fail with `App is not registered for Accessibility`

You skipped manual step 2. Switch into cctermtest and run `~/.ccterm-uitest/first-run.sh`, then accept the dialogs.

### `cctermtest`'s desktop stays visible after auto-login

The autoswitch LaunchAgent didn't load. Inside cctermtest, check:

```bash
launchctl print gui/$(id -u)/com.ccterm.uitest.autoswitch
```

If missing, re-run setup. If present but failing, look at `/Users/cctermtest/.ccterm-uitest/autoswitch.log`.

### Autoswitch doesn't return me to my account

macOS 14+ removed the `CGSession` binary. The autoswitch helper now relies on AppleScript:

1. Primary: `tell application "loginwindow" to «event aevtsclk»` — needs **Automation** TCC for osascript→loginwindow.
2. Fallback: keystroke `⌘⌃Q` — needs **Accessibility** TCC for osascript.

If autoswitch silently does nothing, open cctermtest's session, run `cat ~/.ccterm-uitest/autoswitch.log`, and look at the last entry. Common fix: grant the missing permission in `System Settings → Privacy & Security → Automation` (or `Accessibility`). The osascript binary may appear under the parent process (Terminal/bash) — toggle Allow there.

### Permission dialogs keep coming back

macOS Sequoia 15+ resets Screen Recording permission monthly. There's no workaround short of an MDM PPPC profile. Just accept again.

### I want my account back / start over

```bash
make uitest-uninstall
```

This:

- Disables auto-login.
- Removes `cctermtest`'s LaunchAgent, sentinel, scripts.
- Optionally deletes the `cctermtest` account (asks first).
- Removes ACLs from your repo.

Remote Login stays on (you may want it for other reasons) — disable it manually if you don't.

---

## Implementation notes

- Setup is idempotent — re-running fixes drift instead of duplicating state.
- macOS 14 (Sonoma) removed `CGSession`. autoswitch now uses `osascript` to send the `«aevtsclk»` Apple event to `loginwindow`, falling back to a `⌘⌃Q` keystroke. The fallback path requires Accessibility TCC for osascript.
- DerivedData lives at `/Users/cctermtest/Library/Developer/Xcode/DerivedData` — independent from your main account, so your incremental builds aren't disturbed.
- Code signing for UI tests uses `CODE_SIGNING_ALLOWED=NO` (same as `test.sh`), so cctermtest doesn't need access to your developer certificates.

## Security

The setup makes several security-relevant changes. Each is hardened to limit blast radius.

### sshd whitelists exactly one user, loopback only

`/etc/ssh/sshd_config.d/99-ccterm-uitest.conf` installs:

```
AllowUsers cctermtest@127.0.0.1 cctermtest@::1
Match User cctermtest
    PasswordAuthentication no
    AuthenticationMethods publickey
```

`AllowUsers` is a sshd protocol-level whitelist: any user / source not matching is rejected **before** PAM, before authentication, before banner. The effect:

- Network-side attackers see port 22 open but cannot log in as **any** user — your main account included.
- Even from loopback (`127.0.0.1` / `::1`), only `cctermtest` can connect, and only via public-key auth (the default password `ccterm-uitest` is unreachable over SSH at all).

There's no way for the open Remote Login to expose your main account, because sshd refuses to even try authenticating it.

### Passwordless sudo is tightly scoped

`/etc/sudoers.d/ccterm-uitest` allows exactly two command signatures (no glob, no shell, no wildcards):

```
cctermtest ALL=(root) NOPASSWD: /usr/bin/mdutil -i off /Users/cctermtest,
                                /usr/bin/mdutil -E /Users/cctermtest
```

`mdutil` is Apple's Spotlight control utility with no known privilege-escalation primitives. Even if `cctermtest` is fully compromised, the attacker cannot `sudo bash`, write arbitrary files, or spawn a root shell through this rule.

### Cross-user blast radius

If `cctermtest` is compromised, the attacker:

- **cannot read** your home (default `700` permissions; macOS keeps it private),
- **can read but not write** the repo (we only grant `read,execute` ACLs),
- **cannot see** your Aqua session — keyboard events, clipboard, screen, notifications are per-session,
- **cannot read** your Keychain (per-user),
- **cannot escalate to root** through our sudoers rule (only `mdutil` with fixed args).

The attacker *can* write to `/tmp` (shared), and *can* toggle Spotlight indexing on `cctermtest`'s home. Both are low-impact and reversible.

### Default password

`cctermtest`'s password defaults to `ccterm-uitest`. Anyone with **physical** access to the Mac who picks `CCTerm UI Test` at the login window can log in. Override via:

```bash
UITEST_PASS="$(openssl rand -hex 16)" make uitest-setup
```

Save the value somewhere (1Password, Keychain). You only need it if you ever switch to `cctermtest` manually — daily SSH access uses your public key.

### Auto-login and FileVault

Auto-login uses `/etc/kcpassword` (XOR-obfuscated, not encrypted). If your disk is unlocked, anyone who reboots can land in `cctermtest`'s desktop (which the autoswitch agent flips away from in ~2 seconds). With FileVault, the disk-unlock prompt still gates the boot — auto-login only kicks in after unlock.

### Repo ACL

Read+execute only. `cctermtest` can compile and run the project but cannot modify your working tree. Build outputs go to `cctermtest`'s own `~/Library/Developer/Xcode/DerivedData` — they don't touch your DerivedData cache.

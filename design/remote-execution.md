# Remote Execution — run Claude Code against a remote machine

**Status:** Proposal (feasibility proven, see §2)
**Scope:** AgentSDK launch seam · new app-layer remote services · New-Session UI
**Author:** design discussion, 2026-06

---

## 1. Goal

Let a user run Claude **locally** (the CCTerm UI, the model, the control loop)
while the **filesystem and every Bash command execute on a remote machine** —
a dev box, a build server, a locked-down CI host. The remote side needs no
bespoke daemon: a standard `sshd` is enough.

Concretely, after picking a remote host for a session:

- `Read` / `Edit` / `Glob` / `Grep` / `Bash` all operate on the **remote**
  filesystem and shell.
- The remote shell type follows the **remote** machine (`$SHELL -l`), reading
  the remote user's profile — never hard-coded.
- If the remote machine has **no outbound internet**, it reaches the Anthropic
  API by **borrowing the Mac's egress** through the same SSH connection
  (reverse tunnel → the user's existing HTTP proxy, or a proxy CCTerm runs).

### Why "run Claude on the remote", not "forward each tool from local Claude"

An earlier idea was to keep Claude local and rewrite each `Bash` tool call into
`ssh remote '<cmd>'` via a `PreToolUse` hook, plus SSHFS for the filesystem.
That approach **simulates** remote: every `Read`/`Glob`/`Grep` pays a FUSE +
network round trip, Bash needs cwd/env remapping, git and file-watching are
degraded — the cost is **smeared across every operation, forever**. The
`PreToolUse` hook also cannot substitute a tool result (it can only
allow/deny/ask and optionally rewrite the input — confirmed against the
[hooks docs](https://code.claude.com/docs/en/hooks)), so it can never return
clean stdout/exit-code semantics.

Running Claude **on** the remote makes remote **native**: the Claude process
sees a real local filesystem, shell, git, env. The Mac degrades to a pure
front-end whose only job is to move the stream-json control protocol over SSH
instead of a local pipe. The cost concentrates at **one boundary** (one-time,
engineerable) instead of being smeared across every tool call.

---

## 2. Feasibility — already proven against a real remote

Both load-bearing assumptions were verified end-to-end against a real
restricted-network Debian dev box (`devbox`, reachable only via the corp SSH
config), driving small Python stand-ins instead of Claude.

### 2a. Transport channel — stream-json survives SSH intact

`ssh -T devbox python3 -u echo.py`, feeding newline-delimited JSON and checking
a SHA-256 round trip:

| line | payload | bytes | byte-exact |
|---|---|---|---|
| 0 | plain JSON | 46 | ✅ |
| 1 | unicode (`世界 🚀 — “quotes”`) | 74 | ✅ |
| 2 | backslash / dquote / tab / control chars | 69 | ✅ |
| 3 | 200 KB single line | 200027 | ✅ |
| 4 | nested JSON | 65 | ✅ |

First response at **882 ms** (not buffered until EOF). `-T` allocates **no
PTY**, so there is no CRLF translation and no `^C` interpretation — the pipe is
**8-bit clean**, exactly what stream-json needs.

### 2b. Reverse-egress channel — remote borrows the Mac's network

One command does both jobs — transport **and** egress:

```bash
ssh -T -R 127.0.0.1:8899:127.0.0.1:8888 devbox \
  'HTTPS_PROXY=http://127.0.0.1:8899 HTTP_PROXY=http://127.0.0.1:8899 \
   python3 -u fetch.py'
```

| target | devbox direct | via the tunnel |
|---|---|---|
| `https://api.ipify.org` (HTTPS/CONNECT) | ❌ **Connection refused** | ✅ egress IP = **the Mac's** |
| `http://ifconfig.me/ip` (plain HTTP) | ✅ devbox's IP | ✅ **the Mac's** IP |

The decisive evidence: `api.ipify.org`, which devbox **cannot reach on its own
(refused)**, becomes reachable through the tunnel and returns **the Mac's**
egress IP — and the Mac proxy log recorded both the `CONNECT` and the `GET`
arriving from `127.0.0.1` (the `ssh -R` forwarder). HTTPS stays end-to-end TLS:
the proxy blind-forwards `CONNECT`, so SNI/cert remain the real domain — no base
URL rewrite, no injected cert.

**Takeaways that shape the design below:**

- `-T` (no PTY) is mandatory; the remote launch must not print to stdout before
  Claude starts (a login banner would corrupt the JSON stream) — so the remote
  command `exec`s Claude directly rather than going through an interactive shell.
- Egress is just a different `ssh -R` target: point it at the user's existing
  proxy (zero extra process) **or** at a proxy CCTerm runs.
- Zero remote install — `sshd` + the remote's own `claude` binary are all that's
  needed.

---

## 3. Architecture & layering

**Principle:** AgentSDK stays a faithful, transport-agnostic wrapper of the
Claude CLI stream-json protocol. It must not learn what "ssh" or "proxy" means.
Everything stateful and domain-specific lives in the CCTerm app layer.

### 3a. The one AgentSDK change — structured launch (argv, not a string)

Today the only launch seam is `SessionConfiguration.customCommand`, parsed by a
naive space split (`AgentSDK/Sources/AgentSDK/AgentSDK.swift:122`,
`customCommand.split(separator: " ")`). That is fatal for an ssh launch: the
remote `env KEY=val … claude` segment breaks the moment any value (a path, a
workdir) contains a space.

Replace/augment it with a structured plan:

```swift
public enum LaunchPlan {
    case local(binaryPath: String?)                    // current behavior
    case wrapped(executable: String, argv: [String])   // app builds the full ssh argv
}
```

The SDK simply runs `executable` with `argv` (no tokenizing) and keeps owning
the `Process` lifecycle. It **still does not know about ssh**. ~20 lines;
`customCommand` can remain for back-compat.

### 3b. New app-layer components

Each mirrors an existing pattern so none of this is novel infrastructure:

| New component | Mirrors | Responsibility |
|---|---|---|
| `RemoteHost` (Codable model) | `SessionConfig` | ssh alias/host/user/port/identity, remote `claude` path, remote workdir, proxy mode |
| `RemoteHostStore` (`@Observable`, app-scope) | `RecentProjectsStore` | persist the host list; injected via `.environment()` |
| `RemoteEgressService` (`@Observable`, app-scope) | — | owns the Mac-side proxy process (or "use existing proxy" passthrough) lifecycle, status, logs; **shared across sessions** to the same host |
| `SSHLaunchBuilder` (pure) | — | `(RemoteHost, egress decision, sessionId, workdir) → LaunchPlan.wrapped(...)` + remote env |
| `RemoteHostProbe` | — | connectivity validation for the sheet's "Test Connection" (the §2 echo/fetch checks, in Swift) |

**Why the proxy belongs in the app layer, not the SDK:** one proxy can be
shared by many sessions to the same host (the pooled-channel goal); it has UI
(status/logs); it persists settings; its lifecycle is independent of any single
`Session`. None of that belongs in a protocol wrapper.

### 3c. Where it plugs into the session chain (same shape as `cwd`/`worktree`)

The insertion point is structurally identical to how `cwd` and `worktreeBranch`
already flow, so it is a known pattern, not a new spine:

- `SessionConfig` gains `remoteHostId: String?`, persisted on `SessionRecord`
  exactly like `cwd` / `worktreeBranch`
  (`macos/ccterm/Services/Session/SessionConfig.swift`).
- `SessionConfig.toAgentSDKConfig(...)` (`SessionConfig.swift:135`), called from
  `SessionRuntime+Start.swift:431` (which already hoists `customCommand` from
  `UserDefaults`), resolves the host via `RemoteHostStore`, asks
  `RemoteEgressService` to ensure the tunnel is up, and produces a
  `LaunchPlan.wrapped(...)` instead of a `customCommand`.

### 3d. Data flow

```
┌─ Mac (local) ─────────────────────────────┐        ┌─ Remote (devbox) ──────────┐
│ Session / SessionRuntime                   │        │                            │
│   └ AgentSDK.Session (stream-json)         │        │                            │
│        stdin/stdout  ───────────────────── ssh -T ───────────► claude (remote)   │
│                                            │  pipe  │   reads remote FS,         │
│ RemoteEgressService                        │        │   runs remote bash,        │
│   └ CONNECT proxy :8888 ◄───── ssh -R ─────┼────────┤   HTTPS_PROXY=127.0.0.1:8899│
│        └ user proxy / direct → Anthropic   │        │   (no internet of its own) │
└────────────────────────────────────────────┘        └────────────────────────────┘
        one SSH connection carries both the protocol and the egress tunnel
```

### 3e. Connection pool (ControlMaster) — the "pooled channel" goal

Each remote session is its own `ssh` invocation running its own `claude`.
SSH **ControlMaster** multiplexing lets them share one TCP + auth handshake per
host (a persistent master), each session becoming a multiplexed channel — so
spawning the Nth session pays almost no handshake cost. Lives in
`SSHLaunchBuilder` / a per-host `SSHConnectionPool` owned by
`RemoteEgressService`. (`ControlMaster auto` + `ControlPath` + `ControlPersist`.)

### 3f. Lifecycle / orphan handling

The orphan risk (kill the local `ssh`, leave a stray remote `claude`) maps
cleanly onto the SDK's **existing** mechanism: `Session.close()` already closes
stdin → the CLI exits on EOF. Over `ssh -T`, channel close → the remote
`claude` gets stdin EOF → it exits. v1 therefore needs **ssh configured
correctly**, not a supervisor:

- `-T` / `RequestTTY=no` — no PTY (also required for protocol cleanliness).
- `ServerAliveInterval` / `ServerAliveCountMax` — detect a dead network.
- remote command `exec claude …` — propagate EOF/signals to the real process.

Surviving laptop sleep / network change with the remote session intact (a
remote supervisor that holds the `claude` process across reconnects) is a
**later** milestone (M5), explicitly out of scope for v1.

---

## 4. UI

The New-Session compose card's left "Projects" column already has a `+` button
that calls `presentFolderPicker()` directly
(`macos/ccterm/Content/Chat/NewSessionConfigurator.swift:262`). Turn it into a
SwiftUI `Menu` (SwiftUI-by-default per the architecture rules):

```
+  ▾
├─ Add Local Folder…              → existing presentFolderPicker()
├─ Remote ▸
│   ├─ <host A>                   → enter that host's context
│   ├─ <host B>
│   ├─ ──────────
│   └─ Add SSH Host…              → opens the config sheet
```

**Add-SSH-Host sheet** (SwiftUI `.sheet`):

- ssh fields: alias, host, user, port, identity file, remote `claude` path,
  remote workdir base.
- **Test Connection** — drives `RemoteHostProbe`, shows the green/red result
  from the §2 checks (reachable? interpreter present? egress via tunnel works?).
- **Proxy config** — radio:
  - *Use an existing local HTTP proxy* — host:port (zero extra process; `ssh -R`
    targets it directly).
  - *Let CCTerm run one* — starts the native Swift CONNECT proxy.
- Save → `RemoteHostStore.add`.

The Mac-side proxy for the "CCTerm runs one" mode is implemented natively in
Swift (`Network.framework` `NWListener`/`NWConnection`, ~150 lines, wired to app
lifecycle + `appLog`) — **not** the Python stand-in used for the §2
verification.

---

## 5. Open decisions

1. **Left-column project list when a remote host is selected.**
   - **(A, recommended)** the whole column switches to that host's context — a
     host switcher (Local / host A / host B) at the top, with the recents list +
     folder picker operating in that host's namespace.
   - (B) local and remote folders mixed in one list with a per-row host badge —
     smaller change, muddier mental model.

2. **v1 scope.** Recommended: **M1–M4** = v1 (bash + files genuinely run
   remote; UI can configure a host; locked-down remotes reach the API via the
   tunnel). **M5/M6** = v2. Open question: must v1 include remote session
   **history** (M6)? Without it, remote sessions' transcript JSONL lives only on
   the remote disk (`~/.claude/projects` on the remote) and won't appear in the
   sidebar — the local `HistoryLoader` reads local files today.

---

## 6. Milestones

Each is independently testable; early ones land behind a smoke target, reusing
the `InterruptSmoke` / `*Smoke` convention in `macos/AgentSDK/Sources/`.

| # | Milestone | Deliverable / verification |
|---|---|---|
| **M0** | Feasibility | ✅ done — clean transport + reverse-egress tunnel, verified on a real remote (§2) |
| **M1** | SDK `LaunchPlan` (argv-based) | change `SessionConfiguration`; `RemoteSmoke` target launches real `claude` on the remote over ssh, runs one turn; verify protocol + lifecycle + no orphan |
| **M2** | `RemoteEgressService` (proxy) | native Swift CONNECT proxy + "use existing proxy" passthrough; wire `ssh -R` into the argv; verify a no-internet remote reaches the API through the tunnel |
| **M3** | `RemoteHost` model/store + `SSHLaunchBuilder` + `RemoteHostProbe` | + ControlMaster pool; `SessionConfig.remoteHostId` end-to-end: create a host-bound session, send a message, bash/files run remote |
| **M4** | UI: menu + add-host sheet + proxy config | `+` → `Menu`; host submenu; sheet with Test Connection + proxy config; host-scoped project list (decision §5.1) |
| **M5** | Lifecycle hardening | reconnect on sleep/wake/network change; orphan reaping; error surfacing; remote `claude` version check |
| **M6** | Remote path / history semantics | remote folder picker (browse remote fs); per-host recents; remote session history (read `~/.claude` over sftp); disable/replace local-only path UI (Finder reveal, `--add-dir`, permission-prompt paths) |

**M1–M3** = "works and is usable"; **M4** = productized; **M5/M6** = completeness.

---

## 7. Non-goals (v1)

- Surviving network drops / laptop sleep with the remote session intact (M5).
- Reading remote session history into the sidebar (M6).
- Remote-path-aware "Reveal in Finder", `--add-dir`, permission-prompt path UI (M6).
- Authenticating the remote `claude` via the claude.ai OAuth browser flow on a
  headless box — v1 assumes API-key (or Bedrock/Vertex) credentials injectable as
  env at launch.

---

## 8. Risks

- **Login-shell PATH vs clean stdout.** Finding the remote `claude` wants a login
  shell, but a login shell may print a banner that corrupts the JSON stream.
  Resolution: pin the remote `claude` path (configured per host) and `exec` it
  directly; never route the protocol through an interactive shell.
- **Node proxy env coverage.** Claude runs on Node; confirm it honors
  `HTTPS_PROXY` for all API calls. Fallback: `ANTHROPIC_BASE_URL` → the tunnel +
  a remote `/etc/hosts` alias.
- **Protocol version skew.** The Mac's AgentSDK targets a CLI protocol version;
  the remote ships whatever `claude` is installed there. Add a version check at
  launch (M5).
- **sshd `MaxSessions`.** Default 10 multiplexed channels per connection caps
  per-host concurrency; document and surface, raise on the remote if needed.

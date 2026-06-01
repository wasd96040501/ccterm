# Remote Execution — run Claude Code against a remote machine

**Status:** Proposal — M1 (structured launch, §2d/§3a) + M2 egress-proxy primitive (§2c) landed; feasibility proven (§2)
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

### 2c. Egress proxy — both modes implemented & verified (M2)

The §2b feasibility used Python stand-ins. The real proxy now ships as
`RemoteEgress.ConnectProxy` (a separate SwiftPM target in the `AgentSDK`
package, kept out of `AgentSDK` itself so the protocol wrapper stays
proxy-agnostic — §3). It is a `Network.framework` forward proxy: blind-forwards
`CONNECT` (HTTPS stays end-to-end TLS) and forwards absolute-form plain HTTP.

`RemoteEgressSmoke` (`swift run RemoteEgressSmoke`) drives a real remote over
`ssh -R` and proves both egress modes end-to-end:

| mode | `ssh -R` target | result |
|---|---|---|
| **A — reuse existing proxy** | the user's own local HTTP proxy | remote's `curl` egresses at the Mac |
| **B — CCTerm's own proxy** | `ConnectProxy` on an ephemeral loopback port | remote's `curl` egresses at the Mac (CONNECT **and** plain HTTP) |

The decisive, non-flaky assertion: a packet can only egress at the remote (its
own NAT — one stable `/24`) or at the Mac, so the smoke asserts the IP a remote
`curl` reports through the tunnel is a valid public IP whose `/24` is **not** the
remote's own egress `/24`. (It does *not* try to match the Mac's egress pool —
that NAT spans many subnets per destination and equality there is flaky.) A
negative control confirms the HTTPS IP endpoint is unreachable from the remote
directly.

**Security:** `ConnectProxy` binds `127.0.0.1` only (via
`requiredLocalEndpoint`) — never an open CONNECT relay on a routable interface.
The smoke actively probes the proxy port over the Mac's LAN address and asserts
it is refused.

### 2d. Structured launch — real `claude` over ssh, proxy-forced (M1)

The §2a transport check used a Python echo stand-in. `RemoteSmoke`
(`swift run RemoteSmoke`) now drives the **real** `claude` on the remote through
the shipped `LaunchPlan.wrapped` seam (§3a) and proves all three M1
deliverables on one turn:

- **structured argv** — the ssh command runs verbatim, with the full
  `claudeArguments()` list shell-quoted into the remote command, so spaces in
  any flag value no longer mangle the launch;
- **protocol** — initialize + one prompt + the assistant reply + the final
  result envelope all survive `ssh -T` (no PTY, 8-bit-clean);
- **lifecycle / no orphan** — `session.close()` → stdin EOF → channel close →
  the remote `claude` exits; the smoke asserts no remote process carrying the
  session id survives.

**Egress is forced through the Mac's proxy and proven decisive, not assumed.**
Per project decision the remote `claude` must reach the API *only* via the Mac's
existing local HTTP proxy (default `127.0.0.1:1081`), tunneled over `ssh -R` —
never the remote's own network (mode A of §2c only; no `ConnectProxy` here).
`HTTPS_PROXY` *forces* this (Node routes through the proxy and never silently
falls back to a direct socket), and the smoke proves it with a **tunnel on/off
differential** that holds even when the remote *does* have its own route to the
API — the realistic case: the verified dev box refuses `api.ipify.org` but still
allowlists `api.anthropic.com` (HTTP 403 direct). So "can the remote reach the
API directly?" is the wrong question; "does a turn need our tunnel?" is the right
one. The proxy env points at a remote loopback port that is alive **only** while
our `ssh -R` is up, then:

- **Part 1 — curl differential:** a remote `curl -x <proxy-port> api.anthropic.com`
  is *refused* with the tunnel down and returns an HTTP code with it up — the
  `ssh -R → 1081` path is the API carrier, dead without the tunnel.
- **Part 2 — positive turn (tunnel up):** real `claude` runs a clean turn; its API
  egress flows through `1081`.
- **Part 3 — control turn (tunnel down):** the same launch *minus* `-R` must
  **fail** — claude cannot complete a turn without the proxy, so it provably is
  not using the remote's own network.

A turn that fails without the tunnel but succeeds with it can only have egressed
at the Mac.

---

## 3. Architecture & layering

**Principle:** AgentSDK stays a faithful, transport-agnostic wrapper of the
Claude CLI stream-json protocol. It must not learn what "ssh" or "proxy" means.
Everything stateful and domain-specific lives in the CCTerm app layer.

### 3a. The one AgentSDK change — structured launch (argv, not a string) ✅ landed (M1)

The only launch seam used to be `SessionConfiguration.customCommand`, parsed by a
naive space split (`customCommand.split(separator: " ")`). That is fatal for an
ssh launch: the remote `env KEY=val … claude` segment breaks the moment any
value (a path, a workdir) contains a space.

It is now augmented with a structured plan (`SessionConfiguration.launchPlan`):

```swift
public enum LaunchPlan {
    case local(binaryPath: String?)                    // current behavior
    case wrapped(executable: String, argv: [String])   // app builds the full argv
}
```

The SDK runs `executable` with **exactly** `argv` (no tokenizing, nothing
appended) and keeps owning the `Process` lifecycle. It **still does not know
about ssh**. When `launchPlan` is nil the legacy resolution
(`customCommand` → `binaryPath` → auto-locate) is preserved byte-for-byte, so
existing callers are unaffected.

`.wrapped` solves the *local* tokenizing problem; the *remote command* handed to
ssh is still a single shell string, so its quoting is the caller's job (the app
layer / M4's `SSHLaunchBuilder`), never the SDK's. To let the caller embed the
real claude flags into that command, the argv list the SDK would pass to `claude`
is exposed as `SessionConfiguration.claudeArguments()` — so what runs remotely is
byte-for-byte what would run locally.

### 3b. New app-layer components

Each mirrors an existing pattern so none of this is novel infrastructure:

| New component | Mirrors | Responsibility |
|---|---|---|
| `RemoteHost` (Codable model) | `SessionConfig` | ssh alias/host/user/port/identity, remote workdir, proxy mode, and the `RemoteClaudePolicy` (`managed` / `useRemote(path:)`, §3g) |
| `RemoteHostStore` (`@Observable`, app-scope) | `RecentProjectsStore` | persist the host list; injected via `.environment()` |
| `RemoteEgressService` (`@Observable`, app-scope) | — | owns the Mac-side proxy process (or "use existing proxy" passthrough) lifecycle, status, logs; **shared across sessions** to the same host |
| `SSHLaunchBuilder` (pure) | — | `(RemoteHost, egress decision, sessionId, workdir) → LaunchPlan.wrapped(...)` + remote env |
| `RemoteHostProbe` | — | connectivity validation for the sheet's "Test Connection" (the §2 echo/fetch checks, in Swift) |
| `RemoteProvisioner` | — | `managed` mode only: installs **our** pinned `claude` to a controlled remote path, idempotently (skip if already present + version matches); runs during the SSH-only provisioning status (§3g) |
| `RemoteCredentialResolver` | — | `managed` mode only: resolves the Mac's current credential (API key / refreshed claude.ai OAuth bearer) into launch-time env for `SSHLaunchBuilder`; refreshes OAuth on the Mac, never forwards the refresh token (§3i, §9) |
| `RemoteTranscriptFetcher` | `HistoryLoader` | on demand, pulls a remote session's `.jsonl` down to a local cache so the existing reverse-paging reader can read it (§3h) |

**Why the proxy belongs in the app layer, not the SDK:** one proxy can be
shared by many sessions to the same host (the pooled-channel goal); it has UI
(status/logs); it persists settings; its lifecycle is independent of any single
`Session`. None of that belongs in a protocol wrapper.

### 3c. Where it plugs into the session chain (same shape as `cwd`/`worktree`)

The insertion point is structurally identical to how `cwd` and `worktreeBranch`
already flow, so it is a known pattern, not a new spine:

- `SessionConfig` / `SessionRecord` gain new persisted fields, alongside the
  existing `cwd` / `worktreeBranch`
  (`macos/ccterm/Services/Session/SessionConfig.swift`,
  `Services/Session/SessionRecord.swift`):
  - `remoteHostId: String?` — which host the session runs on (nil = local). Also
    the signal that history must be fetched from the remote (§3h).
  - `remoteTranscriptPath: String?` — the remote `.jsonl` path for this session
    (resolved once the remote `claude` reports its session file), so history can
    be pulled later without re-deriving it.
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

### 3g. Provisioning & the SSH-only session status

Provisioning is a **per-host policy**, not one fixed behavior (resolved
decision #3):

```swift
enum RemoteClaudePolicy {
    case managed                  // CCTerm installs + pins its own claude (and owns login state, §3i)
    case useRemote(path: String?) // trust the remote's own claude; no download, no credential push
}
```

- **`managed`** — CCTerm installs **its own pinned** `claude` to a **controlled
  path** (e.g. `~/.ccterm/bin/claude`, version-stamped) so the protocol version
  is one we control. Installation is **idempotent**: if our binary already exists
  at that path with the expected version, provisioning is skipped. On a
  no-internet remote the download goes through the reverse tunnel established for
  the session, or — as a fallback — the binary is uploaded over the existing
  SSH/SFTP channel. In this mode CCTerm also **owns the login state**: it forwards
  the Mac's refreshed credential into the launch (§3i). This is the mode that
  mirrors how the official Claude desktop app provisions a remote (§9).

- **`useRemote(path:)`** — trust the `claude` already on the remote (a pinned
  absolute path, or login-shell-probed like `RemoteSmoke` does today). CCTerm
  **downloads nothing, writes nothing**, and — per decision #3 — **does not manage
  login state**: the remote `claude` authenticates with whatever credentials the
  user has configured on the remote (its own `~/.claude` / env). The user
  guarantees both a protocol-compatible binary and working auth. Provisioning
  degrades to a path probe plus an optional soft `--version` sanity check (warn,
  don't block). This mode is only possible because our transport is the vanilla
  stream-json protocol, not a bespoke daemon (contrast §9).

This setup is work that only the SSH path performs, and it happens *before* the
normal stream-json bootstrap. So `SessionRuntime.Status`
(`SessionRuntime.swift:20`, today `notStarted → starting → idle → responding →
interrupting → stopped`) gains a new case used **only** for remote sessions:

```swift
enum Status {
    case notStarted
    case starting
    case provisioning   // NEW — SSH-only: open master, ensure remote claude, bring up tunnel
    case idle
    case responding
    case interrupting
    case stopped
}
```

During `.provisioning` the UI shows a distinct "Connecting to <host>…" state:
ensure ControlMaster, bring up the `-R` tunnel, and — for `managed` only —
`RemoteProvisioner.ensureInstalled` + resolve the credential to forward (§3i).
For `useRemote` the provisioning step is just the path probe. Local sessions
never enter `.provisioning` and go straight `starting → idle`.

### 3h. Remote session history

A remote session's transcript JSONL is written by the remote `claude` under the
**remote** `~/.claude/projects/...`; the local `HistoryLoader` reads local files
today. When the user clicks a session whose record has a `remoteHostId`:

1. `RemoteTranscriptFetcher` pulls the remote `.jsonl`
   (`remoteTranscriptPath`) down to a local cache file over the pooled SSH
   channel (sftp / `ssh cat`), incrementally when possible.
2. The existing reverse-streaming `JSONLReversePageSource` / backfill pipeline
   then reads the **cached** file unchanged — no change to the reader, only to
   *where the bytes come from*.

This keeps the sidebar and the transcript renderer fully reused; only the source
of the JSONL bytes is swapped behind `remoteHostId`.

### 3i. Credentials / login state (aligned with Claude.app — §9)

The egress tunnel is **network only** (`ConnectProxy` blind-forwards `CONNECT`,
TLS stays end-to-end — §2b), so it can never inject auth. The remote `claude`
must hold a credential itself. Reverse-engineering the official Claude desktop
app (§9) settles how to provide it, and `managed` mode aligns with it exactly:

- **The Mac owns the credential and pushes a short-lived one as env.** Whatever
  the Mac is already authed with — an API key, or a claude.ai **subscription
  (OAuth)** — CCTerm resolves it to the launch-time env the CLI understands:
  `ANTHROPIC_API_KEY` (x-api-key) or `ANTHROPIC_AUTH_TOKEN` / `CLAUDE_CODE_OAUTH_TOKEN`
  (bearer), plus `ANTHROPIC_CUSTOM_HEADERS` and the cloud-provider vars
  (`CLAUDE_CODE_USE_BEDROCK` / `…_VERTEX`, etc.) where relevant.
- **Refresh happens on the Mac; the refresh token never leaves it.** For OAuth,
  CCTerm refreshes the access token locally (it expires) and forwards only the
  resulting **short-lived bearer** per launch. This is exactly Claude.app's
  behavior — it strips `claudeAiOauth.refreshToken` before any handoff and
  re-mints a fresh access token from the Keychain-stored credential each spawn.
  It solves the OAuth-expiry problem that a naive token copy would hit.
- **Env, not a file.** The token rides as process env at launch (embedded in the
  remote command / forwarded through the launch), not written to the remote disk.
  Prefer keeping it off `argv` (visible in `ps`); env is readable only to the
  same user / root via `/proc/<pid>/environ`. (Claude.app makes the same
  trade-off and deliberately does **not** copy its staged `.credentials.json` to
  the remote — that staged dir is its local-transport path only.)
- **Auth ⟂ egress.** The bearer/key handles *who you are*; the `ssh -R` tunnel
  handles *how the packets get out*. They are independent: a no-internet remote
  needs both (token + tunnel); a remote with its own internet needs only the
  token (and could skip the tunnel).
- **`useRemote` forwards nothing** (decision #3): the user's remote `claude` uses
  its own login state; CCTerm injects no credential. The user guarantees auth.

This lives in `SSHLaunchBuilder` (resolve + inject for `managed`) fed by the same
credential store the local app already uses; a `RemoteCredentialResolver` owns
the OAuth-refresh-on-Mac step. **Divergence from Claude.app:** it assumes the
remote reaches the API directly and runs **no tunnel**; our target remotes are
locked-down, so we keep the `ssh -R` egress (§2c/§2d). We adopt its *auth* model
and keep our *egress* model.

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

- ssh fields: alias, host, user, port, identity file, remote workdir base.
- **Claude on the remote** — radio (the §3g policy):
  - *Let CCTerm manage it* (`managed`) — installs CCTerm's pinned `claude` and
    forwards the Mac's credential into the launch (§3i). No remote setup needed.
  - *Use the remote's own* (`useRemote`) — a `claude` path (or auto-probe); CCTerm
    downloads nothing and **forwards no credential** — the remote's own login
    state is used, guaranteed by the user.
- **Test Connection** — drives `RemoteHostProbe`, shows the green/red result
  from the §2 checks (reachable? `claude` present/compatible? egress via tunnel
  works? — for `managed`, credential resolvable?).
- **Proxy config** — radio:
  - *Use an existing local HTTP proxy* — host:port (zero extra process; `ssh -R`
    targets it directly).
  - *Let CCTerm run one* — starts the native Swift CONNECT proxy.
- Save → `RemoteHostStore.add`.

The Mac-side proxy for the "CCTerm runs one" mode is implemented natively in
Swift as `RemoteEgress.ConnectProxy` (`Network.framework`
`NWListener`/`NWConnection`, loopback-only, `onLog` hook for the app to wire to
`appLog`) — **not** the Python stand-in used for the §2 verification. Already
landed and verified in both modes (§2c).

### 4a. Host switcher — a horizontal capsule strip in the Projects column

The project list is **host-scoped** (resolves the earlier "A vs B" decision in
favor of A). The switcher is a **horizontally-scrolling capsule strip** inserted
in the left column **below the "Projects" header, above the recents list**
(`NewSessionConfigurator.swift` `projectsColumn`, between `projectsHeader` and
`recentsList`):

```
┌ Projects ─────────────────────  + ▾ ┐
│ ( Local ) ( devbox ) ( build-01 ) …  │   ← horizontal scroll, tap a capsule to switch
│ ───────────────────────────────────  │
│  my-app           ~/src/my-app        │   ← recents, now scoped to the active host
│  api              ~/src/api           │
└───────────────────────────────────────┘
```

Tapping a capsule switches the active host context: the recents list, the
folder picker, and the "Recent Sessions" section all operate in that host's
namespace. `Local` is always the first capsule. The `+` menu (§4) still adds a
local folder or a new SSH host.

### 4b. Clicking a remote session

A "Recent Sessions" / sidebar row for a session whose record carries a
`remoteHostId` triggers the §3h fetch on click — the remote `.jsonl` is pulled to
the local cache and the normal backfill renders it. A subtle "from <host>"
affordance distinguishes remote rows.

---

## 5. Resolved decisions

1. **Host-scoped project list (was A vs B) → A, with a specific style.** The left
   column is host-scoped via a **horizontal capsule strip** placed below the
   "Projects" header, above the recents list (§4a). `Local` is the first capsule.
2. **Remote session history is in v1.** Clicking a remote session pulls its
   `.jsonl` from the remote on demand and renders it through the existing
   backfill pipeline (§3h). `SessionRecord` gains `remoteHostId` +
   `remoteTranscriptPath` (§3c).
3. **Provisioning is a per-host policy: `managed` or `useRemote` (§3g).**
   `managed` installs CCTerm's **pinned** `claude` to a controlled path,
   idempotently, during the SSH-only `.provisioning` status — and **owns the
   login state**, forwarding the Mac's refreshed credential into the launch
   (§3i), aligned with Claude.app (§9). `useRemote` trusts the remote's own
   `claude` (no download) and **does not manage login state** — the user
   guarantees a compatible binary and working auth on the remote.

---

## 6. Milestones

Each is independently testable; early ones land behind a smoke target, reusing
the `InterruptSmoke` / `*Smoke` convention in `macos/AgentSDK/Sources/`.

| # | Milestone | Deliverable / verification |
|---|---|---|
| **M0** | Feasibility | ✅ done — clean transport + reverse-egress tunnel, verified on a real remote (§2) |
| **M1** | SDK `LaunchPlan` (argv-based) | ✅ done — `SessionConfiguration.launchPlan` (`.local` / `.wrapped`) + `claudeArguments()` shipped; legacy `customCommand`/`binaryPath` path preserved. `RemoteSmoke` launches the real remote `claude` over `ssh -T`, runs one turn, and verifies protocol + lifecycle + no orphan with API egress **forced** through the Mac's `1081` proxy, proven by a tunnel on/off differential (decisive even when the remote can reach the API on its own) — §2d. |
| **M2** | `RemoteEgressService` (proxy) | 🟡 proxy primitive + both egress modes done. Native Swift CONNECT proxy shipped as `RemoteEgress.ConnectProxy` (loopback-only); `RemoteEgressSmoke` verifies a no-internet remote borrows the Mac's egress through `ssh -R` in **both** modes — reusing an existing local proxy *and* CCTerm's own `ConnectProxy` (§2c). Wiring `ssh -R` into the session argv + the app-scope `RemoteEgressService` lifecycle lands with M4. |
| **M3** | `RemoteProvisioner` + `.provisioning` status | install CCTerm's pinned `claude` to a controlled remote path, idempotent; new SSH-only runtime status (§3g); `RemoteSmoke` proves a fresh remote self-provisions then runs a turn |
| **M4** | `RemoteHost` model/store + `SSHLaunchBuilder` + `RemoteHostProbe` | + ControlMaster pool; `SessionConfig.remoteHostId` end-to-end: create a host-bound session, send a message, bash/files run remote |
| **M5** | Remote session history | `RemoteTranscriptFetcher` + `remoteTranscriptPath` field; clicking a remote session fetches its `.jsonl` and renders via the existing backfill (§3h) |
| **M6** | UI | `+` → `Menu` (add local / remote ▸ hosts / add SSH host); add-host sheet with Test Connection + proxy config; host-scoped capsule switcher (§4a); remote-session click affordance (§4b) |
| **M7** | Lifecycle hardening | reconnect on sleep/wake/network change; orphan reaping; surfaced errors |
| **M8** | Remote path semantics | remote folder picker (browse remote fs); per-host recents; replace local-only path UI (Finder reveal, `--add-dir`, permission-prompt paths) |

**M1–M6 = v1** (bash + files run remote, self-provisioned remote `claude`, remote
history, full host UI). **M7/M8 = v2** (resilience + remote-path polish).

---

## 7. Non-goals (v1)

- Surviving network drops / laptop sleep with the remote session intact (M7).
- Remote-path-aware "Reveal in Finder", `--add-dir`, permission-prompt path UI (M8).
- Browsing the remote filesystem in the folder picker — v1 takes a typed/remembered
  remote workdir; the live remote browser is M8.
- Running the claude.ai OAuth **browser flow on the headless remote** — we never
  do this. The Mac authenticates (API key or claude.ai subscription) and forwards
  a short-lived credential as launch env (§3i), refreshing on the Mac. Subscription
  (OAuth) is therefore *in scope* for v1 via forwarding — what is out of scope is
  doing the interactive login on the remote itself.

---

## 8. Risks

- **Login-shell PATH vs clean stdout.** Finding the remote `claude` wants a login
  shell, but a login shell may print a banner that corrupts the JSON stream.
  Resolution: pin the remote `claude` path (configured per host) and `exec` it
  directly; never route the protocol through an interactive shell.
- **Node proxy env coverage.** Claude runs on Node; confirm it honors
  `HTTPS_PROXY` for all API calls. Fallback: `ANTHROPIC_BASE_URL` → the tunnel +
  a remote `/etc/hosts` alias.
- **Protocol version skew** — *mitigated in `managed`, accepted in `useRemote`.*
  In `managed` mode CCTerm provisions its **own** pinned `claude` to a controlled
  path (§3g), so the remote protocol version is one we choose; provisioning
  verifies the stamped version and re-installs on mismatch. In `useRemote` the
  user opts into whatever the box has — we run a soft `--version` check and warn,
  but do not block; protocol compatibility is the user's responsibility.
- **Provisioning on a no-internet remote (chicken-and-egg).** Installing `claude`
  needs egress, but the egress tunnel is part of the session launch. Resolution:
  bring up the `-R` tunnel first, install through it; fallback is uploading a
  prebuilt binary over the existing SSH/SFTP channel.
- **sshd `MaxSessions`.** Default 10 multiplexed channels per connection caps
  per-host concurrency; document and surface, raise on the remote if needed.

---

## 9. Prior art — how the official Claude desktop app does remote (reverse-engineered)

`/Applications/Claude.app` (`com.anthropic.claudefordesktop`, an Electron app)
already does SSH-remote sessions on a **claude.ai subscription**, so its handling
is a useful reference. Reverse-engineering the main bundle (`app.asar` →
`.vite/build/index.js`) shows:

- **Transport — an RPC daemon, not a pipe.** It does *not* run `ssh host "claude
  …"`. Using the vendored `ssh2` library it **SFTP-deploys a pinned
  `claude-ssh`/`ccd-cli` daemon** to `~/.claude/remote/srv/<ver>/server`, starts
  it `server --serve --socket <run/<id>/rpc.sock> --token-file <tok>`, opens an
  `ssh exec` `--bridge` channel, and drives everything over newline-delimited
  **JSON-RPC** (`process.spawn` / `process.stdin` / `files.*` / `git.*`). The
  daemon spawns the remote `claude`.
- **Auth — refreshed-on-Mac bearer, forwarded as env.** The credential is read
  from the macOS **Keychain** (`security find-generic-password`), the OAuth access
  token is **refreshed locally** (`POST /v1/oauth/token`, `grant_type=refresh_token`,
  PKCE S256) before use, and the **short-lived bearer** is forwarded into the
  remote spawn as env (`ANTHROPIC_AUTH_TOKEN` / `CLAUDE_CODE_OAUTH_TOKEN` /
  `ANTHROPIC_API_KEY`, via a per-provider `sessionEnvVars()`). Its env forwarder
  passes `CLAUDE_*`/`ANTHROPIC_*` but **explicitly excludes `CLAUDE_CONFIG_DIR`**
  and never SFTPs its staged `.credentials.json` to the remote (that staged dir
  is its *local* transport path); the **refresh token never leaves the Mac**.
- **Egress — direct from the remote, no tunnel.** The SSH channel carries only
  RPC; the remote `claude` reaches `api.anthropic.com` **directly** over the
  remote's own network. Its `vmAllowedDomains` / `vmEgressPolicy` allowlist is for
  the Cowork **micro-VM sandbox**, not SSH remotes.
- **Provisioning — always `managed`.** It deploys its own pinned daemon **and**
  CLI (remote `--cli-url` fetch of `claude.zst`, SFTP fallback), version-checked.
  It has **no `useRemote` mode** — its transport *requires* the bespoke daemon.

**What we take, what we differ on.** We adopt its **auth** model verbatim
(Mac-refresh + forward a short-lived bearer as env; refresh token stays local —
§3i) and its **`managed` provisioning** spirit (§3g). We differ in two ways, both
deliberate: (1) our transport is the **vanilla stream-json protocol over `ssh
-T`**, not a custom RPC daemon — simpler, and it is exactly what makes a
**`useRemote`** mode possible (any protocol-compatible `claude` works); (2) our
target remotes are **locked-down**, so we keep the **`ssh -R` egress tunnel**
(§2c/§2d) that Claude.app does not need. Net: **same auth, our egress, plus a
no-install `useRemote` option they can't offer.**

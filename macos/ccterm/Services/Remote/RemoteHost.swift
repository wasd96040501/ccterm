import Foundation

/// A remote machine a session can run its `claude` on, over `ssh`.
///
/// The app-layer mirror of `SessionConfig` for the *where does this run* axis:
/// a `SessionConfig.remoteHostId` points at one of these (nil = local). The
/// `RemoteHostStore` persists the list; `SSHLaunchBuilder` turns one of these
/// (plus an egress decision + the session's claude argv) into an
/// `AgentSDK.LaunchPlan.wrapped` (design `remote-execution.md` §3b/§3c/§3e).
///
/// The SDK never sees this type — it only learns what "ssh" is through the
/// fully-built argv. Everything ssh/proxy-specific stays in the app layer.
struct RemoteHost: Codable, Identifiable, Hashable, Sendable {

    /// Stable identity stored on a session as `remoteHostId`. A UUID string so
    /// renaming the alias or editing connection details never re-keys sessions.
    var id: String

    /// User-facing display name (capsule label, sheet title). Defaults to
    /// `host` when the user doesn't type one.
    var alias: String

    /// The ssh target — an `~/.ssh/config` alias (e.g. `devbox`) or a hostname.
    /// This is the literal `<host>` in `ssh <host>`; `user` / `port` /
    /// `identityFile` below are optional overrides layered on top, so a fully
    /// `~/.ssh/config`-driven host needs only this.
    var host: String

    /// Explicit login user (`-l` / `user@host`). nil → ssh config / current user.
    var user: String?

    /// Explicit port (`-p`). nil → ssh config / 22.
    var port: Int?

    /// Explicit identity file (`-i`). nil → ssh config / agent.
    var identityFile: String?

    /// Base working directory for sessions on this host. A session's remote cwd
    /// is derived from this; nil falls back to a per-session scratch dir.
    var remoteWorkdir: String?

    /// How `claude` is obtained on the remote (§3g).
    var claudePolicy: RemoteClaudePolicy

    /// How the remote reaches the Anthropic API (§3e/§2c).
    var proxy: RemoteProxyMode

    init(
        id: String = UUID().uuidString,
        alias: String,
        host: String,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        remoteWorkdir: String? = nil,
        claudePolicy: RemoteClaudePolicy = .managed,
        proxy: RemoteProxyMode = .useExisting(hostPort: nil)
    ) {
        self.id = id
        self.alias = alias
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.remoteWorkdir = remoteWorkdir
        self.claudePolicy = claudePolicy
        self.proxy = proxy
    }

    /// Display name, never empty — falls back to the ssh target.
    var displayName: String { alias.isEmpty ? host : alias }
}

/// Per-host policy for the remote `claude` binary + its login state (§3g).
enum RemoteClaudePolicy: Codable, Hashable, Sendable {
    /// CCTerm installs + pins its own `claude` to a controlled path
    /// (`~/.ccterm/bin/claude`) and owns the login state (forwards the Mac's
    /// refreshed credential into the launch, §3i). Mirrors Claude.app (§9).
    case managed

    /// Trust the `claude` already on the remote — a pinned absolute path, or
    /// nil to login-shell-probe it. CCTerm downloads nothing, writes nothing,
    /// and forwards **no** credential; the remote's own auth is used. The user
    /// guarantees a protocol-compatible binary + working auth.
    case useRemote(path: String?)
}

/// How a remote session's API egress is routed (§3e). v1 wires only
/// `.useExisting` (the smoke-proven mode A): each session's own `ssh -R` points
/// at an HTTP proxy already running on the Mac.
enum RemoteProxyMode: Codable, Hashable, Sendable {
    /// Reuse an HTTP proxy already running on the Mac. `hostPort` (e.g.
    /// `127.0.0.1:1081`) nil → resolve from the Claude-configured proxy
    /// (`HTTPS_PROXY` → `~/.claude/settings.json`), else default `127.0.0.1:1081`.
    case useExisting(hostPort: String?)

    /// CCTerm runs its own native CONNECT proxy (`RemoteEgress.ConnectProxy`).
    /// Defined for forward-compat; wiring lands in a later milestone.
    case ccTermRunsOne
}

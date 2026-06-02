import AgentSDK
import Foundation

/// Turns a `RemoteHost` + the session's resolved launch inputs into the
/// `AgentSDK.LaunchPlan.wrapped` that runs the real `claude` on the remote over
/// `ssh -T` (design `remote-execution.md` §3a/§3e). **Pure** — no I/O, no
/// `UserDefaults`, no store access; every input is resolved upstream (the host
/// from `RemoteHostStore`, the credential env from `RemoteCredentialResolver`,
/// the binary path from `RemoteProvisioner`, the egress decision from
/// `RemoteEgressService`). That keeps it trivially unit-testable: assert on the
/// produced argv.
///
/// This is the app-layer owner of the **remote shell quoting** the SDK
/// deliberately does not do: `.wrapped`'s argv is handed to `Process` untokenized,
/// but the *remote command* is a single shell string, so `claude`'s flags and the
/// env assignments are POSIX-single-quoted here. The shape mirrors `RemoteSmoke`'s
/// `buildSSHArgv` byte-for-byte (the real-ssh integration check), pinned by
/// `SSHLaunchBuilderTests`.
nonisolated struct SSHLaunchBuilder {

    /// System ssh. `.wrapped` runs this verbatim with the argv below.
    static let sshExecutable = "/usr/bin/ssh"

    /// Everything needed to build one remote session's launch. All resolved.
    struct Inputs {
        /// The host to run on (connection details + policy).
        var host: RemoteHost
        /// Stable session id — rides in `--session-id`/`--resume` inside
        /// `claudeArguments`, not added here.
        var sessionId: String
        /// Absolute remote working directory the session runs in.
        var remoteWorkdir: String
        /// Resolved remote `claude` path (managed install path, pinned, or probed).
        var remoteClaudePath: String
        /// The claude argv (`SessionConfiguration.claudeArguments()`), embedded
        /// verbatim into the remote command. Byte-for-byte what would run locally.
        var claudeArguments: [String]
        /// Launch-time credential env (`managed` → the §3i bearer/key; `useRemote`
        /// → empty, the remote uses its own auth). Never logged by this type.
        var credentialEnv: [String: String]
        /// Per-session reverse-tunnel egress, or nil to use the remote's own
        /// network (no `-R`, no proxy env).
        var egress: Egress?
    }

    /// Per-session reverse-tunnel egress (§3e). Opens `remoteForwardPort` on the
    /// remote loopback over `ssh -R`, forwarding to the **host-scoped shared Mac
    /// proxy** at `macProxyHostPort`; the remote `claude` is pointed at the
    /// forwarded port via `HTTPS_PROXY`. The tunnel lives and dies with this one
    /// session's ssh (no sharing in v1).
    struct Egress {
        var remoteForwardPort: Int
        var macProxyHostPort: String  // e.g. "127.0.0.1:1081"
    }

    func makeLaunchPlan(_ inputs: Inputs) -> LaunchPlan {
        var argv = Self.baseOptions
        argv += Self.connectionOptions(for: inputs.host)
        if let egress = inputs.egress {
            argv += ["-R", "127.0.0.1:\(egress.remoteForwardPort):\(egress.macProxyHostPort)"]
        }
        argv.append(Self.sshTarget(for: inputs.host))
        argv.append(remoteCommand(inputs))
        return .wrapped(executable: Self.sshExecutable, argv: argv)
    }

    // MARK: - ssh options

    /// `-T` (no PTY → 8-bit-clean for stream-json), batch (never prompt — launch
    /// is non-interactive, key-based), and keepalives so a dead network is
    /// detected rather than hanging forever. Mirrors `RemoteSmoke.sshBaseOpts`.
    static let baseOptions: [String] = [
        "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20",
        "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
    ]

    /// Per-host connection overrides layered on top of `~/.ssh/config`. A host
    /// fully described by an ssh config alias needs none of these.
    static func connectionOptions(for host: RemoteHost) -> [String] {
        var opts: [String] = []
        if let port = host.port { opts += ["-p", String(port)] }
        if let identity = host.identityFile, !identity.isEmpty { opts += ["-i", identity] }
        if let user = host.user, !user.isEmpty { opts += ["-l", user] }
        return opts
    }

    /// The ssh target token. Just the host — `user` is applied via `-l` above so
    /// the token stays a clean alias for `~/.ssh/config` `Host` matching.
    static func sshTarget(for host: RemoteHost) -> String { host.host }

    // MARK: - remote command

    /// The single shell string handed to ssh: cd into the workdir, then `exec
    /// env <assignments> <claude> <args>`. `exec` so EOF/signals propagate to the
    /// real `claude` (no intervening shell — §3f lifecycle).
    private func remoteCommand(_ inputs: Inputs) -> String {
        let envAssignments = environmentAssignments(inputs).joined(separator: " ")
        let quotedArgs = inputs.claudeArguments.map(Self.posixQuote).joined(separator: " ")
        let wd = Self.posixQuote(inputs.remoteWorkdir)
        let claude = Self.posixQuote(inputs.remoteClaudePath)
        return
            "mkdir -p \(wd) >/dev/null 2>&1; cd \(wd) || exit 97; "
            + "exec env \(envAssignments) \(claude) \(quotedArgs)"
    }

    /// `KEY='value'` assignments for the remote `env`: the proxy vars that force
    /// egress through the tunnel (when present), then the credential env. Sorted
    /// for deterministic argv (testability); the shell does not care about order.
    private func environmentAssignments(_ inputs: Inputs) -> [String] {
        var assignments: [String] = []
        if let egress = inputs.egress {
            let proxyURL = "http://127.0.0.1:\(egress.remoteForwardPort)"
            // Both cases of each var — Node honors the upper-case forms; lower-case
            // covers tools that only read those. NO_PROXY is deliberately NOT set:
            // the remote must route all egress through the tunnel.
            for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] {
                assignments.append("\(key)=\(Self.posixQuote(proxyURL))")
            }
        }
        for key in inputs.credentialEnv.keys.sorted() {
            assignments.append("\(key)=\(Self.posixQuote(inputs.credentialEnv[key]!))")
        }
        return assignments
    }

    /// POSIX single-quote a string for safe embedding in a remote shell command.
    /// `'` → `'\''`. Mirrors `RemoteSmoke.shq`.
    static func posixQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

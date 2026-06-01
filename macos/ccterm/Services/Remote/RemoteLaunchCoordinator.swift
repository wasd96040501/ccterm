import AgentSDK
import Foundation

/// Ties the remote-launch pieces together for one session's `.provisioning`
/// step (design `remote-execution.md` §3g): look up the host, ensure the remote
/// `claude` (`managed`) or probe it (`useRemote`), resolve the credential env,
/// decide egress, and hand the assembled argv to `SSHLaunchBuilder`. App-scope,
/// injected into `SessionManager` → `SessionRuntime`. Pure orchestration on top
/// of the app-layer primitives — no AgentSDK contamination.
///
/// The blocking work (provision download/upload, credential refresh, ssh probes)
/// runs off the main actor; only `Sendable` primitives cross back, and the
/// `LaunchPlan` is reassembled on the main actor.
@MainActor
final class RemoteLaunchCoordinator {

    private let hosts: RemoteHostStore

    init(hosts: RemoteHostStore) {
        self.hosts = hosts
    }

    /// The resolved launch for a remote session.
    struct Resolved {
        /// The ssh `LaunchPlan` to hand the SDK.
        var launchPlan: LaunchPlan
        /// Local scratch dir for the SDK's local `Process` cwd — the *remote* cwd
        /// lives inside the ssh command, so the local one is irrelevant but must
        /// exist.
        var localWorkingDirectory: URL
    }

    /// Outcome of `resolveLaunch`. A custom enum rather than `Result` because the
    /// failure payload is a human-readable reason (a `String`), not an `Error`.
    enum Outcome {
        case resolved(Resolved)
        case failed(String)
    }

    /// Resolve the ssh `LaunchPlan` for the session bound to `hostId`. Returns a
    /// `.failed(reason)` (surfaced to the launch-failure path) when the host is
    /// unknown or provisioning / credential resolution fails.
    func resolveLaunch(
        hostId: String, sessionId: String, claudeArguments: [String]
    ) async -> Outcome {
        guard let host = hosts.host(id: hostId) else {
            return .failed("remote host \(hostId) is not configured")
        }
        let raw = await Task.detached(priority: .userInitiated) {
            Self.resolveBlocking(host: host, sessionId: sessionId, claudeArguments: claudeArguments)
        }.value
        switch raw {
        case .failed(let reason):
            return .failed(reason)
        case .resolved(let r):
            let dir = URL(fileURLWithPath: r.localWorkdir, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return .resolved(
                Resolved(launchPlan: .wrapped(executable: r.executable, argv: r.argv), localWorkingDirectory: dir))
        }
    }

    // MARK: - Off-main resolution

    /// `Sendable` carrier so only primitives cross the actor boundary (the
    /// `LaunchPlan` is rebuilt on the main actor).
    private struct RawLaunch: Sendable {
        var executable: String
        var argv: [String]
        var localWorkdir: String
    }

    private enum RawOutcome: Sendable {
        case resolved(RawLaunch)
        case failed(String)
    }

    nonisolated private static func resolveBlocking(
        host: RemoteHost, sessionId: String, claudeArguments: [String]
    ) -> RawOutcome {
        // Egress: v1 only wires the "reuse an existing Mac proxy" mode (§3e). The
        // remote is assumed locked-down, so a turn always tunnels through the Mac.
        let egress: SSHLaunchBuilder.Egress
        switch host.proxy {
        case .useExisting(let hostPort):
            let resolved =
                hostPort
                ?? RemoteCredentialResolver.proxyHostPort(RemoteCredentialResolver.resolveClaudeProxy().https)
                ?? "127.0.0.1:1081"
            egress = SSHLaunchBuilder.Egress(
                remoteForwardPort: Self.forwardPort(for: sessionId), macProxyHostPort: resolved)
        case .ccTermRunsOne:
            return .failed("CCTerm-run proxy is not wired yet — configure the host to reuse an existing local proxy")
        }

        // Remote `claude` + credential env, per policy.
        let claudePath: String
        var credentialEnv: [String: String] = [:]
        switch host.claudePolicy {
        case .managed:
            let proxy = RemoteCredentialResolver.resolveClaudeProxy()
            guard let path = RemoteProvisioner().ensureInstalled(host: host, proxy: proxy) else {
                return .failed("could not provision the managed claude on \(host.host)")
            }
            claudePath = path
            guard let env = RemoteCredentialResolver().resolveLaunchEnv() else {
                return .failed("could not resolve a credential to forward to \(host.host)")
            }
            credentialEnv = env
        case .useRemote(let pinned):
            guard let path = Self.resolveUseRemotePath(host: host, pinned: pinned) else {
                return .failed("could not find a remote claude on \(host.host) (set an explicit path)")
            }
            claudePath = path
        // `useRemote` forwards NO credential — the remote uses its own auth.
        }

        let remoteWorkdir = host.remoteWorkdir ?? "/tmp/ccterm-remote-\(sessionId)"
        let inputs = SSHLaunchBuilder.Inputs(
            host: host, sessionId: sessionId, remoteWorkdir: remoteWorkdir, remoteClaudePath: claudePath,
            claudeArguments: claudeArguments, credentialEnv: credentialEnv, egress: egress)
        let plan = SSHLaunchBuilder().makeLaunchPlan(inputs)
        guard case .wrapped(let exe, let argv) = plan else {
            return .failed("internal: SSHLaunchBuilder did not produce a wrapped plan")
        }
        let localWorkdir = NSTemporaryDirectory() + "ccterm-remote-local-\(sessionId.prefix(8))"
        return .resolved(RawLaunch(executable: exe, argv: argv, localWorkdir: localWorkdir))
    }

    /// `useRemote`: a pinned absolute path wins; otherwise login-shell-probe
    /// `command -v claude` on the remote.
    nonisolated private static func resolveUseRemotePath(host: RemoteHost, pinned: String?) -> String? {
        if let pinned, !pinned.isEmpty { return pinned }
        let probe =
            SSHLaunchBuilder.baseOptions + SSHLaunchBuilder.connectionOptions(for: host)
            + [SSHLaunchBuilder.sshTarget(for: host), "$SHELL -lc 'command -v claude' 2>/dev/null || true"]
        let r = RemoteProcess.run("/usr/bin/ssh", probe, timeout: 25)
        let line = r.out.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("/") })
        return line
    }

    /// A per-session remote loopback port for the `-R` tunnel, in 18000..<19000.
    /// Stable djb2 over the session id (not `String.hashValue`, which is
    /// per-process randomized) so it is reproducible within a launch; concurrent
    /// sessions to one host land on different ports with high probability.
    nonisolated static func forwardPort(for sessionId: String) -> Int {
        var hash: UInt64 = 5381
        for byte in sessionId.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return 18000 + Int(hash % 1000)
    }
}

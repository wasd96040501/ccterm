import Foundation

/// Connectivity validation for the Add-SSH-Host sheet's "Test Connection" button
/// (design `remote-execution.md` §4, M6). Runs the §2-style checks in Swift, off
/// the main actor, by reusing the same building blocks the real launch uses —
/// `SSHLaunchBuilder` for the ssh argv, `RemoteProcess` to run it, and
/// `RemoteCredentialResolver` for the `managed` credential check — so a green
/// result means the same path the session launch takes is healthy.
///
/// Deliberately *not* run here: bringing up the `-R` egress tunnel and curling
/// through it. Reachability already proves the SSH carrier; the tunnel is a launch
/// concern, too heavy for a tap-to-test button.
nonisolated struct RemoteHostProbe {

    enum Status: Sendable {
        case ok
        case warn
        case fail
    }

    /// One staged check, rendered as a row in the sheet (icon + label + detail).
    struct Check: Identifiable, Sendable {
        var id: String { label }
        var label: String
        var status: Status
        var detail: String
    }

    /// Run the checks for `host`. Blocking ssh work happens on a detached task;
    /// only `Sendable` `Check` values cross back to the caller.
    func run(_ host: RemoteHost) async -> [Check] {
        await Task.detached(priority: .userInitiated) {
            Self.runBlocking(host)
        }.value
    }

    // MARK: - Off-main

    nonisolated private static func runBlocking(_ host: RemoteHost) -> [Check] {
        var checks: [Check] = []

        // 1. Reachable — a no-op `true` over ssh. Stops here on failure; the rest
        //    of the checks need a working connection.
        let connectArgs =
            SSHLaunchBuilder.baseOptions + SSHLaunchBuilder.connectionOptions(for: host)
            + [SSHLaunchBuilder.sshTarget(for: host), "true"]
        let reach = RemoteProcess.run(Self.ssh, connectArgs, timeout: 25)
        guard reach.code == 0 else {
            checks.append(
                Check(
                    label: String(localized: "Reachable"), status: .fail,
                    detail: firstError(reach.err) ?? String(localized: "SSH connection failed")))
            return checks
        }
        checks.append(
            Check(
                label: String(localized: "Reachable"), status: .ok,
                detail: String(localized: "SSH connection succeeded")))

        // 2. Claude — managed installs its own on first launch; useRemote must
        //    already have a protocol-compatible binary.
        switch host.claudePolicy {
        case .managed:
            checks.append(
                Check(
                    label: String(localized: "Claude"), status: .ok,
                    detail: String(localized: "CCTerm will install its own claude on first launch")))
        case .useRemote(let pinned):
            if let path = resolveUseRemotePath(host: host, pinned: pinned) {
                checks.append(Check(label: String(localized: "Claude"), status: .ok, detail: path))
            } else {
                checks.append(
                    Check(
                        label: String(localized: "Claude"), status: .fail,
                        detail: String(localized: "No claude found on the remote — set an explicit path.")))
            }
        }

        // 3. Credential — managed forwards the Mac's credential, so it must be
        //    resolvable here. useRemote uses the remote's own auth (nothing to check).
        if case .managed = host.claudePolicy {
            if RemoteCredentialResolver().resolveLaunchEnv() != nil {
                checks.append(
                    Check(
                        label: String(localized: "Credential"), status: .ok,
                        detail: String(localized: "A credential is available to forward.")))
            } else {
                checks.append(
                    Check(
                        label: String(localized: "Credential"), status: .fail,
                        detail: String(localized: "No API key or claude.ai login found on this Mac.")))
            }
        }

        return checks
    }

    /// `useRemote`: a pinned absolute path wins; otherwise login-shell-probe
    /// `command -v claude`. Mirrors `RemoteLaunchCoordinator.resolveUseRemotePath`.
    nonisolated private static func resolveUseRemotePath(host: RemoteHost, pinned: String?) -> String? {
        if let pinned, !pinned.isEmpty { return pinned }
        let probe =
            SSHLaunchBuilder.baseOptions + SSHLaunchBuilder.connectionOptions(for: host)
            + [SSHLaunchBuilder.sshTarget(for: host), "$SHELL -lc 'command -v claude' 2>/dev/null || true"]
        let r = RemoteProcess.run(Self.ssh, probe, timeout: 25)
        return r.out.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("/") })
    }

    /// Last non-empty stderr line, trimmed + capped, for a human-readable failure.
    nonisolated private static func firstError(_ stderr: String) -> String? {
        let line = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
        guard let line, !line.isEmpty else { return nil }
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }

    private static let ssh = SSHLaunchBuilder.sshExecutable
}

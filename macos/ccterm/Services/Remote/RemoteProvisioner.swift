import Foundation

/// `managed`-policy provisioning of CCTerm's own pinned `claude` onto a remote
/// (design `remote-execution.md` §3g + §9 SFTP fallback). The Mac downloads the
/// checksum-verified `linux-x64` binary through its own proxy egress and uploads
/// it to a controlled path (`~/.ccterm/bin/claude`) over `ssh` stdin. The remote
/// runs no installer, mutates no profile, needs no node. Idempotent via a version
/// stamp. App-layer port of `RemoteSmoke`'s `Provisioner` (remote logic is
/// app-owned, no shared target).
///
/// Blocking (curl/ssh/shasum) — call off the main actor.
nonisolated struct RemoteProvisioner {

    private static let releaseBaseURL = "https://downloads.claude.ai/claude-code-releases"
    private static let managedRemoteDir = "~/.ccterm/bin"

    /// Ensure a CCTerm-managed `claude` exists on `host` and return its ABSOLUTE
    /// remote path (safe to single-quote into the launch). nil on failure.
    func ensureInstalled(host: RemoteHost, proxy: RemoteCredentialResolver.ClaudeProxy) -> String? {
        var curlBase = ["-fsS"]
        if let p = proxy.https { curlBase += ["-x", p] }

        // 1. Resolve the latest version (Mac side, through the proxy).
        let verR = RemoteProcess.run(
            "/usr/bin/curl", curlBase + ["--max-time", "30", "\(Self.releaseBaseURL)/latest"], timeout: 40)
        let ver = verR.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard verR.code == 0, ver.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil else {
            appLog(
                .error, "RemoteProvisioner",
                "could not resolve latest claude version (curl exit=\(verR.code), got '\(ver.prefix(40))')")
            return nil
        }

        // 2. Idempotent: stamp matches AND the binary still runs → skip the pull.
        let absPath = resolveRemoteAbsPath(host: host)
        let stampR = RemoteProcess.run(
            "/usr/bin/ssh", sshArgs(host, "cat \(Self.managedRemoteDir)/.claude-version 2>/dev/null || true"),
            timeout: 25)
        if stampR.out.trimmingCharacters(in: .whitespacesAndNewlines) == ver {
            let vr = RemoteProcess.run(
                "/usr/bin/ssh", sshArgs(host, "\(Self.managedRemoteDir)/claude --version 2>/dev/null || true"),
                timeout: 30)
            if vr.out.contains(ver) {
                appLog(.info, "RemoteProvisioner", "managed claude \(ver) already present on \(host.host) (skip)")
                return absPath
            }
        }

        appLog(
            .info, "RemoteProvisioner",
            "installing managed claude \(ver) → \(Self.managedRemoteDir)/claude on \(host.host) (download + upload)")

        // 3. Checksum for linux-x64 from the manifest.
        let manR = RemoteProcess.run(
            "/usr/bin/curl", curlBase + ["--max-time", "30", "\(Self.releaseBaseURL)/\(ver)/manifest.json"],
            timeout: 40)
        guard manR.code == 0,
            let md = manR.out.data(using: .utf8),
            let mo = try? JSONSerialization.jsonObject(with: md) as? [String: Any],
            let plats = mo["platforms"] as? [String: Any],
            let lx = plats["linux-x64"] as? [String: Any],
            let expectedSum = lx["checksum"] as? String, expectedSum.count == 64
        else {
            appLog(.error, "RemoteProvisioner", "could not read linux-x64 checksum from manifest")
            return nil
        }

        // 4. Download to a Mac temp file (~240MB), verify sha256.
        let tmp = NSTemporaryDirectory() + "ccterm-managed-claude-linux-x64-\(ver)"
        let dlR = RemoteProcess.run(
            "/usr/bin/curl",
            curlBase + ["--max-time", "500", "-o", tmp, "\(Self.releaseBaseURL)/\(ver)/linux-x64/claude"],
            timeout: 540)
        guard dlR.code == 0 else {
            appLog(.error, "RemoteProvisioner", "download failed (curl exit=\(dlR.code))")
            return nil
        }
        let sumR = RemoteProcess.run("/usr/bin/shasum", ["-a", "256", tmp], timeout: 60)
        let actualSum = sumR.out.split(separator: " ").first.map(String.init) ?? ""
        guard actualSum == expectedSum else {
            appLog(
                .error, "RemoteProvisioner",
                "checksum mismatch (expected \(expectedSum.prefix(12))…, got \(actualSum.prefix(12))…)")
            try? FileManager.default.removeItem(atPath: tmp)
            return nil
        }

        // 5. Upload over ssh (stdin stream), then chmod + stamp.
        let upCode = RemoteProcess.uploadFile(
            localPath: tmp,
            sshArgs: sshArgs(host, "mkdir -p \(Self.managedRemoteDir) && cat > \(Self.managedRemoteDir)/claude"),
            timeout: 300)
        try? FileManager.default.removeItem(atPath: tmp)
        guard upCode == 0 else {
            appLog(.error, "RemoteProvisioner", "upload failed (ssh exit=\(upCode))")
            return nil
        }
        let finR = RemoteProcess.run(
            "/usr/bin/ssh",
            sshArgs(
                host,
                "chmod +x \(Self.managedRemoteDir)/claude && echo \(ver) > \(Self.managedRemoteDir)/.claude-version"),
            timeout: 30)
        guard finR.code == 0 else {
            appLog(.error, "RemoteProvisioner", "chmod/stamp failed (ssh exit=\(finR.code))")
            return nil
        }

        // 6. Verify the uploaded binary actually runs.
        let vr = RemoteProcess.run(
            "/usr/bin/ssh", sshArgs(host, "\(Self.managedRemoteDir)/claude --version 2>/dev/null || true"),
            timeout: 30)
        guard vr.out.contains(ver) else {
            appLog(
                .error, "RemoteProvisioner",
                "uploaded binary did not report version \(ver) (got '\(vr.out.prefix(40))')")
            return nil
        }
        appLog(.info, "RemoteProvisioner", "managed claude \(ver) installed + verified on \(host.host)")
        return resolveRemoteAbsPath(host: host)
    }

    /// Resolve `~/.ccterm/bin/claude` to an absolute remote path (the launch
    /// single-quotes the path, so a literal `~` would not expand). Falls back to
    /// the `~`-form if the probe is inconclusive.
    private func resolveRemoteAbsPath(host: RemoteHost) -> String {
        let r = RemoteProcess.run("/usr/bin/ssh", sshArgs(host, "echo \(Self.managedRemoteDir)/claude"), timeout: 25)
        let line = r.out.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("/") })
        return line ?? "\(Self.managedRemoteDir)/claude"
    }

    /// ssh argv for a one-off control command on `host` — base opts + the host's
    /// connection overrides + target + command. Reuses `SSHLaunchBuilder` so the
    /// connection details match the session launch exactly.
    private func sshArgs(_ host: RemoteHost, _ command: String) -> [String] {
        SSHLaunchBuilder.baseOptions + SSHLaunchBuilder.connectionOptions(for: host)
            + [SSHLaunchBuilder.sshTarget(for: host), command]
    }
}

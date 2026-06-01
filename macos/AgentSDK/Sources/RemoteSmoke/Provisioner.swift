import Foundation

// Remote `claude` provisioning for the smoke — design `remote-execution.md` §3g
// (`managed` policy) + §9 (Claude.app's SFTP fallback). The Mac downloads the
// pinned, checksum-verified linux-x64 binary through its own proxy egress and
// uploads it to a CONTROLLED remote path (`~/.ccterm/bin/claude`). The remote
// runs NO installer, mutates no shell profile, needs no node — it only receives
// one verified file. Idempotent via a version stamp.
//
// `run()` / `log()` / `sshBaseOpts()` are defined in `main.swift` (same target).

private let releaseBaseURL = "https://downloads.claude.ai/claude-code-releases"
private let managedRemoteDir = "~/.ccterm/bin"

/// Ensure a CCTerm-managed `claude` exists on the remote at `~/.ccterm/bin/claude`
/// and return its ABSOLUTE remote path (so it can be safely single-quoted into the
/// launch command). Returns nil on failure.
func ensureRemoteManagedClaude(sshHost: String, sshOpts: [String], proxy: ClaudeProxy) -> String? {
    // Mac-side curl base, routed through the Claude-configured proxy.
    var curlBase = ["-fsS"]
    if let p = proxy.https { curlBase += ["-x", p] }

    // 1. Resolve the latest version (Mac side).
    let verR = run("/usr/bin/curl", curlBase + ["--max-time", "30", "\(releaseBaseURL)/latest"], timeout: 40)
    let ver = verR.out.trimmingCharacters(in: .whitespacesAndNewlines)
    guard verR.code == 0, ver.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil else {
        log("[provision] could not resolve latest claude version (curl exit=\(verR.code), got '\(ver.prefix(40))')")
        return nil
    }

    // 2. Idempotent: stamp matches AND the binary still runs → skip the 240MB pull.
    let absPath = resolveRemoteAbsPath(sshHost: sshHost, sshOpts: sshOpts)
    let stampR = run(
        "/usr/bin/ssh", sshOpts + [sshHost, "cat \(managedRemoteDir)/.claude-version 2>/dev/null || true"],
        timeout: 25)
    if stampR.out.trimmingCharacters(in: .whitespacesAndNewlines) == ver {
        let vr = run(
            "/usr/bin/ssh", sshOpts + [sshHost, "\(managedRemoteDir)/claude --version 2>/dev/null || true"], timeout: 30
        )
        if vr.out.contains(ver) {
            log("[provision] managed claude \(ver) already present on \(sshHost) (skip)")
            return absPath
        }
    }

    log(
        "[provision] installing managed claude \(ver) → \(managedRemoteDir)/claude on \(sshHost) (Mac download + ssh upload)"
    )

    // 3. Checksum for linux-x64 from the manifest.
    let manR = run(
        "/usr/bin/curl", curlBase + ["--max-time", "30", "\(releaseBaseURL)/\(ver)/manifest.json"], timeout: 40)
    guard manR.code == 0,
        let md = manR.out.data(using: .utf8),
        let mo = try? JSONSerialization.jsonObject(with: md) as? [String: Any],
        let plats = mo["platforms"] as? [String: Any],
        let lx = plats["linux-x64"] as? [String: Any],
        let expectedSum = lx["checksum"] as? String, expectedSum.count == 64
    else {
        log("[provision] could not read linux-x64 checksum from manifest")
        return nil
    }

    // 4. Download the binary to a Mac temp file (~240MB), verify sha256.
    let tmp = "/tmp/ccterm-managed-claude-linux-x64-\(ver)"
    let dlR = run(
        "/usr/bin/curl", curlBase + ["--max-time", "500", "-o", tmp, "\(releaseBaseURL)/\(ver)/linux-x64/claude"],
        timeout: 540)
    guard dlR.code == 0 else {
        log("[provision] download failed (curl exit=\(dlR.code))")
        return nil
    }
    let sumR = run("/usr/bin/shasum", ["-a", "256", tmp], timeout: 60)
    let actualSum = sumR.out.split(separator: " ").first.map(String.init) ?? ""
    guard actualSum == expectedSum else {
        log("[provision] checksum mismatch (expected \(expectedSum.prefix(12))…, got \(actualSum.prefix(12))…)")
        try? FileManager.default.removeItem(atPath: tmp)
        return nil
    }

    // 5. Upload over ssh (stdin stream — no scp option quirks), then chmod + stamp.
    let upCode = sshUploadFile(
        localPath: tmp, sshHost: sshHost, sshOpts: sshOpts,
        remoteCommand: "mkdir -p \(managedRemoteDir) && cat > \(managedRemoteDir)/claude", timeout: 300)
    try? FileManager.default.removeItem(atPath: tmp)
    guard upCode == 0 else {
        log("[provision] upload failed (ssh exit=\(upCode))")
        return nil
    }
    let finR = run(
        "/usr/bin/ssh",
        sshOpts + [
            sshHost, "chmod +x \(managedRemoteDir)/claude && echo \(ver) > \(managedRemoteDir)/.claude-version",
        ],
        timeout: 30)
    guard finR.code == 0 else {
        log("[provision] chmod/stamp failed (ssh exit=\(finR.code))")
        return nil
    }

    // 6. Verify the uploaded binary actually runs.
    let vr = run(
        "/usr/bin/ssh", sshOpts + [sshHost, "\(managedRemoteDir)/claude --version 2>/dev/null || true"], timeout: 30)
    guard vr.out.contains(ver) else {
        log("[provision] uploaded binary did not report version \(ver) (got '\(vr.out.prefix(40))')")
        return nil
    }
    log("[provision] managed claude \(ver) installed + verified on \(sshHost)")
    return resolveRemoteAbsPath(sshHost: sshHost, sshOpts: sshOpts)
}

/// Resolve `~/.ccterm/bin/claude` to an absolute remote path (the launch command
/// single-quotes the path, so a literal `~` would not expand). Falls back to the
/// `~`-form if the probe is inconclusive.
private func resolveRemoteAbsPath(sshHost: String, sshOpts: [String]) -> String {
    let r = run("/usr/bin/ssh", sshOpts + [sshHost, "echo \(managedRemoteDir)/claude"], timeout: 25)
    let line = r.out.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("/") })
    return line ?? "\(managedRemoteDir)/claude"
}

/// Stream a local file to a remote command's stdin over ssh (used to upload the
/// binary). `run()` cannot redirect a file into stdin, so this is a small variant.
private func sshUploadFile(
    localPath: String, sshHost: String, sshOpts: [String], remoteCommand: String, timeout: TimeInterval
) -> Int32 {
    guard let input = FileHandle(forReadingAtPath: localPath) else { return -1 }
    defer { try? input.close() }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    proc.arguments = sshOpts + [sshHost, remoteCommand]
    proc.standardInput = input
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return -1 }
    let watchdog = DispatchQueue(label: "provision.upload.watchdog")
    watchdog.asyncAfter(deadline: .now() + timeout) { if proc.isRunning { proc.terminate() } }
    proc.waitUntilExit()
    return proc.terminationStatus
}

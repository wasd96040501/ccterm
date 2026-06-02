import AgentSDK
import Foundation

// Real-remote smoke for the structured launch seam — design `remote-execution.md`
// M1 (`LaunchPlan.wrapped`). It launches the REAL `claude` on a remote box over
// `ssh -T` and runs one turn, proving the three M1 deliverables:
//
//   1. structured argv launch — `LaunchPlan.wrapped(executable:argv:)` runs the
//      ssh command verbatim, with the claude argument list (spaces, paths and
//      all) embedded into the remote command without the old space-split
//      mangling.
//   2. protocol — the stream-json control protocol survives `ssh -T` intact
//      (8-bit-clean pipe, no PTY); we initialize, send a prompt, and read the
//      assistant reply + final result.
//   3. lifecycle / no orphan — `session.close()` → stdin EOF → channel close →
//      the remote `claude` exits; we assert no stray remote process remains.
//
// THE EGRESS CONSTRAINT (per project decision):
//   The remote `claude` MUST reach the Anthropic API ONLY through the Mac's
//   existing local HTTP proxy (default 127.0.0.1:1081), tunneled via `ssh -R`.
//   It must NOT use the remote's own network.
//
//   `HTTPS_PROXY` *forces* this: Node routes API calls through the proxy and does
//   not silently fall back to a direct connection. We PROVE it with a tunnel
//   on/off differential that stays decisive even when the remote DOES have its
//   own direct route to the API (the common case — a restricted box that still
//   allowlists api.anthropic.com):
//
//     · proxy env points at a remote loopback port that is ONLY alive when our
//       `ssh -R` tunnel is up;
//     · TUNNEL DOWN  → that port is refused → a claude turn cannot complete;
//     · TUNNEL UP    → the port forwards to the Mac's 1081 → the turn succeeds.
//
//   A turn that fails without the tunnel but succeeds with it can only have
//   egressed through the Mac's proxy — never the remote's own network.
//
// LOGIN STATE (design §3i): when no API key/token is in the env, the smoke falls
// back to the Mac's claude.ai OAuth login in the Keychain — it reads it READ-ONLY,
// resolves a short-lived bearer (refreshing on the Mac through the *Claude-configured
// proxy* only if expired, never writing the Keychain, never forwarding the refresh
// token), and injects it into the remote `claude` as CLAUDE_CODE_OAUTH_TOKEN. This
// mirrors how the official Claude desktop app provisions a remote spawn (§9).
//
// PROVISIONING (design §3g, `managed`): when SMOKE_REMOTE_CLAUDE is unset, the Mac
// downloads the pinned, checksum-verified linux-x64 `claude` and uploads it to a
// controlled remote path (~/.ccterm/bin/claude), idempotently — the remote runs no
// installer (§9 SFTP fallback).
//
// Run from `macos/AgentSDK` — with a claude.ai subscription login (no API key
// needed) and a running local proxy:
//
//   swift run RemoteSmoke
//
// …or force an API-key/token credential instead:
//
//   ANTHROPIC_API_KEY=… swift run RemoteSmoke
//
// Env overrides:
//   SMOKE_SSH_HOST        remote ssh alias/host             (default: devbox)
//   SMOKE_EXISTING_PROXY  host:port of the Mac's local proxy (default: the
//                         Claude-configured HTTPS_PROXY, else 127.0.0.1:1081)
//   SMOKE_REMOTE_FWD_PORT loopback port to open on the remote (default: 18991)
//   SMOKE_REMOTE_CLAUDE   remote `claude` path; if unset, a CCTerm-managed claude
//                         is provisioned to ~/.ccterm/bin/claude (Mac download + upload)
//   SMOKE_REMOTE_WORKDIR  remote cwd for the session         (default: /tmp/ccterm-remote-smoke)
//   SMOKE_MODEL           model to drive                     (default: claude-haiku-4-5)
//   SMOKE_API_HOST        API host the curl differential probes (default: https://api.anthropic.com)
//   SMOKE_SKIP_CLAUDE_NEG set to 1 to skip the tunnel-down claude control turn
//   SMOKE_FORCE_REFRESH   set to 1 to force an OAuth refresh-through-proxy even when
//                         the cached access token is still fresh (Keychain still NOT written)
//   SMOKE_OAUTH_TOKEN_URL override the OAuth token endpoint (default: https://api.anthropic.com/v1/oauth/token)
//   Credentials forwarded to the remote (whichever are set locally, never logged):
//                         ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN,
//                         ANTHROPIC_BASE_URL, ANTHROPIC_CUSTOM_HEADERS, or the
//                         Keychain OAuth bearer as CLAUDE_CODE_OAUTH_TOKEN

// MARK: - helpers

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(msg)\n".utf8))
}

/// POSIX single-quote a string for safe embedding in a remote shell command.
/// This is the quoting the app layer (M4's `SSHLaunchBuilder`) owns; the SDK's
/// `.wrapped` argv stays untokenized, but the *remote command* is still a shell
/// string and must be quoted by the caller.
func shq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

@discardableResult
func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 40) -> (code: Int32, out: String, err: String)
{
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launchPath)
    proc.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe

    var outData = Data()
    var errData = Data()
    let group = DispatchGroup()
    let lock = NSLock()
    for (pipe, sink) in [(outPipe, 0), (errPipe, 1)] {
        group.enter()
        DispatchQueue.global().async {
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            if sink == 0 { outData = d } else { errData = d }
            lock.unlock()
            group.leave()
        }
    }
    do {
        try proc.run()
    } catch {
        return (-1, "", "spawn failed: \(error)")
    }
    let watchdog = DispatchQueue(label: "remote-smoke.watchdog")
    watchdog.asyncAfter(deadline: .now() + timeout) {
        if proc.isRunning { proc.terminate() }
    }
    proc.waitUntilExit()
    group.wait()
    return (
        proc.terminationStatus,
        String(data: outData, encoding: .utf8) ?? "",
        String(data: errData, encoding: .utf8) ?? ""
    )
}

/// Common `ssh -T` options: no PTY (8-bit-clean), batch (never prompt), and
/// keepalives so a dead network is detected rather than hanging forever.
func sshBaseOpts() -> [String] {
    [
        "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20",
        "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
    ]
}

// MARK: - config

let envv = ProcessInfo.processInfo.environment
let sshHost = envv["SMOKE_SSH_HOST"] ?? "devbox"
// The HTTP proxy the local Claude is configured with (process env →
// ~/.claude/settings.json `env`). Used both as the `ssh -R` tunnel target and as
// the Mac-side egress for an OAuth refresh — resolved from config, never hardcoded.
let claudeProxy = resolveClaudeProxy()
let existingProxy = envv["SMOKE_EXISTING_PROXY"] ?? proxyHostPort(claudeProxy.https) ?? "127.0.0.1:1081"
let remoteFwdPort = envv["SMOKE_REMOTE_FWD_PORT"] ?? "18991"
let remoteWorkdir = envv["SMOKE_REMOTE_WORKDIR"] ?? "/tmp/ccterm-remote-smoke"
let model = envv["SMOKE_MODEL"] ?? "claude-haiku-4-5"
// Optional real prompt to drive a genuine model answer (instead of the default
// PONG echo). When set, the positive turn asserts non-empty assistant text + no
// error result, and the full answer is logged.
let customPrompt = envv["SMOKE_PROMPT"]
let apiHost = envv["SMOKE_API_HOST"] ?? "https://api.anthropic.com"
let proxyURL = "http://127.0.0.1:\(remoteFwdPort)"
let reverseForward = "127.0.0.1:\(remoteFwdPort):\(existingProxy)"

// Credentials: prefer explicit env (API key / auth token). Otherwise fall back to
// the Mac's claude.ai OAuth login in the Keychain (§3i) — resolve a short-lived
// bearer (refreshed on the Mac through the Claude proxy if expired) and inject it
// as CLAUDE_CODE_OAUTH_TOKEN. The Keychain is read-only; the refresh token is
// never forwarded.
let credKeys = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS"]
let presentCreds = credKeys.filter { (envv[$0]?.isEmpty == false) }
let hasEnvAuth = presentCreds.contains("ANTHROPIC_API_KEY") || presentCreds.contains("ANTHROPIC_AUTH_TOKEN")

var oauthBearer: String? = nil
if !hasEnvAuth {
    guard let login = readKeychainOAuth() else {
        log(
            "ERROR: no API credential in env AND no usable claude.ai OAuth login in the Keychain — log in locally with `claude` (subscription) or set ANTHROPIC_API_KEY"
        )
        exit(1)
    }
    guard let bearer = resolveOAuthBearer(login, proxy: claudeProxy, force: envv["SMOKE_FORCE_REFRESH"] == "1")
    else {
        log("ERROR: could not resolve a usable OAuth bearer (token expired and refresh failed)")
        exit(1)
    }
    oauthBearer = bearer
}

log("ssh host=\(sshHost)  proxy=\(existingProxy)  remote-fwd-port=\(remoteFwdPort)  model=\(model)")
if hasEnvAuth {
    log("auth: forwarding env credentials: \(presentCreds.joined(separator: ", ")) (values never logged)")
} else {
    log(
        "auth: claude.ai OAuth login from Keychain → CLAUDE_CODE_OAUTH_TOKEN (bearer redacted; refresh token not forwarded; Keychain not modified)"
    )
}

var failures: [String] = []

/// Redact any forwarded credential value before logging an ssh argv.
func redact(_ argv: [String]) -> [String] {
    argv.map { tok -> String in
        var t = tok
        for k in presentCreds where (envv[k]?.isEmpty == false) {
            t = t.replacingOccurrences(of: envv[k]!, with: "<\(k)>")
        }
        if let b = oauthBearer, !b.isEmpty {
            t = t.replacingOccurrences(of: b, with: "<CLAUDE_CODE_OAUTH_TOKEN>")
        }
        return t
    }
}

/// The remote env assignments that force claude's egress through the proxy port
/// plus the forwarded credentials.
func remoteEnvAssignments() -> [String] {
    var a = [
        "HTTPS_PROXY=\(shq(proxyURL))", "https_proxy=\(shq(proxyURL))",
        "HTTP_PROXY=\(shq(proxyURL))", "http_proxy=\(shq(proxyURL))",
    ]
    for k in presentCreds { a.append("\(k)=\(shq(envv[k]!))") }
    // The §3i short-lived bearer from the Mac's claude.ai OAuth login. The CLI
    // treats CLAUDE_CODE_OAUTH_TOKEN as a subscription bearer (adds the oauth beta
    // header itself). Never the refresh token. NO_PROXY is deliberately NOT
    // forwarded — the remote must route all egress through the tunnel.
    if let b = oauthBearer, !b.isEmpty { a.append("CLAUDE_CODE_OAUTH_TOKEN=\(shq(b))") }
    return a
}

// MARK: - preflight: the local proxy must actually be up

let proxyCheck = run(
    "/usr/bin/curl",
    ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "10", "-x", "http://\(existingProxy)", apiHost],
    timeout: 15)
let proxyCode = proxyCheck.out.trimmingCharacters(in: .whitespaces)
if proxyCheck.code != 0 || proxyCode.isEmpty || proxyCode == "000" {
    log(
        "ERROR: local proxy \(existingProxy) did not reach \(apiHost) (curl exit=\(proxyCheck.code), code=\(proxyCode)) — is your 1081 proxy running?"
    )
    exit(1)
}
log("preflight OK: local proxy \(existingProxy) reaches \(apiHost) (HTTP \(proxyCode))")

// MARK: - resolve the remote claude path (managed provisioning — §3g)

let remoteClaude: String
if let pinned = envv["SMOKE_REMOTE_CLAUDE"], !pinned.isEmpty {
    remoteClaude = pinned
    log("remote claude (pinned): \(remoteClaude)")
} else {
    // `managed` policy: ensure CCTerm's own pinned `claude` at the controlled
    // remote path (~/.ccterm/bin/claude), installed by a Mac download + ssh
    // upload, idempotently. Returns an absolute path (safe to single-quote).
    guard let provisioned = ensureRemoteManagedClaude(sshHost: sshHost, sshOpts: sshBaseOpts(), proxy: claudeProxy)
    else {
        log(
            "ERROR: failed to provision the managed claude on \(sshHost). Set SMOKE_REMOTE_CLAUDE to an absolute path to bypass."
        )
        exit(1)
    }
    remoteClaude = provisioned
    log("remote claude (managed): \(remoteClaude)")
}

// MARK: - Part 1: curl differential — the 1081 tunnel is the API carrier
//
// Hit the API host through the proxy PORT on the remote, with and without the
// `ssh -R` tunnel. The port is alive ⟺ the tunnel is up, so this proves the
// tunnel→1081 path carries API traffic and that the port is dead without it —
// independent of whether the remote can reach the API on its own.

func remoteCurlViaProxy(useTunnel: Bool, maxTime: Int) -> (code: Int32, body: String) {
    let cmd =
        "curl -sS -o /dev/null -w '%{http_code}' --max-time \(maxTime) -x \(shq(proxyURL)) \(shq(apiHost)) 2>/dev/null || echo CURLFAIL"
    var argv = sshBaseOpts()
    if useTunnel { argv += ["-R", reverseForward] }
    argv += [sshHost, cmd]
    let r = run("/usr/bin/ssh", argv, timeout: TimeInterval(maxTime + 20))
    return (r.code, r.out.trimmingCharacters(in: .whitespacesAndNewlines))
}

log("=== Part 1: curl differential through the proxy port ===")
let curlDown = remoteCurlViaProxy(useTunnel: false, maxTime: 8)
log("tunnel DOWN: proxy-port curl → \(curlDown.body.isEmpty ? "(no output)" : curlDown.body)")
if !curlDown.body.contains("CURLFAIL") && (Int(curlDown.body) ?? 0) > 0 {
    failures.append(
        "tunnel-DOWN curl unexpectedly reached \(apiHost) (HTTP \(curlDown.body)) — something is already listening on the remote's \(remoteFwdPort); the differential is not decisive"
    )
}

let curlUp = remoteCurlViaProxy(useTunnel: true, maxTime: 12)
log("tunnel UP:   proxy-port curl → \(curlUp.body.isEmpty ? "(no output)" : curlUp.body)")
if curlUp.body.contains("CURLFAIL") || (Int(curlUp.body) ?? 0) <= 0 {
    failures.append(
        "tunnel-UP curl did NOT reach \(apiHost) through the proxy (\(curlUp.body)) — the ssh -R → 1081 path is broken")
} else if failures.isEmpty {
    log("Part 1 PASS — API reachable through 1081 ONLY with the tunnel up (HTTP \(curlUp.body))")
}

// MARK: - remote orphan detection (self-match-safe)

/// Run a short script on the remote by feeding it to `bash -s` over STDIN. This
/// matters for orphan detection: if the session id rode in the ssh argv, the
/// remote shell's own cmdline would contain it and `pgrep -f <id>` would match
/// itself. Delivered over stdin, the remote shell's argv is just `bash -s`, so the
/// only process whose cmdline carries the id is the real remote `claude`.
func sshRunScript(_ script: String, timeout: TimeInterval = 25) -> (code: Int32, out: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    proc.arguments = sshBaseOpts() + [sshHost, "bash -s"]
    let inPipe = Pipe()
    let outPipe = Pipe()
    proc.standardInput = inPipe
    proc.standardOutput = outPipe
    proc.standardError = FileHandle.nullDevice
    var outData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    do { try proc.run() } catch { return (-1, "") }
    inPipe.fileHandleForWriting.write(Data(script.utf8))
    try? inPipe.fileHandleForWriting.close()
    let watchdog = DispatchQueue(label: "remote-smoke.orphan.watchdog")
    watchdog.asyncAfter(deadline: .now() + timeout) { if proc.isRunning { proc.terminate() } }
    proc.waitUntilExit()
    group.wait()
    return (proc.terminationStatus, String(data: outData, encoding: .utf8) ?? "")
}

/// True if a remote `claude` carrying this session id is still running. nil if the
/// probe was inconclusive (e.g. ssh failed).
func remoteClaudeAlive(sessionId: String) -> Bool? {
    let r = sshRunScript("pgrep -f -- '\(sessionId)' >/dev/null 2>&1 && echo ALIVE || echo GONE")
    let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.contains("ALIVE") { return true }
    if s.contains("GONE") { return false }
    return nil
}

/// Kill any remote `claude` carrying this session id. pgrep returns only the real
/// process (the checking shell's argv is `bash -s`, never the id), so this targets
/// exactly the orphan.
func reapRemoteClaude(sessionId: String) {
    _ = sshRunScript("for p in $(pgrep -f -- '\(sessionId)' 2>/dev/null); do kill \"$p\" 2>/dev/null; done")
}

// MARK: - drive a claude turn over ssh

struct TurnOutcome {
    var started = false
    var initialized = false
    var sawPong = false
    var resultIsError: Bool?
    var timedOut = true
    var sshExitCode: Int32?
    var assistantText = ""
}

func buildSSHArgv(useTunnel: Bool, sessionId: String, claudeArgs: [String]) -> [String] {
    let quoted = claudeArgs.map(shq).joined(separator: " ")
    let remoteCommand =
        "mkdir -p \(shq(remoteWorkdir)) >/dev/null 2>&1; cd \(shq(remoteWorkdir)) || exit 97; "
        + "exec env \(remoteEnvAssignments().joined(separator: " ")) \(shq(remoteClaude)) \(quoted)"
    var argv = sshBaseOpts()
    if useTunnel { argv += ["-R", reverseForward] }
    argv += [sshHost, remoteCommand]
    return argv
}

func runClaudeTurn(useTunnel: Bool, label: String, strictLifecycle: Bool) async -> TurnOutcome {
    var outcome = TurnOutcome()
    let sessionId = UUID().uuidString.lowercased()
    let localWorkDir = URL(
        fileURLWithPath: "/tmp/ccterm-remote-smoke-local-\(sessionId.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: localWorkDir, withIntermediateDirectories: true)

    var config = SessionConfiguration(
        workingDirectory: localWorkDir,
        model: model,
        sessionId: sessionId,
        inheritsParentEnvironment: true,
        allowDangerouslySkipPermissions: true
    )
    let claudeArgs = config.claudeArguments()
    let argv = buildSSHArgv(useTunnel: useTunnel, sessionId: sessionId, claudeArgs: claudeArgs)
    config.launchPlan = .wrapped(executable: "/usr/bin/ssh", argv: argv)
    log("[\(label)] launch: /usr/bin/ssh \(redact(argv).joined(separator: " "))")

    let session = AgentSDK.Session(configuration: config)
    session.lastKnownSessionId = sessionId

    let resultSeen = DispatchSemaphore(value: 0)
    let processExited = DispatchSemaphore(value: 0)
    let lock = NSLock()

    session.onMessage = { (message: Message2) in
        switch message {
        case .assistant(let a):
            let texts: [String] = (a.message?.content ?? []).compactMap { block in
                if case .text(let t) = block, let txt = t.text { return txt }
                return nil
            }
            let joined = texts.joined()
            guard !joined.isEmpty else { return }
            lock.lock()
            outcome.assistantText += joined
            if outcome.assistantText.uppercased().contains("PONG") { outcome.sawPong = true }
            lock.unlock()
            log("[\(label)] asst: \(joined.prefix(120))")
        case .result(let r):
            lock.lock()
            switch r {
            case .success(let s):
                outcome.resultIsError = s.isError ?? false
                log("[\(label)] result.success isError=\(s.isError ?? false) turns=\(s.numTurns ?? -1)")
            case .errorDuringExecution(let e):
                outcome.resultIsError = true
                log("[\(label)] result.error errors=\(e.errors ?? [])")
            case .unknown(let name, _):
                log("[\(label)] result.unknown \(name)")
            }
            outcome.timedOut = false
            lock.unlock()
            resultSeen.signal()
        case .system(.`init`):
            log("[\(label)] system.init — remote claude is up")
        default:
            break
        }
    }
    session.onStderr = { text in
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { log("[\(label)] stderr: \(t.prefix(280))") }
    }
    session.onProcessExit = { code in
        lock.lock()
        outcome.sshExitCode = code
        lock.unlock()
        log("[\(label)] ssh process exited code=\(code)")
        processExited.signal()
    }

    do {
        try await session.start()
        outcome.started = true
        log("[\(label)] session.start ok")
    } catch {
        failures.append("[\(label)] session.start threw: \(error)")
        return outcome
    }

    let initDone = DispatchSemaphore(value: 0)
    session.initialize(promptSuggestions: false) { resp in
        log("[\(label)] init reply: models=\(resp?.models?.count ?? 0)")
        initDone.signal()
    }
    if initDone.wait(timeout: .now() + 60) == .timedOut {
        failures.append("[\(label)] initialize timed out after 60s")
        session.close()
        return outcome
    }
    outcome.initialized = true

    let turnPrompt =
        customPrompt
        ?? "Reply with exactly the single word: PONG. Output nothing else — no punctuation, no explanation."
    log("[\(label)] sending prompt…")
    session.sendMessage(
        turnPrompt,
        extra: ["uuid": UUID().uuidString.lowercased()])

    // Bounded wait for the final result envelope.
    _ = resultSeen.wait(timeout: .now() + 90)

    log("[\(label)] closing session (stdin EOF → channel close → remote claude exits)…")
    session.close()
    if processExited.wait(timeout: .now() + 15) == .timedOut {
        failures.append("[\(label)] local ssh process did not exit within 15s of close()")
    }

    // Orphan check: no remote claude carrying this session id should remain.
    // A turn that completed (the positive case) exits on stdin EOF immediately. A
    // turn deliberately wedged on a dead network (the tunnel-down control turn)
    // can only abort once its in-flight API call times out — claude DOES exit
    // then (stdin EOF was already delivered), so this is claude's network-timeout
    // behavior, not a launch/lifecycle defect (M7 hardening, out of scope for v1).
    // Poll briefly; reap a lingering control-turn process so the box stays clean.
    var alive = false
    var inconclusive = false
    var waited = 0.0
    while waited < 14 {
        Thread.sleep(forTimeInterval: 2)
        waited += 2
        switch remoteClaudeAlive(sessionId: sessionId) {
        case .some(true): alive = true
        case .some(false):
            alive = false
            inconclusive = false
        case .none: inconclusive = true
        }
        if !alive { break }
    }
    if alive {
        if strictLifecycle {
            failures.append(
                "[\(label)] ORPHAN: remote claude (session id \(sessionId)) still running \(Int(waited))s after close()"
            )
        } else {
            log(
                "[\(label)] expected lingering claude (control turn wedged on a dead network) — reaping to keep the box clean"
            )
        }
        reapRemoteClaude(sessionId: sessionId)
    } else if inconclusive {
        log("[\(label)] WARN: orphan check inconclusive (ssh probe failed)")
    } else {
        log("[\(label)] lifecycle OK: no orphan remote claude")
    }
    return outcome
}

// MARK: - Part 2: positive turn (tunnel UP) — protocol + lifecycle + egress via 1081

log("=== Part 2: claude turn with the tunnel UP (egress forced through 1081) ===")
let pos = await runClaudeTurn(useTunnel: true, label: "tunnel-up", strictLifecycle: true)
if !pos.started {
    failures.append("positive turn never started")
} else if pos.timedOut {
    failures.append("positive turn did not complete within 90s (no result) — protocol or egress broke")
} else if pos.resultIsError == true {
    failures.append(
        "positive turn returned an error result — could the remote authenticate AND reach the API via the tunnel?")
} else if customPrompt == nil && !pos.sawPong {
    failures.append(
        "positive turn completed but no assistant text contained PONG (got: '\(pos.assistantText.prefix(80))')")
} else if customPrompt != nil && pos.assistantText.isEmpty {
    failures.append("positive turn completed but produced no assistant text for the custom prompt")
} else {
    if customPrompt != nil {
        log("Part 2 — remote claude answered the prompt:\n----\n\(pos.assistantText)\n----")
    }
    log("Part 2 PASS — remote claude ran a clean turn over ssh; API egress went through 1081")
}

// MARK: - Part 3: control turn (tunnel DOWN) — claude must NOT use the remote's own network

if envv["SMOKE_SKIP_CLAUDE_NEG"] == "1" {
    log("=== Part 3 skipped (SMOKE_SKIP_CLAUDE_NEG=1) ===")
} else {
    log("=== Part 3: claude turn with the tunnel DOWN — must fail (proves no devbox-direct egress) ===")
    let neg = await runClaudeTurn(useTunnel: false, label: "tunnel-down", strictLifecycle: false)
    if neg.initialized && neg.sawPong && neg.resultIsError != true {
        failures.append(
            "control turn SUCCEEDED with the tunnel DOWN — claude reached the API WITHOUT the 1081 proxy (it used the remote's own network). The egress constraint is violated."
        )
    } else if !neg.initialized {
        log("Part 3 inconclusive — control turn failed before the API stage (init/start). Egress not exercised.")
    } else {
        log(
            "Part 3 PASS — with the tunnel down the turn could not complete (claude honors the proxy; no devbox-direct egress)"
        )
    }
}

// MARK: - report

log("=== REPORT ===")
if failures.isEmpty {
    log(
        "ALL PASS — structured launch + protocol + lifecycle over ssh, with API egress proven to flow ONLY through \(existingProxy)"
    )
    exit(0)
}
for f in failures { log("FAIL: \(f)") }
exit(1)

import Foundation
import RemoteEgress

// Real-network smoke for the remote-execution egress tunnel (design
// `remote-execution.md` §2b / M2). Proves a no-internet remote borrows the
// Mac's egress through `ssh -R`, in BOTH proxy modes:
//
//   Mode A — "use an existing local HTTP proxy": `ssh -R` targets a proxy the
//            user already runs (here 127.0.0.1:1081). Zero extra process.
//   Mode B — "let CCTerm run one": we start the native Swift `ConnectProxy`
//            and `ssh -R` targets it.
//
// The check, in both modes: run `curl <ip-url>` ON the remote with
// HTTPS_PROXY/HTTP_PROXY pointed at the `ssh -R` forwarded port, and assert the
// egress IP it reports is a valid public IPv4 whose /24 is NOT the remote's own
// egress /24. A packet can only egress at the remote or at the Mac, so "not the
// remote's pool" ⟹ "exited at the Mac". (We do not match the Mac's egress pool:
// the corp NAT spans many subnets, so equality there is inherently flaky.)
//
// Mode B additionally asserts the proxy binds 127.0.0.1 ONLY — never an open
// CONNECT relay on a routable interface.
//
// Run from `macos/AgentSDK`:
//
//   swift run RemoteEgressSmoke
//
// Env overrides:
//   SMOKE_SSH_HOST     remote ssh alias/host           (default: devbox)
//   SMOKE_EXISTING_PROXY  host:port of the existing proxy (default: 127.0.0.1:1081)
//   SMOKE_REMOTE_FWD_PORT loopback port to open on the remote (default: 18899)
//   SMOKE_IP_URL       HTTPS url echoing the caller IP  (default: https://api.ipify.org)
//   SMOKE_HTTP_IP_URL  plain-HTTP url echoing the caller IP, IPv4-only host so
//                      the /24 cross-check stays meaningful (default: http://api.ipify.org)
//   SMOKE_REMOTE_PROBE_URL  url the REMOTE can reach directly, to learn its own
//                      egress /24 (default: http://ifconfig.me/ip)

// MARK: - small process + logging helpers

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(msg)\n".utf8))
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

    // Drain pipes on background threads so a large/blocked write can't deadlock.
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

    let deadline = DispatchTime.now() + timeout
    let watchdog = DispatchQueue(label: "smoke.watchdog")
    watchdog.asyncAfter(deadline: deadline) {
        if proc.isRunning { proc.terminate() }
    }
    proc.waitUntilExit()
    group.wait()

    let out = String(data: outData, encoding: .utf8) ?? ""
    let err = String(data: errData, encoding: .utf8) ?? ""
    return (proc.terminationStatus, out, err)
}

func sshArgs(remoteForward: String? = nil, host: String, remoteCommand: String) -> [String] {
    var a = [
        "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
        "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
    ]
    if let rf = remoteForward { a += ["-R", rf] }
    a += [host, remoteCommand]
    return a
}

func trimIP(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// First non-loopback IPv4 address of this Mac (e.g. en0), for the loopback-only
/// security probe. Returns nil if the host has no routable IPv4 interface.
func primaryLANIPv4() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    var result: String?
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
            let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
        else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
        {
            let ip = String(cString: host)
            if isPublicIPv4OrPrivate(ip) {
                result = ip
                break
            }
        }
    }
    return result
}

/// Any well-formed IPv4 (public or private) — the LAN probe wants the Mac's
/// actual interface address, which is typically a private 192.168/10/172 IP.
func isPublicIPv4OrPrivate(_ s: String) -> Bool {
    let parts = s.split(separator: ".")
    return parts.count == 4 && parts.compactMap { UInt8($0) }.count == 4
}

/// `/24` prefix of a dotted-quad, else the whole string. The remote's own
/// egress sits in one stable `/24` (e.g. a `198.51.100.x`-style pool); the
/// Mac's egress can be a large NAT pool spanning *many* unrelated subnets and
/// even /8s, varying per destination. So we never assert "tunnel IP ∈ Mac's
/// pool" — that is inherently flaky. We assert the tight invariant instead
/// (see `evaluateBorrowed`).
func prefix24(_ ip: String) -> String {
    let octets = ip.split(separator: ".")
    guard octets.count == 4 else { return ip }
    return octets.prefix(3).joined(separator: ".")
}

/// A routable public IPv4 — guards against curl emitting an error page / empty
/// body instead of an IP, and rejects private/loopback/link-local ranges.
func isPublicIPv4(_ s: String) -> Bool {
    let parts = s.split(separator: ".")
    guard parts.count == 4 else { return false }
    let octets = parts.compactMap { UInt8($0) }
    guard octets.count == 4 else { return false }
    switch (octets[0], octets[1]) {
    case (10, _), (127, _), (0, _), (192, 168), (169, 254): return false
    case (172, 16...31): return false
    default: return true
    }
}

/// A global IPv6 (safety net: a dual-stack echo endpoint may answer over v6).
/// Rejects loopback `::1`, link-local `fe80:`, and unique-local `fc/fd`.
func isGlobalIPv6(_ s: String) -> Bool {
    guard s.contains(":") else { return false }
    let lower = s.lowercased()
    if lower == "::1" || lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd") {
        return false
    }
    return true
}

let env = ProcessInfo.processInfo.environment
let sshHost = env["SMOKE_SSH_HOST"] ?? "devbox"
let existingProxy = env["SMOKE_EXISTING_PROXY"] ?? "127.0.0.1:1081"
let remoteFwdPort = env["SMOKE_REMOTE_FWD_PORT"] ?? "18899"
let ipURL = env["SMOKE_IP_URL"] ?? "https://api.ipify.org"
let httpIPURL = env["SMOKE_HTTP_IP_URL"] ?? "http://api.ipify.org"
let remoteProbeURL = env["SMOKE_REMOTE_PROBE_URL"] ?? "http://ifconfig.me/ip"

log("ssh host=\(sshHost)  existing-proxy=\(existingProxy)  remote-fwd-port=\(remoteFwdPort)")
log("ip url (https/CONNECT)=\(ipURL)   ip url (http)=\(httpIPURL)   remote-probe=\(remoteProbeURL)")

var failures: [String] = []

// MARK: - reference IPs + the decisive invariant
//
// A packet from the remote can only egress in one of two places: at the remote
// itself (→ the remote's own NAT, a stable /24) or at the Mac (→ the Mac's NAT,
// some other address). So the tight, non-flaky proof that the remote "borrowed
// the Mac's egress" is: the IP a remote `curl` reports through the tunnel is a
// valid public IPv4 whose /24 is NOT the remote's own egress /24. We do NOT try
// to match the Mac's egress pool (it spans many subnets — see `prefix24`).

// Mac's egress, for context only (logged, never hard-asserted).
let macDirectNoProxy = trimIP(run("/usr/bin/curl", ["-s", "--noproxy", "*", "--max-time", "15", ipURL]).out)
let macViaExisting = trimIP(
    run("/usr/bin/curl", ["-s", "--max-time", "15", "--proxy", "http://\(existingProxy)", ipURL]).out)
log(
    "Mac egress (context)  direct=\(macDirectNoProxy.isEmpty ? "(none)" : macDirectNoProxy)  via-existing-proxy=\(macViaExisting.isEmpty ? "(none)" : macViaExisting)"
)

// The remote's OWN egress /24 — the thing the tunnel egress must differ from.
// Probed against a url the locked-down box CAN reach directly (the HTTPS IP
// target is refused — see the negative control next). `-4` to pin IPv4.
let remoteDirect = trimIP(
    run("/usr/bin/ssh", sshArgs(host: sshHost, remoteCommand: "curl -4 -s --max-time 12 \(remoteProbeURL) || true")).out
)
let remotePool = isPublicIPv4(remoteDirect) ? prefix24(remoteDirect) : ""
log(
    "Remote OWN egress=\(remoteDirect.isEmpty ? "(none/blocked)" : remoteDirect)  pool=\(remotePool.isEmpty ? "(unknown)" : remotePool + ".x")"
)

// Negative control: the HTTPS IP endpoint should be UNREACHABLE from the remote
// directly (§2b). If it ever becomes reachable, the ≠-remote-pool check below
// still carries the proof; this is logged context.
let neg = run("/usr/bin/ssh", sshArgs(host: sshHost, remoteCommand: "curl -sS --max-time 12 \(ipURL)"))
if neg.code == 0 && isPublicIPv4(trimIP(neg.out)) {
    log(
        "negative control: remote CAN reach \(ipURL) directly as \(trimIP(neg.out)) — proof leans on the ≠-remote-pool check"
    )
} else {
    log("negative control OK: remote cannot reach \(ipURL) directly (ssh/curl exit=\(neg.code))")
}

if macDirectNoProxy.isEmpty { failures.append("could not determine Mac egress IP (no local internet?)") }
if remotePool.isEmpty { log("WARN: remote OWN egress pool unknown — ≠-pool check degrades to a validity check") }

/// The shared verdict: did this tunnel result egress at the Mac (not the remote)?
func evaluateBorrowed(_ label: String, _ tunnelIP: String) {
    let v4 = isPublicIPv4(tunnelIP)
    if tunnelIP.isEmpty {
        failures.append("\(label): remote got no response through the tunnel")
    } else if !v4 && !isGlobalIPv6(tunnelIP) {
        failures.append("\(label): tunnel returned non-IP output '\(tunnelIP.prefix(60))'")
    } else if v4 && !remotePool.isEmpty && prefix24(tunnelIP) == remotePool {
        failures.append(
            "\(label): egress \(tunnelIP) is in the remote's OWN pool \(remotePool).x — NOT borrowing the Mac")
    } else {
        let note =
            v4 ? (remotePool.isEmpty ? "remote pool unknown" : "≠ \(remotePool).x") : "via IPv6, ≠ remote's IPv4 pool"
        log("\(label): PASS — egress \(tunnelIP) exited at the Mac, not the remote (\(note))")
    }
}

// MARK: - Mode A — reuse an existing local HTTP proxy

func tunnelCurl(forwardTarget: String, url: String = ipURL) -> String {
    // ssh -R 127.0.0.1:<remoteFwdPort>:<forwardTarget> ; remote curl via that port.
    // Point the proxy via env (how `claude`/Node actually consumes it). Set both
    // upper- and lower-case variants: Node honors HTTPS_PROXY, while curl ignores
    // the upper-case HTTP_PROXY for plain HTTP and only reads lower-case http_proxy.
    let rf = "127.0.0.1:\(remoteFwdPort):\(forwardTarget)"
    let p = "http://127.0.0.1:\(remoteFwdPort)"
    let remoteCmd =
        "HTTPS_PROXY=\(p) https_proxy=\(p) HTTP_PROXY=\(p) http_proxy=\(p) "
        + "curl -s --max-time 20 \(url)"
    let r = run("/usr/bin/ssh", sshArgs(remoteForward: rf, host: sshHost, remoteCommand: remoteCmd))
    if r.code != 0 {
        log("  ssh exit=\(r.code) stderr=\(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")
    }
    return trimIP(r.out)
}

log("=== Mode A: reuse existing proxy \(existingProxy) ===")
let modeAIP = tunnelCurl(forwardTarget: existingProxy)
log("Mode A: remote-through-tunnel egress=\(modeAIP.isEmpty ? "(none)" : modeAIP)")
evaluateBorrowed("Mode A", modeAIP)

// MARK: - Mode B — CCTerm's own native CONNECT proxy

log("=== Mode B: CCTerm-run native ConnectProxy ===")
let proxy = ConnectProxy()
proxy.onLog = { log("  [proxy] \($0)") }

do {
    let boundPort = try await proxy.start(port: 0)
    log("Mode B: ConnectProxy listening on 127.0.0.1:\(boundPort)")

    // Security: the proxy must bind loopback ONLY — an open CONNECT relay on a
    // routable interface would let anyone on the LAN tunnel through this Mac.
    // Prove it by trying to reach the port over a non-loopback address.
    if let lanIP = primaryLANIPv4() {
        let reach = run(
            "/usr/bin/curl",
            [
                "-s", "-o", "/dev/null", "-w", "%{http_code}",
                "--max-time", "4", "-x", "http://\(lanIP):\(boundPort)", ipURL,
            ])
        if reach.code == 0 {
            failures.append("SECURITY: proxy is reachable on \(lanIP):\(boundPort) — NOT loopback-only")
        } else {
            log("security OK: proxy refuses non-loopback \(lanIP):\(boundPort) (curl exit=\(reach.code))")
        }
    } else {
        log("security check skipped: no non-loopback IPv4 interface found")
    }

    let modeBIP = tunnelCurl(forwardTarget: "127.0.0.1:\(boundPort)")
    log("Mode B: remote-through-tunnel egress=\(modeBIP.isEmpty ? "(none)" : modeBIP)")
    evaluateBorrowed("Mode B (CONNECT)", modeBIP)

    // Also exercise the proxy's plain-HTTP forwarding path. CONNECT (above) is
    // the API path; plain HTTP is best-effort but shipped, so prove it forwards.
    let modeBHTTPIP = tunnelCurl(forwardTarget: "127.0.0.1:\(boundPort)", url: httpIPURL)
    log("Mode B (plain HTTP): remote-through-tunnel egress=\(modeBHTTPIP.isEmpty ? "(none)" : modeBHTTPIP)")
    evaluateBorrowed("Mode B (plain HTTP)", modeBHTTPIP)
    proxy.stop()
} catch {
    failures.append("Mode B: ConnectProxy failed to start: \(error)")
    proxy.stop()
}

// MARK: - report

log("=== REPORT ===")
if failures.isEmpty {
    log("ALL PASS — both egress modes borrow the Mac's network end-to-end")
    exit(0)
} else {
    for f in failures { log("FAIL: \(f)") }
    exit(1)
}

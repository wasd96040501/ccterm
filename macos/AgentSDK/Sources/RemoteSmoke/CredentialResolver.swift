import Foundation

// Login-state resolution for the remote smoke — design `remote-execution.md` §3i.
//
// This mirrors how the official Claude desktop app (reverse-engineered, §9)
// provisions auth for a remote spawn, and is written so the logic can later be
// lifted into the app-layer `RemoteCredentialResolver` / `SSHLaunchBuilder`:
//
//   · The Mac OWNS the credential. We read the local claude.ai OAuth login from
//     the Keychain READ-ONLY and forward only a short-lived bearer.
//   · Refresh happens ON THE MAC, lazily (only when the access token is expired),
//     through the SAME HTTP proxy the local Claude is configured with (resolved
//     from config — never hardcoded). The refreshed token is kept in-process; we
//     NEVER write the Keychain (Claude.app treats that item as read-only too) and
//     NEVER forward the refresh token.
//   · client_id is the Claude Code CLI's public OAuth client — the only client a
//     `Claude Code-credentials` refresh token is bound to.
//
// `run()` / `log()` are defined in `main.swift` (same target).

// MARK: - Claude-configured HTTP proxy (resolved, not hardcoded)

struct ClaudeProxy {
    var https: String?  // e.g. "http://localhost:1081"
    var noProxy: String?
}

/// Resolve the HTTP proxy the local Claude is configured with, the way the CLI
/// itself would: process environment first, then the `env` block of
/// `~/.claude/settings.json`. Never hardcodes a port — returns nil components if
/// nothing is configured, and the caller decides any fallback.
func resolveClaudeProxy() -> ClaudeProxy {
    let env = ProcessInfo.processInfo.environment
    func pick(_ keys: [String], _ table: [String: String]) -> String? {
        for k in keys { if let v = table[k], !v.isEmpty { return v } }
        return nil
    }
    var https = pick(["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"], env)
    var noProxy = pick(["NO_PROXY", "no_proxy"], env)
    if https == nil || noProxy == nil, let settings = readClaudeSettingsEnv() {
        if https == nil { https = pick(["HTTPS_PROXY", "HTTP_PROXY"], settings) }
        if noProxy == nil { noProxy = pick(["NO_PROXY"], settings) }
    }
    return ClaudeProxy(https: https, noProxy: noProxy)
}

/// The `env` block of `~/.claude/settings.json` (where a user configures the
/// proxy for the local Claude). Returns nil if absent/unparseable.
private func readClaudeSettingsEnv() -> [String: String]? {
    let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    guard let data = FileManager.default.contents(atPath: path),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let env = obj["env"] as? [String: Any]
    else { return nil }
    var out: [String: String] = [:]
    for (k, v) in env { if let s = v as? String { out[k] = s } }
    return out
}

/// Extract `host:port` from a proxy URL like `http://localhost:1081`.
func proxyHostPort(_ url: String?) -> String? {
    guard let url, let comps = URLComponents(string: url), let host = comps.host else { return nil }
    return "\(host):\(comps.port ?? 8080)"
}

// MARK: - Local claude.ai OAuth login (Keychain, read-only)

struct OAuthLogin {
    var accessToken: String
    var refreshToken: String
    var expiresAtMs: Double
    var scopes: [String]

    /// Fresh with a 5-minute safety margin.
    var isFresh: Bool { Date().timeIntervalSince1970 * 1000 < expiresAtMs - 5 * 60 * 1000 }
}

/// Read the local Claude Code OAuth credential from the macOS Keychain.
/// READ-ONLY: this never writes the item back (mirrors Claude.app, which only
/// reads `Claude Code-credentials` and persists refreshed tokens to its own
/// store). Account is the OS user, exactly as the CLI / Claude.app query it.
func readKeychainOAuth() -> OAuthLogin? {
    let r = run(
        "/usr/bin/security",
        ["find-generic-password", "-a", NSUserName(), "-w", "-s", "Claude Code-credentials"],
        timeout: 15)
    guard r.code == 0 else {
        log("[cred] Keychain read failed (security exit=\(r.code)) — is a claude.ai login present?")
        return nil
    }
    let raw = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = raw.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let oauth = obj["claudeAiOauth"] as? [String: Any],
        let access = oauth["accessToken"] as? String, !access.isEmpty,
        let expiresAt = oauth["expiresAt"] as? Double
    else {
        log("[cred] Keychain item present but not a parseable claudeAiOauth credential")
        return nil
    }
    let refresh = oauth["refreshToken"] as? String ?? ""
    let scopes = (oauth["scopes"] as? [String]) ?? []
    return OAuthLogin(accessToken: access, refreshToken: refresh, expiresAtMs: expiresAt, scopes: scopes)
}

// MARK: - Bearer resolution (lazy refresh on the Mac, through Claude's proxy)

/// The Claude Code CLI's public OAuth client id. A `Claude Code-credentials`
/// refresh token is bound to this client, so this is the only client that can
/// refresh it (on the Mac, by the CLI, by Claude.app, or by us).
private let claudeCodeClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

/// Resolve a short-lived bearer to inject into the remote `claude`.
///
/// - Fresh access token → forward it as-is (NO network, NO writes). This is the
///   common path and the one the smoke verification hits (token still valid).
/// - Expired (or `force`) → refresh on the Mac via `POST <apiHost>/v1/oauth/token`
///   (client_id 9d1c250a) routed through the resolved Claude proxy. The new token
///   stays in-process only — the Keychain is NEVER written, the refresh token is
///   NEVER returned.
func resolveOAuthBearer(_ login: OAuthLogin, proxy: ClaudeProxy, force: Bool) -> String? {
    if login.isFresh && !force {
        log("[cred] access token fresh — forwarding existing bearer (no refresh, Keychain untouched)")
        return login.accessToken
    }
    guard !login.refreshToken.isEmpty else {
        log("[cred] token expired and no refresh token available")
        return nil
    }

    let tokenURL =
        ProcessInfo.processInfo.environment["SMOKE_OAUTH_TOKEN_URL"]
        ?? "https://api.anthropic.com/v1/oauth/token"
    log(
        "[cred] \(force ? "force-" : "")refreshing access token via \(tokenURL) through proxy \(proxy.https ?? "(none)") — Keychain will NOT be written"
    )

    let body: [String: Any] = [
        "grant_type": "refresh_token",
        "client_id": claudeCodeClientId,
        "refresh_token": login.refreshToken,
        "scope": login.scopes.joined(separator: " "),
    ]
    guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
        let bodyStr = String(data: bodyData, encoding: .utf8)
    else { return nil }

    // Routed through the Claude-configured proxy (`-x`), mirroring how the local
    // Claude reaches the API. The refresh token rides the request body (never
    // logged); we do not echo this argv anywhere.
    var args = [
        "-fsS", "--max-time", "30", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-H", "anthropic-version: 2023-06-01",
        "--data-binary", bodyStr,
    ]
    if let p = proxy.https { args += ["-x", p] }
    args.append(tokenURL)

    let r = run("/usr/bin/curl", args, timeout: 40)
    guard r.code == 0,
        let data = r.out.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let newAccess = obj["access_token"] as? String, !newAccess.isEmpty
    else {
        log("[cred] refresh failed (curl exit=\(r.code)) — not falling back to a stale token")
        return nil
    }
    log("[cred] refresh OK — new short-lived bearer obtained (in-process only)")
    return newAccess
}

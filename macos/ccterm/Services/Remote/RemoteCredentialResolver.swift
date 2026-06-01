import Foundation

/// Resolves the Mac's current credential into the launch-time env for a
/// `managed` remote `claude` (design `remote-execution.md` §3i, aligned with
/// Claude.app §9). App-layer port of `RemoteSmoke`'s `CredentialResolver`; the
/// smoke keeps its own copy (remote logic is app-owned, no shared target).
///
/// Invariants (the security model):
///   · The Mac OWNS the credential. The Keychain is read **read-only**; we never
///     write it and never forward the refresh token.
///   · OAuth refresh happens ON THE MAC, lazily (only when the access token is
///     expired), through the SAME proxy the local Claude is configured with.
///   · Only a short-lived bearer / API key reaches the remote, as launch env.
///
/// Blocking (shells out to `security` / `curl`) — call off the main actor.
nonisolated struct RemoteCredentialResolver {

    /// The HTTP proxy the local Claude is configured with, resolved the way the
    /// CLI itself resolves it. Used both as the OAuth-refresh egress and (by the
    /// coordinator) as the `ssh -R` tunnel target.
    struct ClaudeProxy {
        var https: String?  // e.g. "http://localhost:1081"
        var noProxy: String?
    }

    /// The Claude Code CLI's public OAuth client id. A `Claude Code-credentials`
    /// refresh token is bound to this client, so it is the only client that can
    /// refresh it.
    private static let claudeCodeClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Resolve launch-time credential env for a `managed` host. Returns nil when
    /// no usable credential exists (caller should surface a launch failure).
    ///
    /// Order mirrors the smoke: explicit API key / auth token in the env or
    /// `~/.claude/settings.json` wins; otherwise fall back to the claude.ai OAuth
    /// login in the Keychain, refreshing on the Mac if the access token expired.
    func resolveLaunchEnv(forceRefresh: Bool = false) -> [String: String]? {
        let settingsEnv = Self.readClaudeSettingsEnv() ?? [:]
        let processEnv = ProcessInfo.processInfo.environment

        func pick(_ key: String) -> String? {
            if let v = processEnv[key], !v.isEmpty { return v }
            if let v = settingsEnv[key], !v.isEmpty { return v }
            return nil
        }

        var env: [String: String] = [:]
        for key in ["ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS"] {
            if let v = pick(key) { env[key] = v }
        }
        if let apiKey = pick("ANTHROPIC_API_KEY") {
            env["ANTHROPIC_API_KEY"] = apiKey
            return env
        }
        if let authToken = pick("ANTHROPIC_AUTH_TOKEN") {
            env["ANTHROPIC_AUTH_TOKEN"] = authToken
            return env
        }

        // No explicit key/token → claude.ai OAuth login from the Keychain.
        guard let login = Self.readKeychainOAuth() else {
            appLog(
                .error, "RemoteCredentialResolver",
                "no API credential AND no usable claude.ai OAuth login in the Keychain")
            return nil
        }
        guard let bearer = resolveOAuthBearer(login, proxy: Self.resolveClaudeProxy(), force: forceRefresh) else {
            appLog(.error, "RemoteCredentialResolver", "could not resolve a usable OAuth bearer (refresh failed)")
            return nil
        }
        env["CLAUDE_CODE_OAUTH_TOKEN"] = bearer
        return env
    }

    // MARK: - Claude-configured proxy (resolved, not hardcoded)

    /// Resolve the local Claude's HTTP proxy: process env → `~/.claude/settings.json`
    /// `env`. nil components when nothing is configured (caller decides fallback).
    static func resolveClaudeProxy() -> ClaudeProxy {
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

    /// Extract `host:port` from a proxy URL like `http://localhost:1081`.
    static func proxyHostPort(_ url: String?) -> String? {
        guard let url, let comps = URLComponents(string: url), let host = comps.host else { return nil }
        return "\(host):\(comps.port ?? 8080)"
    }

    private static func readClaudeSettingsEnv() -> [String: String]? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
        guard let data = FileManager.default.contents(atPath: path),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let env = obj["env"] as? [String: Any]
        else { return nil }
        var out: [String: String] = [:]
        for (k, v) in env { if let s = v as? String { out[k] = s } }
        return out
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
    /// READ-ONLY — never written back. Account is the OS user, exactly as the
    /// CLI / Claude.app query it.
    static func readKeychainOAuth() -> OAuthLogin? {
        let r = RemoteProcess.run(
            "/usr/bin/security",
            ["find-generic-password", "-a", NSUserName(), "-w", "-s", "Claude Code-credentials"],
            timeout: 15)
        guard r.code == 0 else {
            appLog(.warning, "RemoteCredentialResolver", "Keychain read failed (security exit=\(r.code))")
            return nil
        }
        let raw = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = raw.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = obj["claudeAiOauth"] as? [String: Any],
            let access = oauth["accessToken"] as? String, !access.isEmpty,
            let expiresAt = oauth["expiresAt"] as? Double
        else {
            appLog(.warning, "RemoteCredentialResolver", "Keychain item not a parseable claudeAiOauth credential")
            return nil
        }
        let refresh = oauth["refreshToken"] as? String ?? ""
        let scopes = (oauth["scopes"] as? [String]) ?? []
        return OAuthLogin(accessToken: access, refreshToken: refresh, expiresAtMs: expiresAt, scopes: scopes)
    }

    // MARK: - Bearer resolution (lazy refresh on the Mac, through Claude's proxy)

    /// Fresh token → forward as-is (no network, no writes). Expired (or `force`)
    /// → refresh on the Mac via `POST /v1/oauth/token` (client_id 9d1c250a)
    /// through the resolved Claude proxy; the new token stays in-process. The
    /// Keychain is NEVER written, the refresh token is NEVER returned.
    func resolveOAuthBearer(_ login: OAuthLogin, proxy: ClaudeProxy, force: Bool) -> String? {
        if login.isFresh && !force {
            appLog(.info, "RemoteCredentialResolver", "access token fresh — forwarding existing bearer (no refresh)")
            return login.accessToken
        }
        guard !login.refreshToken.isEmpty else {
            appLog(.warning, "RemoteCredentialResolver", "token expired and no refresh token available")
            return nil
        }

        let tokenURL = "https://api.anthropic.com/v1/oauth/token"
        appLog(
            .info, "RemoteCredentialResolver",
            "refreshing access token via \(tokenURL) through proxy \(proxy.https ?? "(none)") — Keychain not written")

        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": Self.claudeCodeClientId,
            "refresh_token": login.refreshToken,
            "scope": login.scopes.joined(separator: " "),
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
            let bodyStr = String(data: bodyData, encoding: .utf8)
        else { return nil }

        var args = [
            "-fsS", "--max-time", "30", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", "anthropic-version: 2023-06-01",
            "--data-binary", bodyStr,
        ]
        if let p = proxy.https { args += ["-x", p] }
        args.append(tokenURL)

        let r = RemoteProcess.run("/usr/bin/curl", args, timeout: 40)
        guard r.code == 0,
            let data = r.out.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let newAccess = obj["access_token"] as? String, !newAccess.isEmpty
        else {
            appLog(.error, "RemoteCredentialResolver", "refresh failed (curl exit=\(r.code)) — not using a stale token")
            return nil
        }
        appLog(.info, "RemoteCredentialResolver", "refresh OK — new short-lived bearer obtained (in-process only)")
        return newAccess
    }
}

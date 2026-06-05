import Foundation

// MARK: - Removable: tri-state value wrapper

/// Field that can be set, cleared, or omitted entirely.
///
/// - `unset`: skipped during serialization (field absent from JSON)
/// - `clear`: serialized as JSON `null` (CLI removes the field from flag settings)
/// - `set(T)`: serialized as the wrapped value
public enum Removable<T> {
    case unset
    case clear
    case set(T)

    /// Converts the value to a serializable `Any?`. Returning `nil` skips the field.
    func serialized(_ transform: (T) -> Any) -> Any? {
        switch self {
        case .unset: return nil
        case .clear: return NSNull()
        case .set(let value): return transform(value)
        }
    }

    /// Convenience overload for types that are themselves valid JSON values.
    func serialized() -> Any? where T: JSONSerializableValue {
        serialized { $0.jsonValue }
    }
}

/// Type that can be used directly as a JSON value.
protocol JSONSerializableValue {
    var jsonValue: Any { get }
}

extension String: JSONSerializableValue { var jsonValue: Any { self } }
extension Bool: JSONSerializableValue { var jsonValue: Any { self } }
extension Int: JSONSerializableValue { var jsonValue: Any { self } }
extension Double: JSONSerializableValue { var jsonValue: Any { self } }

extension Array: JSONSerializableValue where Element: JSONSerializableValue {
    var jsonValue: Any { map { $0.jsonValue } }
}

extension Dictionary: JSONSerializableValue where Key == String, Value: JSONSerializableValue {
    var jsonValue: Any { mapValues { $0.jsonValue } }
}

// MARK: - DictionarySerializable

/// Type that serializes to `[String: Any]`.
protocol DictionarySerializable {
    func toDictionary() -> [String: Any]
}

extension DictionarySerializable {
    var jsonValue: Any { toDictionary() }
}

// MARK: - FlagSettings

/// Type-safe builder for the CLI's `apply_flag_settings` protocol.
///
/// Every field defaults to `.unset` (omitted from serialization).
/// Setting `.clear` removes the corresponding field on the CLI side.
///
/// ```swift
/// var settings = FlagSettings()
/// settings.effortLevel = .set(.high)
/// settings.fastMode = .set(true)
/// settings.language = .set("zh-CN")
/// session.applyFlagSettings(settings)
/// ```
public struct FlagSettings: DictionarySerializable {

    // MARK: Model & reasoning

    /// Overrides the default model. When set, also triggers `setMainLoopModelOverride()`.
    public var model: Removable<String> = .unset

    /// Optional model whitelist. Accepts family alias ("opus"), version prefix ("opus-4-5"), or full model ID.
    public var availableModels: Removable<[String]> = .unset

    /// Model ID remap (e.g. Anthropic model ID -> Bedrock ARN).
    public var modelOverrides: Removable<[String: String]> = .unset

    /// Model used by the server-side advisor tool.
    public var advisorModel: Removable<String> = .unset

    /// Reasoning effort level. `max` is only available to Anthropic users.
    public var effortLevel: Removable<Effort> = .unset

    /// Whether thinking is enabled. `false` disables it; default is `true`.
    public var alwaysThinkingEnabled: Removable<Bool> = .unset

    public var fastMode: Removable<Bool> = .unset

    /// Fast mode is not persisted across sessions.
    public var fastModePerSessionOptIn: Removable<Bool> = .unset

    /// Enable "ultracode" for the session: xhigh effort plus standing
    /// dynamic-workflow orchestration. Pair with `effortLevel = .set(.xhigh)`.
    /// Requires workflows enabled and an xhigh-capable model CLI-side.
    public var ultracode: Removable<Bool> = .unset

    // MARK: Auth & credentials

    /// Path to a script that prints the auth value.
    public var apiKeyHelper: Removable<String> = .unset

    /// Path to a script that exports AWS credentials.
    public var awsCredentialExport: Removable<String> = .unset

    /// Path to a script that refreshes AWS auth.
    public var awsAuthRefresh: Removable<String> = .unset

    /// Command that refreshes GCP auth.
    public var gcpAuthRefresh: Removable<String> = .unset

    /// Forces a specific login method.
    public var forceLoginMethod: Removable<LoginMethod> = .unset

    /// Organization UUID for OAuth login.
    public var forceLoginOrgUUID: Removable<String> = .unset

    // MARK: Permissions & security

    /// Tool permission configuration.
    public var permissions: Removable<Permissions> = .unset

    /// Only honor managed permission rules.
    public var allowManagedPermissionRulesOnly: Removable<Bool> = .unset

    /// Skip the bypass-mode confirmation prompt.
    public var skipDangerousModePermissionPrompt: Removable<Bool> = .unset

    /// Disable auto mode. Setting `true` sends `"disable"`.
    public var disableAutoMode: Removable<Bool> = .unset

    // MARK: MCP servers

    /// Auto-approve every MCP server in the project.
    public var enableAllProjectMcpServers: Removable<Bool> = .unset

    /// Approved `.mcp.json` servers.
    public var enabledMcpjsonServers: Removable<[String]> = .unset

    /// Rejected `.mcp.json` servers.
    public var disabledMcpjsonServers: Removable<[String]> = .unset

    /// MCP server allowlist.
    public var allowedMcpServers: Removable<[McpServerEntry]> = .unset

    /// MCP server denylist.
    public var deniedMcpServers: Removable<[McpServerEntry]> = .unset

    /// Read the MCP allowlist only from managed settings.
    public var allowManagedMcpServersOnly: Removable<Bool> = .unset

    // MARK: Hooks & customization

    /// Custom commands run before/after tool execution. JSON shape: `Record<eventName, HookMatcher[]>`.
    public var hooks: Removable<[String: Any]> = .unset

    /// Disable every hook and statusLine.
    public var disableAllHooks: Removable<Bool> = .unset

    /// Only allow managed hooks.
    public var allowManagedHooksOnly: Removable<Bool> = .unset

    /// HTTP hook URL allowlist (supports `*` wildcards).
    public var allowedHttpHookUrls: Removable<[String]> = .unset

    /// Allowlist of env vars exposed to HTTP hooks.
    public var httpHookAllowedEnvVars: Removable<[String]> = .unset

    /// Custom status line.
    public var statusLine: Removable<StatusLine> = .unset

    /// Restrict customization to plugins. `true` locks everything; an array locks specific surfaces.
    public var strictPluginOnlyCustomization: Removable<PluginCustomization> = .unset

    // MARK: UI & output

    /// Assistant response output style.
    public var outputStyle: Removable<String> = .unset

    /// Preferred language.
    public var language: Removable<String> = .unset

    /// Disable syntax highlighting.
    public var syntaxHighlightingDisabled: Removable<Bool> = .unset

    /// Show spinner tips.
    public var spinnerTipsEnabled: Removable<Bool> = .unset

    /// Custom spinner verbs.
    public var spinnerVerbs: Removable<SpinnerVerbs> = .unset

    /// Override spinner tips.
    public var spinnerTipsOverride: Removable<SpinnerTipsOverride> = .unset

    /// Reduce animations.
    public var prefersReducedMotion: Removable<Bool> = .unset

    /// Show thinking summaries. Default `false`.
    public var showThinkingSummaries: Removable<Bool> = .unset

    /// Prompt suggestions.
    public var promptSuggestionEnabled: Removable<Bool> = .unset

    /// Have `/rename` update the terminal title. Default `true`.
    public var terminalTitleFromRename: Removable<Bool> = .unset

    // MARK: Plugins & marketplaces

    /// Enabled plugins. Key format: `"plugin-id@marketplace-id"`.
    /// Value: `true`/`false` or a string array.
    public var enabledPlugins: Removable<[String: Any]> = .unset

    /// Additional marketplaces.
    public var extraKnownMarketplaces: Removable<[String: ExtraKnownMarketplace]> = .unset

    /// Enterprise marketplace allowlist.
    public var strictKnownMarketplaces: Removable<[[String: Any]]> = .unset

    /// Enterprise marketplace denylist.
    public var blockedMarketplaces: Removable<[[String: Any]]> = .unset

    /// Plugin configuration.
    public var pluginConfigs: Removable<[String: Any]> = .unset

    /// Custom plugin trust warning message (read only from policy settings).
    public var pluginTrustMessage: Removable<String> = .unset

    // MARK: Git & project

    /// Commit/PR attribution text.
    public var attribution: Removable<Attribution> = .unset

    /// (Deprecated) co-authored-by attribution. Use `attribution` instead.
    public var includeCoAuthoredBy: Removable<Bool> = .unset

    /// Include git instructions in the system prompt. Default `true`.
    public var includeGitInstructions: Removable<Bool> = .unset

    /// Worktree configuration.
    public var worktree: Removable<Worktree> = .unset

    /// Custom plans directory (relative to the project root).
    public var plansDirectory: Removable<String> = .unset

    // MARK: Misc

    /// Environment variables.
    public var env: Removable<[String: String]> = .unset

    /// Custom command for `@`-mention file suggestions.
    public var fileSuggestion: Removable<FileSuggestion> = .unset

    /// File picker honors `.gitignore`. Default `true`.
    public var respectGitignore: Removable<Bool> = .unset

    /// Chat history retention in days. `0` disables persistence. Default `30`.
    public var cleanupPeriodDays: Removable<Int> = .unset

    /// Default shell.
    public var defaultShell: Removable<Shell> = .unset

    /// Sandbox configuration.
    public var sandbox: Removable<Sandbox> = .unset

    /// Skip the WebFetch denylist check.
    public var skipWebFetchPreflight: Removable<Bool> = .unset

    /// Survey appearance probability (0-1).
    public var feedbackSurveyRate: Removable<Double> = .unset

    /// Auto-update channel.
    public var autoUpdatesChannel: Removable<UpdateChannel> = .unset

    /// Minimum version (prevents downgrades).
    public var minimumVersion: Removable<String> = .unset

    /// Agent used by the main loop.
    public var agent: Removable<String> = .unset

    /// Company announcements shown at launch.
    public var companyAnnouncements: Removable<[String]> = .unset

    /// Remote session configuration.
    public var remote: Removable<Remote> = .unset

    /// SSH connection configurations.
    public var sshConfigs: Removable<[SSHConfig]> = .unset

    /// Glob patterns for CLAUDE.md files to exclude.
    public var claudeMdExcludes: Removable<[String]> = .unset

    /// Enable auto-memory.
    public var autoMemoryEnabled: Removable<Bool> = .unset

    /// Auto-memory directory (supports `~/` prefix).
    public var autoMemoryDirectory: Removable<String> = .unset

    /// Background memory consolidation.
    public var autoDreamEnabled: Removable<Bool> = .unset

    /// Show the "clear context" option when accepting a plan.
    public var showClearContextOnPlanAccept: Removable<Bool> = .unset

    /// Enable channel notifications.
    public var channelsEnabled: Removable<Bool> = .unset

    /// Channel plugin allowlist.
    public var allowedChannelPlugins: Removable<[ChannelPlugin]> = .unset

    public init() {}

    // MARK: - Serialization

    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [:]

        func add(_ key: String, _ value: Any?) {
            if let value { dict[key] = value }
        }

        // Model & reasoning
        add("model", model.serialized())
        add("availableModels", availableModels.serialized())
        add("modelOverrides", modelOverrides.serialized())
        add("advisorModel", advisorModel.serialized())
        add("effortLevel", effortLevel.serialized { $0.rawValue })
        add("alwaysThinkingEnabled", alwaysThinkingEnabled.serialized())
        add("fastMode", fastMode.serialized())
        add("fastModePerSessionOptIn", fastModePerSessionOptIn.serialized())
        add("ultracode", ultracode.serialized())

        // Auth & credentials
        add("apiKeyHelper", apiKeyHelper.serialized())
        add("awsCredentialExport", awsCredentialExport.serialized())
        add("awsAuthRefresh", awsAuthRefresh.serialized())
        add("gcpAuthRefresh", gcpAuthRefresh.serialized())
        add("forceLoginMethod", forceLoginMethod.serialized { $0.rawValue })
        add("forceLoginOrgUUID", forceLoginOrgUUID.serialized())

        // Permissions & security
        add("permissions", permissions.serialized { $0.toDictionary() })
        add("allowManagedPermissionRulesOnly", allowManagedPermissionRulesOnly.serialized())
        add("skipDangerousModePermissionPrompt", skipDangerousModePermissionPrompt.serialized())
        add("disableAutoMode", disableAutoMode.serialized { $0 ? "disable" as Any : NSNull() as Any })

        // MCP servers
        add("enableAllProjectMcpServers", enableAllProjectMcpServers.serialized())
        add("enabledMcpjsonServers", enabledMcpjsonServers.serialized())
        add("disabledMcpjsonServers", disabledMcpjsonServers.serialized())
        add("allowedMcpServers", allowedMcpServers.serialized { $0.map { $0.toDictionary() } })
        add("deniedMcpServers", deniedMcpServers.serialized { $0.map { $0.toDictionary() } })
        add("allowManagedMcpServersOnly", allowManagedMcpServersOnly.serialized())

        // Hooks & customization
        add("hooks", hooks.serialized { $0 })
        add("disableAllHooks", disableAllHooks.serialized())
        add("allowManagedHooksOnly", allowManagedHooksOnly.serialized())
        add("allowedHttpHookUrls", allowedHttpHookUrls.serialized())
        add("httpHookAllowedEnvVars", httpHookAllowedEnvVars.serialized())
        add("statusLine", statusLine.serialized { $0.toDictionary() })
        add("strictPluginOnlyCustomization", strictPluginOnlyCustomization.serialized { $0.jsonValue })

        // UI & output
        add("outputStyle", outputStyle.serialized())
        add("language", language.serialized())
        add("syntaxHighlightingDisabled", syntaxHighlightingDisabled.serialized())
        add("spinnerTipsEnabled", spinnerTipsEnabled.serialized())
        add("spinnerVerbs", spinnerVerbs.serialized { $0.toDictionary() })
        add("spinnerTipsOverride", spinnerTipsOverride.serialized { $0.toDictionary() })
        add("prefersReducedMotion", prefersReducedMotion.serialized())
        add("showThinkingSummaries", showThinkingSummaries.serialized())
        add("promptSuggestionEnabled", promptSuggestionEnabled.serialized())
        add("terminalTitleFromRename", terminalTitleFromRename.serialized())

        // Plugins & marketplaces
        add("enabledPlugins", enabledPlugins.serialized { $0 })
        add(
            "extraKnownMarketplaces",
            extraKnownMarketplaces.serialized { dict in
                dict.mapValues { $0.toDictionary() }
            })
        add("strictKnownMarketplaces", strictKnownMarketplaces.serialized { $0 })
        add("blockedMarketplaces", blockedMarketplaces.serialized { $0 })
        add("pluginConfigs", pluginConfigs.serialized { $0 })
        add("pluginTrustMessage", pluginTrustMessage.serialized())

        // Git & project
        add("attribution", attribution.serialized { $0.toDictionary() })
        add("includeCoAuthoredBy", includeCoAuthoredBy.serialized())
        add("includeGitInstructions", includeGitInstructions.serialized())
        add("worktree", worktree.serialized { $0.toDictionary() })
        add("plansDirectory", plansDirectory.serialized())

        // Misc
        add("env", env.serialized())
        add("fileSuggestion", fileSuggestion.serialized { $0.toDictionary() })
        add("respectGitignore", respectGitignore.serialized())
        add("cleanupPeriodDays", cleanupPeriodDays.serialized())
        add("defaultShell", defaultShell.serialized { $0.rawValue })
        add("sandbox", sandbox.serialized { $0.toDictionary() })
        add("skipWebFetchPreflight", skipWebFetchPreflight.serialized())
        add("feedbackSurveyRate", feedbackSurveyRate.serialized())
        add("autoUpdatesChannel", autoUpdatesChannel.serialized { $0.rawValue })
        add("minimumVersion", minimumVersion.serialized())
        add("agent", agent.serialized())
        add("companyAnnouncements", companyAnnouncements.serialized())
        add("remote", remote.serialized { $0.toDictionary() })
        add("sshConfigs", sshConfigs.serialized { $0.map { $0.toDictionary() } })
        add("claudeMdExcludes", claudeMdExcludes.serialized())
        add("autoMemoryEnabled", autoMemoryEnabled.serialized())
        add("autoMemoryDirectory", autoMemoryDirectory.serialized())
        add("autoDreamEnabled", autoDreamEnabled.serialized())
        add("showClearContextOnPlanAccept", showClearContextOnPlanAccept.serialized())
        add("channelsEnabled", channelsEnabled.serialized())
        add("allowedChannelPlugins", allowedChannelPlugins.serialized { $0.map { $0.toDictionary() } })

        return dict
    }
}

// MARK: - Effort factory

extension FlagSettings {

    /// Build the flag settings for an effort selection. The `.ultracode`
    /// tier is not a real CLI `effortLevel` — it maps to `xhigh` plus the
    /// `ultracode` flag. Every other tier sends `ultracode: false` so the
    /// two are mutually exclusive: picking a normal effort turns ultracode
    /// off, and picking ultracode forces xhigh.
    public static func effort(_ effort: Effort) -> FlagSettings {
        var settings = FlagSettings()
        if effort == .ultracode {
            settings.effortLevel = .set(.xhigh)
            settings.ultracode = .set(true)
        } else {
            settings.effortLevel = .set(effort)
            settings.ultracode = .set(false)
        }
        return settings
    }
}

// MARK: - Enums

extension FlagSettings {

    public enum LoginMethod: String {
        case claudeai
        case console
    }

    public enum Shell: String {
        case bash
        case powershell
    }

    public enum UpdateChannel: String {
        case latest
        case stable
    }

    /// Scope of plugin-only customization lock.
    public enum PluginCustomization {
        /// Lock every customization surface.
        case all
        /// Lock the listed surfaces.
        case surfaces([Surface])

        public enum Surface: String {
            case skills
            case agents
            case hooks
            case mcp
        }

        var jsonValue: Any {
            switch self {
            case .all: return true
            case .surfaces(let surfaces): return surfaces.map { $0.rawValue }
            }
        }
    }
}

// MARK: - Sub-Schema Types

extension FlagSettings {

    /// Permission configuration.
    public struct Permissions: DictionarySerializable {
        /// Allowed action rules.
        public var allow: [[String: Any]]?
        /// Denied action rules.
        public var deny: [[String: Any]]?
        /// Action rules that require confirmation.
        public var ask: [[String: Any]]?
        /// Default permission mode.
        public var defaultMode: String?
        /// Disable bypass-permissions mode by setting `"disable"`.
        public var disableBypassPermissionsMode: String?
        /// Disable auto mode by setting `"disable"`.
        public var disableAutoMode: String?
        /// Additional working directories.
        public var additionalDirectories: [String]?

        public init(
            allow: [[String: Any]]? = nil,
            deny: [[String: Any]]? = nil,
            ask: [[String: Any]]? = nil,
            defaultMode: String? = nil,
            disableBypassPermissionsMode: String? = nil,
            disableAutoMode: String? = nil,
            additionalDirectories: [String]? = nil
        ) {
            self.allow = allow
            self.deny = deny
            self.ask = ask
            self.defaultMode = defaultMode
            self.disableBypassPermissionsMode = disableBypassPermissionsMode
            self.disableAutoMode = disableAutoMode
            self.additionalDirectories = additionalDirectories
        }

        public func toDictionary() -> [String: Any] {
            var dict: [String: Any] = [:]
            if let allow { dict["allow"] = allow }
            if let deny { dict["deny"] = deny }
            if let ask { dict["ask"] = ask }
            if let defaultMode { dict["defaultMode"] = defaultMode }
            if let disableBypassPermissionsMode { dict["disableBypassPermissionsMode"] = disableBypassPermissionsMode }
            if let disableAutoMode { dict["disableAutoMode"] = disableAutoMode }
            if let additionalDirectories { dict["additionalDirectories"] = additionalDirectories }
            return dict
        }
    }

    /// MCP server entry — pick one of `serverName` / `serverCommand` / `serverUrl`.
    public struct McpServerEntry: DictionarySerializable {
        public var serverName: String?
        public var serverCommand: [String]?
        public var serverUrl: String?

        /// Match by server name.
        public static func name(_ name: String) -> McpServerEntry {
            McpServerEntry(serverName: name)
        }

        /// Match by launch command.
        public static func command(_ command: [String]) -> McpServerEntry {
            McpServerEntry(serverCommand: command)
        }

        /// Match by URL.
        public static func url(_ url: String) -> McpServerEntry {
            McpServerEntry(serverUrl: url)
        }

        public init(serverName: String? = nil, serverCommand: [String]? = nil, serverUrl: String? = nil) {
            self.serverName = serverName
            self.serverCommand = serverCommand
            self.serverUrl = serverUrl
        }

        public func toDictionary() -> [String: Any] {
            var dict: [String: Any] = [:]
            if let serverName { dict["serverName"] = serverName }
            if let serverCommand { dict["serverCommand"] = serverCommand }
            if let serverUrl { dict["serverUrl"] = serverUrl }
            return dict
        }
    }

    /// Custom status line.
    public struct StatusLine: DictionarySerializable {
        public var command: String
        public var padding: Int?

        public init(command: String, padding: Int? = nil) {
            self.command = command
            self.padding = padding
        }

        public func toDictionary() -> [String: Any] {
            var dict: [String: Any] = ["type": "command", "command": command]
            if let padding { dict["padding"] = padding }
            return dict
        }
    }

    /// Custom spinner verbs.
    public struct SpinnerVerbs: DictionarySerializable {
        public var mode: Mode
        public var verbs: [String]

        public enum Mode: String {
            case append
            case replace
        }

        public init(mode: Mode, verbs: [String]) {
            self.mode = mode
            self.verbs = verbs
        }

        public func toDictionary() -> [String: Any] {
            ["mode": mode.rawValue, "verbs": verbs]
        }
    }

    /// Override for spinner tips.
    public struct SpinnerTipsOverride: DictionarySerializable {
        public var excludeDefault: Bool?
        public var tips: [String]

        public init(tips: [String], excludeDefault: Bool? = nil) {
            self.tips = tips
            self.excludeDefault = excludeDefault
        }

        public func toDictionary() -> [String: Any] {
            var dict: [String: Any] = ["tips": tips]
            if let excludeDefault { dict["excludeDefault"] = excludeDefault }
            return dict
        }
    }

    /// Git attribution configuration.
    public struct Attribution: DictionarySerializable {
        /// Commit attribution text. Empty string hides the attribution.
        public var commit: String?
        /// PR attribution text.
        public var pr: String?

        public init(commit: String? = nil, pr: String? = nil) {
            self.commit = commit
            self.pr = pr
        }

        public func toDictionary() -> [String: Any] {
            var dict: [String: Any] = [:]
            if let commit { dict["commit"] = commit }
            if let pr { dict["pr"] = pr }
            return dict
        }
    }

    /// Worktree configuration.
    public struct Worktree: DictionarySerializable {
        public var symlinkDirectories: [String]?
        public var sparsePaths: [String]?

        public init(symlinkDirectories: [String]? = nil, sparsePaths: [String]? = nil) {
            self.symlinkDirectories = symlinkDirectories
            self.sparsePaths = sparsePaths
        }

        public func toDictionary() -> [String: Any] {
            var dict: [String: Any] = [:]
            if let symlinkDirectories { dict["symlinkDirectories"] = symlinkDirectories }
            if let sparsePaths { dict["sparsePaths"] = sparsePaths }
            return dict
        }
    }

    /// Custom command for `@`-mention file suggestions.
    public struct FileSuggestion: DictionarySerializable {
        public var command: String

        public init(command: String) {
            self.command = command
        }

        public func toDictionary() -> [String: Any] {
            ["type": "command", "command": command]
        }
    }

    /// Additional marketplace configuration.
    public struct ExtraKnownMarketplace: DictionarySerializable {
        public var source: [String: Any]
        public var installLocation: String?
        public var autoUpdate: Bool?

        public init(source: [String: Any], installLocation: String? = nil, autoUpdate: Bool? = nil) {
            self.source = source
            self.installLocation = installLocation
            self.autoUpdate = autoUpdate
        }

        public func toDictionary() -> [String: Any] {
            var dict: [String: Any] = ["source": source]
            if let installLocation { dict["installLocation"] = installLocation }
            if let autoUpdate { dict["autoUpdate"] = autoUpdate }
            return dict
        }
    }

    /// Remote session configuration.
    public struct Remote: DictionarySerializable {
        public var defaultEnvironmentId: String?

        public init(defaultEnvironmentId: String? = nil) {
            self.defaultEnvironmentId = defaultEnvironmentId
        }

        public func toDictionary() -> [String: Any] {
            var dict: [String: Any] = [:]
            if let defaultEnvironmentId { dict["defaultEnvironmentId"] = defaultEnvironmentId }
            return dict
        }
    }

    /// SSH connection configuration.
    public struct SSHConfig: DictionarySerializable {
        public var id: String
        public var name: String
        /// `"user@hostname"` or a host alias from `~/.ssh/config`.
        public var sshHost: String
        /// SSH port; defaults to 22.
        public var sshPort: Int?
        /// SSH identity file path.
        public var sshIdentityFile: String?
        /// Starting directory (supports `~/` expansion).
        public var startDirectory: String?

        public init(
            id: String,
            name: String,
            sshHost: String,
            sshPort: Int? = nil,
            sshIdentityFile: String? = nil,
            startDirectory: String? = nil
        ) {
            self.id = id
            self.name = name
            self.sshHost = sshHost
            self.sshPort = sshPort
            self.sshIdentityFile = sshIdentityFile
            self.startDirectory = startDirectory
        }

        public func toDictionary() -> [String: Any] {
            var dict: [String: Any] = ["id": id, "name": name, "sshHost": sshHost]
            if let sshPort { dict["sshPort"] = sshPort }
            if let sshIdentityFile { dict["sshIdentityFile"] = sshIdentityFile }
            if let startDirectory { dict["startDirectory"] = startDirectory }
            return dict
        }
    }

    /// Sandbox configuration.
    ///
    /// Sent to the CLI via `applyFlagSettings`; controls filesystem and network isolation for Bash commands.
    public struct Sandbox: DictionarySerializable {
        /// Whether the sandbox is enabled.
        public var enabled: Bool?
        /// Hard-fail when the sandbox is unavailable (default `false` — warn only).
        public var failIfUnavailable: Bool?
        /// Allow the `dangerouslyDisableSandbox` escape (`false` disables it entirely).
        public var allowUnsandboxedCommands: Bool?
        /// Only allow domains configured via managed settings, blocking everything else.
        public var allowManagedDomainsOnly: Bool?
        /// Linux: enable a weakened sandbox inside Docker (significantly less secure).
        public var enableWeakerNestedSandbox: Bool?
        /// Filesystem isolation configuration.
        public var filesystem: Filesystem?
        /// Network isolation configuration.
        public var network: Network?
        /// Command patterns excluded from the sandbox (e.g. `"docker *"`).
        public var excludedCommands: [String]?
        /// Unix socket paths allowed inside the sandbox.
        public var allowUnixSockets: [String]?

        public init(
            enabled: Bool? = nil,
            failIfUnavailable: Bool? = nil,
            allowUnsandboxedCommands: Bool? = nil,
            allowManagedDomainsOnly: Bool? = nil,
            enableWeakerNestedSandbox: Bool? = nil,
            filesystem: Filesystem? = nil,
            network: Network? = nil,
            excludedCommands: [String]? = nil,
            allowUnixSockets: [String]? = nil
        ) {
            self.enabled = enabled
            self.failIfUnavailable = failIfUnavailable
            self.allowUnsandboxedCommands = allowUnsandboxedCommands
            self.allowManagedDomainsOnly = allowManagedDomainsOnly
            self.enableWeakerNestedSandbox = enableWeakerNestedSandbox
            self.filesystem = filesystem
            self.network = network
            self.excludedCommands = excludedCommands
            self.allowUnixSockets = allowUnixSockets
        }

        public func toDictionary() -> [String: Any] {
            var dict: [String: Any] = [:]
            if let enabled { dict["enabled"] = enabled }
            if let failIfUnavailable { dict["failIfUnavailable"] = failIfUnavailable }
            if let allowUnsandboxedCommands { dict["allowUnsandboxedCommands"] = allowUnsandboxedCommands }
            if let allowManagedDomainsOnly { dict["allowManagedDomainsOnly"] = allowManagedDomainsOnly }
            if let enableWeakerNestedSandbox { dict["enableWeakerNestedSandbox"] = enableWeakerNestedSandbox }
            if let filesystem { dict["filesystem"] = filesystem.toDictionary() }
            if let network { dict["network"] = network.toDictionary() }
            if let excludedCommands { dict["excludedCommands"] = excludedCommands }
            if let allowUnixSockets { dict["allowUnixSockets"] = allowUnixSockets }
            return dict
        }

        /// Filesystem isolation configuration.
        ///
        /// Path prefix rules:
        /// - `/path` -> absolute path (e.g. `/tmp/build`)
        /// - `~/path` -> relative to the home directory (e.g. `~/.kube`)
        /// - `./path` or no prefix -> relative to the project root (project settings) or `~/.claude` (user settings)
        ///
        /// Path arrays from multiple scopes are **merged**, not overridden.
        public struct Filesystem: DictionarySerializable {
            /// Additional paths permitted for writes.
            public var allowWrite: [String]?
            /// Paths denied for writes.
            public var denyWrite: [String]?
            /// Paths denied for reads.
            public var denyRead: [String]?
            /// Paths re-allowed for reads inside a `denyRead` region.
            public var allowRead: [String]?
            /// Only honor `allowRead` from managed settings (ignore the user/project/local entries).
            public var allowManagedReadPathsOnly: Bool?

            public init(
                allowWrite: [String]? = nil,
                denyWrite: [String]? = nil,
                denyRead: [String]? = nil,
                allowRead: [String]? = nil,
                allowManagedReadPathsOnly: Bool? = nil
            ) {
                self.allowWrite = allowWrite
                self.denyWrite = denyWrite
                self.denyRead = denyRead
                self.allowRead = allowRead
                self.allowManagedReadPathsOnly = allowManagedReadPathsOnly
            }

            public func toDictionary() -> [String: Any] {
                var dict: [String: Any] = [:]
                if let allowWrite { dict["allowWrite"] = allowWrite }
                if let denyWrite { dict["denyWrite"] = denyWrite }
                if let denyRead { dict["denyRead"] = denyRead }
                if let allowRead { dict["allowRead"] = allowRead }
                if let allowManagedReadPathsOnly { dict["allowManagedReadPathsOnly"] = allowManagedReadPathsOnly }
                return dict
            }
        }

        /// Network isolation configuration.
        public struct Network: DictionarySerializable {
            /// Allowed domains (supports `*` wildcards, e.g. `"*.example.com"`).
            public var allowedDomains: [String]?
            /// Custom HTTP proxy port.
            public var httpProxyPort: Int?
            /// Custom SOCKS proxy port.
            public var socksProxyPort: Int?

            public init(
                allowedDomains: [String]? = nil,
                httpProxyPort: Int? = nil,
                socksProxyPort: Int? = nil
            ) {
                self.allowedDomains = allowedDomains
                self.httpProxyPort = httpProxyPort
                self.socksProxyPort = socksProxyPort
            }

            public func toDictionary() -> [String: Any] {
                var dict: [String: Any] = [:]
                if let allowedDomains { dict["allowedDomains"] = allowedDomains }
                if let httpProxyPort { dict["httpProxyPort"] = httpProxyPort }
                if let socksProxyPort { dict["socksProxyPort"] = socksProxyPort }
                return dict
            }
        }
    }

    /// Entry in the channel plugin allowlist.
    public struct ChannelPlugin: DictionarySerializable {
        public var marketplace: String
        public var plugin: String

        public init(marketplace: String, plugin: String) {
            self.marketplace = marketplace
            self.plugin = plugin
        }

        public func toDictionary() -> [String: Any] {
            ["marketplace": marketplace, "plugin": plugin]
        }
    }
}

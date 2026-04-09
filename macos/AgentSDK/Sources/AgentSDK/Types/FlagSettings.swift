import Foundation

// MARK: - Removable: 三态值包装

/// 表示一个可设置、可清除、或不传的字段。
///
/// - `unset`: 不参与序列化（字段不出现在 JSON 中）
/// - `clear`: 序列化为 JSON `null`（CLI 侧将该字段从 flag settings 中删除）
/// - `set(T)`: 序列化为具体值
public enum Removable<T> {
    case unset
    case clear
    case set(T)

    /// 将值转换为可序列化的 `Any?`。返回 `nil` 表示跳过该字段。
    func serialized(_ transform: (T) -> Any) -> Any? {
        switch self {
        case .unset: return nil
        case .clear: return NSNull()
        case .set(let value): return transform(value)
        }
    }

    /// 便捷方法：值本身可直接作为 JSON 值的类型。
    func serialized() -> Any? where T: JSONSerializableValue {
        serialized { $0.jsonValue }
    }
}

/// 可直接序列化为 JSON 值的类型。
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

/// 可序列化为 `[String: Any]` 的类型。
protocol DictionarySerializable {
    func toDictionary() -> [String: Any]
}

extension DictionarySerializable {
    var jsonValue: Any { toDictionary() }
}

// MARK: - FlagSettings

/// 类型安全的 flag settings 构建器，对应 CLI 的 `apply_flag_settings` 协议。
///
/// 所有字段默认为 `.unset`（不参与序列化）。设置 `.clear` 将在 CLI 侧删除对应字段。
///
/// ```swift
/// var settings = FlagSettings()
/// settings.effortLevel = .set(.high)
/// settings.fastMode = .set(true)
/// settings.language = .set("zh-CN")
/// session.applyFlagSettings(settings)
/// ```
public struct FlagSettings: DictionarySerializable {

    // MARK: 模型 & 推理

    /// 覆盖默认模型。设置后额外调用 `setMainLoopModelOverride()`。
    public var model: Removable<String> = .unset

    /// 可选模型白名单。支持 family alias ("opus")、version prefix ("opus-4-5")、full model ID。
    public var availableModels: Removable<[String]> = .unset

    /// 模型 ID 映射（如 Anthropic model ID → Bedrock ARN）。
    public var modelOverrides: Removable<[String: String]> = .unset

    /// 服务端 advisor tool 使用的模型。
    public var advisorModel: Removable<String> = .unset

    /// 推理 effort 级别。`max` 仅对 ant 用户可用。
    public var effortLevel: Removable<Effort> = .unset

    /// 是否启用 thinking。`false` 禁用 thinking，默认 `true`。
    public var alwaysThinkingEnabled: Removable<Bool> = .unset

    /// 快速模式。
    public var fastMode: Removable<Bool> = .unset

    /// fast mode 不跨 session 持久化。
    public var fastModePerSessionOptIn: Removable<Bool> = .unset

    // MARK: 认证 & 凭证

    /// 输出认证值的脚本路径。
    public var apiKeyHelper: Removable<String> = .unset

    /// 导出 AWS 凭证的脚本路径。
    public var awsCredentialExport: Removable<String> = .unset

    /// 刷新 AWS 认证的脚本路径。
    public var awsAuthRefresh: Removable<String> = .unset

    /// 刷新 GCP 认证的命令。
    public var gcpAuthRefresh: Removable<String> = .unset

    /// 强制登录方式。
    public var forceLoginMethod: Removable<LoginMethod> = .unset

    /// OAuth 登录的组织 UUID。
    public var forceLoginOrgUUID: Removable<String> = .unset

    // MARK: 权限 & 安全

    /// 工具使用权限配置。
    public var permissions: Removable<Permissions> = .unset

    /// 仅使用 managed 权限规则。
    public var allowManagedPermissionRulesOnly: Removable<Bool> = .unset

    /// 跳过 bypass 模式确认。
    public var skipDangerousModePermissionPrompt: Removable<Bool> = .unset

    /// 禁用 auto mode。设置为 `true` 传 `"disable"`。
    public var disableAutoMode: Removable<Bool> = .unset

    // MARK: MCP 服务器

    /// 自动批准项目所有 MCP 服务器。
    public var enableAllProjectMcpServers: Removable<Bool> = .unset

    /// 已批准的 .mcp.json 服务器。
    public var enabledMcpjsonServers: Removable<[String]> = .unset

    /// 已拒绝的 .mcp.json 服务器。
    public var disabledMcpjsonServers: Removable<[String]> = .unset

    /// MCP 服务器白名单。
    public var allowedMcpServers: Removable<[McpServerEntry]> = .unset

    /// MCP 服务器黑名单。
    public var deniedMcpServers: Removable<[McpServerEntry]> = .unset

    /// 仅从 managed settings 读取 MCP 白名单。
    public var allowManagedMcpServersOnly: Removable<Bool> = .unset

    // MARK: Hooks & 自定义

    /// 工具执行前后的自定义命令。JSON 结构: `Record<eventName, HookMatcher[]>`。
    public var hooks: Removable<[String: Any]> = .unset

    /// 禁用所有 hooks 和 statusLine。
    public var disableAllHooks: Removable<Bool> = .unset

    /// 仅允许 managed hooks。
    public var allowManagedHooksOnly: Removable<Bool> = .unset

    /// HTTP hook URL 白名单（支持 `*` 通配符）。
    public var allowedHttpHookUrls: Removable<[String]> = .unset

    /// HTTP hook 可用的环境变量白名单。
    public var httpHookAllowedEnvVars: Removable<[String]> = .unset

    /// 自定义状态栏。
    public var statusLine: Removable<StatusLine> = .unset

    /// 仅允许插件定制。`true` 锁全部，指定数组锁特定表面。
    public var strictPluginOnlyCustomization: Removable<PluginCustomization> = .unset

    // MARK: UI & 输出

    /// 助手响应输出样式。
    public var outputStyle: Removable<String> = .unset

    /// 偏好语言。
    public var language: Removable<String> = .unset

    /// 禁用语法高亮。
    public var syntaxHighlightingDisabled: Removable<Bool> = .unset

    /// 显示 spinner tips。
    public var spinnerTipsEnabled: Removable<Bool> = .unset

    /// 自定义 spinner 动词。
    public var spinnerVerbs: Removable<SpinnerVerbs> = .unset

    /// 覆盖 spinner tips。
    public var spinnerTipsOverride: Removable<SpinnerTipsOverride> = .unset

    /// 减少动画。
    public var prefersReducedMotion: Removable<Bool> = .unset

    /// 显示 thinking 摘要。默认 `false`。
    public var showThinkingSummaries: Removable<Bool> = .unset

    /// 提示建议。
    public var promptSuggestionEnabled: Removable<Bool> = .unset

    /// `/rename` 更新终端标题。默认 `true`。
    public var terminalTitleFromRename: Removable<Bool> = .unset

    // MARK: 插件 & Marketplace

    /// 启用的插件。key 格式: `"plugin-id@marketplace-id"`。
    /// value: `true`/`false` 或字符串数组。
    public var enabledPlugins: Removable<[String: Any]> = .unset

    /// 额外 marketplace。
    public var extraKnownMarketplaces: Removable<[String: ExtraKnownMarketplace]> = .unset

    /// 企业 marketplace 白名单。
    public var strictKnownMarketplaces: Removable<[[String: Any]]> = .unset

    /// 企业 marketplace 黑名单。
    public var blockedMarketplaces: Removable<[[String: Any]]> = .unset

    /// 插件配置。
    public var pluginConfigs: Removable<[String: Any]> = .unset

    /// 插件信任警告自定义消息（仅从 policy settings 读取）。
    public var pluginTrustMessage: Removable<String> = .unset

    // MARK: Git & 项目

    /// commit/PR 归属文本。
    public var attribution: Removable<Attribution> = .unset

    /// (已废弃) co-authored-by 归属。用 `attribution` 替代。
    public var includeCoAuthoredBy: Removable<Bool> = .unset

    /// 系统提示包含 git 指令。默认 `true`。
    public var includeGitInstructions: Removable<Bool> = .unset

    /// worktree 配置。
    public var worktree: Removable<Worktree> = .unset

    /// 计划文件自定义目录（相对项目根目录）。
    public var plansDirectory: Removable<String> = .unset

    // MARK: 其他

    /// 环境变量。
    public var env: Removable<[String: String]> = .unset

    /// `@` 提及自定义文件建议命令。
    public var fileSuggestion: Removable<FileSuggestion> = .unset

    /// 文件选择器是否遵循 .gitignore。默认 `true`。
    public var respectGitignore: Removable<Bool> = .unset

    /// 聊天记录保留天数。`0` = 禁用持久化。默认 `30`。
    public var cleanupPeriodDays: Removable<Int> = .unset

    /// 默认 shell。
    public var defaultShell: Removable<Shell> = .unset

    /// 沙箱配置。
    public var sandbox: Removable<Sandbox> = .unset

    /// 跳过 WebFetch 黑名单检查。
    public var skipWebFetchPreflight: Removable<Bool> = .unset

    /// 调查问卷出现概率（0-1）。
    public var feedbackSurveyRate: Removable<Double> = .unset

    /// 自动更新渠道。
    public var autoUpdatesChannel: Removable<UpdateChannel> = .unset

    /// 最低版本（防降级）。
    public var minimumVersion: Removable<String> = .unset

    /// 主线程使用的 agent 名称。
    public var agent: Removable<String> = .unset

    /// 启动时显示的公司公告。
    public var companyAnnouncements: Removable<[String]> = .unset

    /// 远程会话配置。
    public var remote: Removable<Remote> = .unset

    /// SSH 连接配置。
    public var sshConfigs: Removable<[SSHConfig]> = .unset

    /// 排除的 CLAUDE.md 文件 glob。
    public var claudeMdExcludes: Removable<[String]> = .unset

    /// 启用 auto-memory。
    public var autoMemoryEnabled: Removable<Bool> = .unset

    /// auto-memory 目录（支持 `~/` 前缀）。
    public var autoMemoryDirectory: Removable<String> = .unset

    /// 后台记忆整合。
    public var autoDreamEnabled: Removable<Bool> = .unset

    /// plan 审批时显示"清除上下文"选项。
    public var showClearContextOnPlanAccept: Removable<Bool> = .unset

    /// 启用 channel 通知。
    public var channelsEnabled: Removable<Bool> = .unset

    /// channel 插件白名单。
    public var allowedChannelPlugins: Removable<[ChannelPlugin]> = .unset

    public init() {}

    // MARK: - Serialization

    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [:]

        func add(_ key: String, _ value: Any?) {
            if let value { dict[key] = value }
        }

        // 模型 & 推理
        add("model", model.serialized())
        add("availableModels", availableModels.serialized())
        add("modelOverrides", modelOverrides.serialized())
        add("advisorModel", advisorModel.serialized())
        add("effortLevel", effortLevel.serialized { $0.rawValue })
        add("alwaysThinkingEnabled", alwaysThinkingEnabled.serialized())
        add("fastMode", fastMode.serialized())
        add("fastModePerSessionOptIn", fastModePerSessionOptIn.serialized())

        // 认证 & 凭证
        add("apiKeyHelper", apiKeyHelper.serialized())
        add("awsCredentialExport", awsCredentialExport.serialized())
        add("awsAuthRefresh", awsAuthRefresh.serialized())
        add("gcpAuthRefresh", gcpAuthRefresh.serialized())
        add("forceLoginMethod", forceLoginMethod.serialized { $0.rawValue })
        add("forceLoginOrgUUID", forceLoginOrgUUID.serialized())

        // 权限 & 安全
        add("permissions", permissions.serialized { $0.toDictionary() })
        add("allowManagedPermissionRulesOnly", allowManagedPermissionRulesOnly.serialized())
        add("skipDangerousModePermissionPrompt", skipDangerousModePermissionPrompt.serialized())
        add("disableAutoMode", disableAutoMode.serialized { $0 ? "disable" as Any : NSNull() as Any })

        // MCP 服务器
        add("enableAllProjectMcpServers", enableAllProjectMcpServers.serialized())
        add("enabledMcpjsonServers", enabledMcpjsonServers.serialized())
        add("disabledMcpjsonServers", disabledMcpjsonServers.serialized())
        add("allowedMcpServers", allowedMcpServers.serialized { $0.map { $0.toDictionary() } })
        add("deniedMcpServers", deniedMcpServers.serialized { $0.map { $0.toDictionary() } })
        add("allowManagedMcpServersOnly", allowManagedMcpServersOnly.serialized())

        // Hooks & 自定义
        add("hooks", hooks.serialized { $0 })
        add("disableAllHooks", disableAllHooks.serialized())
        add("allowManagedHooksOnly", allowManagedHooksOnly.serialized())
        add("allowedHttpHookUrls", allowedHttpHookUrls.serialized())
        add("httpHookAllowedEnvVars", httpHookAllowedEnvVars.serialized())
        add("statusLine", statusLine.serialized { $0.toDictionary() })
        add("strictPluginOnlyCustomization", strictPluginOnlyCustomization.serialized { $0.jsonValue })

        // UI & 输出
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

        // 插件 & Marketplace
        add("enabledPlugins", enabledPlugins.serialized { $0 })
        add("extraKnownMarketplaces", extraKnownMarketplaces.serialized { dict in
            dict.mapValues { $0.toDictionary() }
        })
        add("strictKnownMarketplaces", strictKnownMarketplaces.serialized { $0 })
        add("blockedMarketplaces", blockedMarketplaces.serialized { $0 })
        add("pluginConfigs", pluginConfigs.serialized { $0 })
        add("pluginTrustMessage", pluginTrustMessage.serialized())

        // Git & 项目
        add("attribution", attribution.serialized { $0.toDictionary() })
        add("includeCoAuthoredBy", includeCoAuthoredBy.serialized())
        add("includeGitInstructions", includeGitInstructions.serialized())
        add("worktree", worktree.serialized { $0.toDictionary() })
        add("plansDirectory", plansDirectory.serialized())

        // 其他
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

// MARK: - Enums

extension FlagSettings {

    /// 登录方式。
    public enum LoginMethod: String {
        case claudeai
        case console
    }

    /// 默认 shell。
    public enum Shell: String {
        case bash
        case powershell
    }

    /// 自动更新渠道。
    public enum UpdateChannel: String {
        case latest
        case stable
    }

    /// 插件定制锁定范围。
    public enum PluginCustomization {
        /// 锁定全部定制表面。
        case all
        /// 锁定指定表面。
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

    /// 权限配置。
    public struct Permissions: DictionarySerializable {
        /// 允许的操作规则。
        public var allow: [[String: Any]]?
        /// 拒绝的操作规则。
        public var deny: [[String: Any]]?
        /// 需要确认的操作规则。
        public var ask: [[String: Any]]?
        /// 默认权限模式。
        public var defaultMode: String?
        /// 禁用 bypass permissions 模式。设置 `"disable"` 禁用。
        public var disableBypassPermissionsMode: String?
        /// 禁用 auto mode。设置 `"disable"` 禁用。
        public var disableAutoMode: String?
        /// 额外工作目录。
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

    /// MCP 服务器条目（serverName / serverCommand / serverUrl 三选一）。
    public struct McpServerEntry: DictionarySerializable {
        public var serverName: String?
        public var serverCommand: [String]?
        public var serverUrl: String?

        /// 按服务器名称匹配。
        public static func name(_ name: String) -> McpServerEntry {
            McpServerEntry(serverName: name)
        }

        /// 按启动命令匹配。
        public static func command(_ command: [String]) -> McpServerEntry {
            McpServerEntry(serverCommand: command)
        }

        /// 按 URL 匹配。
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

    /// 自定义状态栏。
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

    /// 自定义 spinner 动词。
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

    /// 覆盖 spinner tips。
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

    /// Git 归属配置。
    public struct Attribution: DictionarySerializable {
        /// commit 归属文本。空字符串隐藏归属。
        public var commit: String?
        /// PR 归属文本。
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

    /// Worktree 配置。
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

    /// `@` 提及自定义文件建议命令。
    public struct FileSuggestion: DictionarySerializable {
        public var command: String

        public init(command: String) {
            self.command = command
        }

        public func toDictionary() -> [String: Any] {
            ["type": "command", "command": command]
        }
    }

    /// 额外 marketplace 配置。
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

    /// 远程会话配置。
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

    /// SSH 连接配置。
    public struct SSHConfig: DictionarySerializable {
        public var id: String
        public var name: String
        /// `"user@hostname"` 或 `~/.ssh/config` 中的 host alias。
        public var sshHost: String
        /// SSH 端口，默认 22。
        public var sshPort: Int?
        /// SSH 密钥文件路径。
        public var sshIdentityFile: String?
        /// 起始目录（支持 `~/` 展开）。
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

    /// 沙箱配置。
    ///
    /// 通过 `applyFlagSettings` 发送给 CLI，控制 Bash 命令的文件系统和网络隔离。
    public struct Sandbox: DictionarySerializable {
        /// 是否启用沙箱。
        public var enabled: Bool?
        /// 沙箱不可用时是否硬报错（默认 `false`，仅警告）。
        public var failIfUnavailable: Bool?
        /// 是否允许 `dangerouslyDisableSandbox` 逃逸（`false` 则完全禁用）。
        public var allowUnsandboxedCommands: Bool?
        /// 仅允许 managed settings 中配置的域名，阻止其他所有域名。
        public var allowManagedDomainsOnly: Bool?
        /// Linux: 在 Docker 内启用弱化沙箱（显著降低安全性）。
        public var enableWeakerNestedSandbox: Bool?
        /// 文件系统隔离配置。
        public var filesystem: Filesystem?
        /// 网络隔离配置。
        public var network: Network?
        /// 排除在沙箱外运行的命令模式（如 `"docker *"`）。
        public var excludedCommands: [String]?
        /// 允许访问的 Unix socket 路径。
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

        /// 文件系统隔离配置。
        ///
        /// 路径前缀规则：
        /// - `/path` → 绝对路径（如 `/tmp/build`）
        /// - `~/path` → 相对 home 目录（如 `~/.kube`）
        /// - `./path` 或无前缀 → 相对项目根目录（project settings）或 `~/.claude`（user settings）
        ///
        /// 多 scope 的路径数组是**合并**的，不会被覆盖。
        public struct Filesystem: DictionarySerializable {
            /// 额外允许写入的路径。
            public var allowWrite: [String]?
            /// 拒绝写入的路径。
            public var denyWrite: [String]?
            /// 拒绝读取的路径。
            public var denyRead: [String]?
            /// 在 `denyRead` 区域内重新允许读取的路径。
            public var allowRead: [String]?
            /// 仅使用 managed settings 的 `allowRead`（忽略 user/project/local 的 `allowRead`）。
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

        /// 网络隔离配置。
        public struct Network: DictionarySerializable {
            /// 允许访问的域名（支持 `*` 通配符，如 `"*.example.com"`）。
            public var allowedDomains: [String]?
            /// 自定义 HTTP 代理端口。
            public var httpProxyPort: Int?
            /// 自定义 SOCKS 代理端口。
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

    /// Channel 插件白名单条目。
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

import Foundation

// MARK: - Permission Suggestion

public enum PermissionSuggestion: JSONParseable, UnknownStrippable {
    case addRules(AddRulesSuggestion)
    case setMode(SetModeSuggestion)
    case addDirectories(AddDirectoriesSuggestion)
    case unknown(name: String, raw: [String: Any])

    public init(json: Any) throws {
        guard let dict = json as? [String: Any],
              let tag = dict["type"] as? String else {
            self = .unknown(name: "unknown", raw: [:])
            return
        }
        switch tag {
        case "addRules": self = .addRules(try _jp(dict))
        case "setMode": self = .setMode(try _jp(dict))
        case "addDirectories": self = .addDirectories(try _jp(dict))
        default: self = .unknown(name: tag, raw: dict)
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .addRules(let v): return v.toJSON()
        case .setMode(let v): return v.toJSON()
        case .addDirectories(let v): return v.toJSON()
        case .unknown(_, let raw): return raw
        }
    }

    public func strippingUnknown() -> PermissionSuggestion? {
        if case .unknown = self { return nil }
        return self
    }
}

public struct AddRulesSuggestion: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let rules: [PermissionRule]
    public let behavior: String
    public let destination: String

    public init(json: Any) throws {
        let r = try JSONReader(json, context: "AddRulesSuggestion")
        self._raw = r.dict
        self.rules = try r.decodeArray("rules")
        self.behavior = try r.need("behavior")
        self.destination = try r.need("destination")
    }

    public func toJSON() -> Any { _raw }
}

public struct SetModeSuggestion: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let mode: String
    public let destination: String

    public init(json: Any) throws {
        let r = try JSONReader(json, context: "SetModeSuggestion")
        self._raw = r.dict
        self.mode = try r.need("mode")
        self.destination = try r.need("destination")
    }

    public func toJSON() -> Any { _raw }
}

public struct AddDirectoriesSuggestion: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let directories: [String]
    public let destination: String

    public init(json: Any) throws {
        let r = try JSONReader(json, context: "AddDirectoriesSuggestion")
        self._raw = r.dict
        self.directories = r.stringArray("directories") ?? []
        self.destination = try r.need("destination")
    }

    public func toJSON() -> Any { _raw }
}

// MARK: - Permission Rule

public struct PermissionRule: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let toolName: String
    public let ruleContent: String?

    public init(json: Any) throws {
        let r = try JSONReader(json, context: "PermissionRule")
        self._raw = r.dict
        self.toolName = try r.need("toolName", alt: "tool_name")
        self.ruleContent = r.string("ruleContent", alt: "rule_content")
    }

    public func toJSON() -> Any { _raw }
}

// MARK: - Decision Reason

/// JSON 中 `decision_reason` 既可以是 dict `{ "type": "...", "reason": "..." }` 也可以是纯 string。
/// 不能用 macro 的原因：`@JSONTagged` 的 `init(json: Any)` 先 cast 到 `[String: Any]`，string 输入会失败。
public enum DecisionReason: JSONParseable, UnknownStrippable {
    case string(String)
    case structured(type: String, reason: String?)

    public init(json: Any) throws {
        if let dict = json as? [String: Any] {
            self = .structured(
                type: dict["type"] as? String ?? "other",
                reason: dict["reason"] as? String
            )
        } else if let str = json as? String {
            self = .string(str)
        } else {
            throw JSONParseError.typeMismatch(expected: "Dict or String", in: "DecisionReason")
        }
    }

    public func toJSON() -> Any {
        switch self {
        case .string(let s):
            return s
        case .structured(let type, let reason):
            var dict: [String: Any] = ["type": type]
            if let reason { dict["reason"] = reason }
            return dict
        }
    }

    /// 便捷属性：无论哪种形态都返回原因文本
    public var reason: String? {
        switch self {
        case .string(let s): return s
        case .structured(_, let r): return r
        }
    }

    public func strippingUnknown() -> DecisionReason? { self }
}

// MARK: - Permission Request

public struct PermissionRequest: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let requestId: String
    public let toolName: String
    public let rawInput: [String: Any]
    public let permissionSuggestions: [PermissionSuggestion]?
    public let blockedPath: String?
    public let decisionReason: DecisionReason?
    public let toolUseId: String?
    public let agentId: String?

    /// 类型化 input，从 rawInput + toolName 解析
    public var toolInput: ToolUse {
        let fakeBlock: [String: Any] = ["name": toolName, "input": rawInput, "id": toolUseId ?? "preview"]
        return (try? ToolUse(json: fakeBlock)) ?? .unknown(name: toolName, raw: rawInput)
    }

    public init(json: Any) throws {
        let r = try JSONReader(json, context: "PermissionRequest")
        self._raw = r.dict
        self.requestId = try r.need("request_id")
        self.toolName = try r.need("tool_name")
        self.rawInput = r.rawDict("input") ?? [:]
        self.permissionSuggestions = try r.decodeArrayIfPresent("permission_suggestions")
        self.blockedPath = r.string("blocked_path")
        self.decisionReason = r.decodeIfPresent("decision_reason")
        self.toolUseId = r.string("tool_use_id")
        self.agentId = r.string("agent_id")
    }

    public func toJSON() -> Any { _raw }
}

// MARK: - PermissionRequest Preview

extension PermissionRequest {
    /// 仅用于 Preview / 测试场景构造 mock 数据。
    public static func makePreview(requestId: String, toolName: String, input: [String: Any]) -> PermissionRequest {
        let dict: [String: Any] = [
            "request_id": requestId,
            "tool_name": toolName,
            "input": input,
        ]
        return try! PermissionRequest(json: dict)
    }
}

// MARK: - PermissionRequest Convenience

extension PermissionRequest {

    private static let toolVerbs: [String: String] = [
        "Bash": "running", "Read": "reading", "Write": "writing to",
        "Edit": "editing", "Glob": "searching", "Grep": "searching",
        "Task": "running task", "ExitPlanMode": "the plan",
    ]

    private static let feedbackTemplate = "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). To tell you how to proceed, the user said:\n"

    /// 场景1: Deny 无反馈 — 自动拼接 "User rejected {verb} {desc}"，interrupt: true。
    public func deny() -> PermissionDecision {
        let verb = Self.toolVerbs[toolName] ?? "using"
        let desc = describeInput()
        let message = desc.isEmpty
            ? "User rejected \(verb)"
            : "User rejected \(verb) \(desc)"
        return .deny(reason: message, interrupt: true)
    }

    /// 场景2: Deny + 用户反馈文字 — 使用 feedback 模板，interrupt: false。
    public func deny(feedback: String) -> PermissionDecision {
        .deny(reason: Self.feedbackTemplate + feedback, interrupt: false)
    }

    /// 场景3: Allow Once — 可选传入用户编辑过的 input。
    public func allowOnce(updatedInput: [String: Any]? = nil) -> PermissionDecision {
        .allow(updatedInput: updatedInput)
    }

    /// 场景4: Allow Always — 可选传入编辑过的 input 和自定义权限规则，默认使用 CLI 建议的 permissionSuggestions。
    public func allowAlways(updatedInput: [String: Any]? = nil, updatedPermissions: [[String: Any]]? = nil) -> PermissionDecision {
        let permissions = updatedPermissions ?? permissionSuggestions?.map { $0.toJSON() as! [String: Any] }
        return .allowAlways(updatedInput: updatedInput, updatedPermissions: permissions)
    }

    private func describeInput() -> String {
        if let v = rawInput["command"] as? String { return "command: \(v)" }
        if let v = rawInput["file_path"] as? String { return "file: \(v)" }
        if let v = rawInput["path"] as? String { return "path: \(v)" }
        if let v = rawInput["pattern"] as? String { return "pattern: \(v)" }
        return ""
    }
}

// MARK: - Hook Request

/// CLI 请求执行 Hook 回调。
public struct HookRequest: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let requestId: String
    public let callbackId: String
    public let input: [String: Any]
    public let toolUseId: String?

    public init(json: Any) throws {
        let r = try JSONReader(json, context: "HookRequest")
        self._raw = r.dict
        self.requestId = try r.need("request_id")
        self.callbackId = try r.need("callback_id")
        self.input = r.rawDict("input") ?? [:]
        self.toolUseId = r.string("tool_use_id")
    }

    public func toJSON() -> Any { _raw }
}

// MARK: - MCP Request

/// CLI 转发 MCP 协议消息。
public struct MCPRequest: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let requestId: String
    public let serverName: String
    public let message: [String: Any]

    public init(json: Any) throws {
        let r = try JSONReader(json, context: "MCPRequest")
        self._raw = r.dict
        self.requestId = try r.need("request_id")
        self.serverName = try r.need("server_name")
        self.message = r.rawDict("message") ?? [:]
    }

    public func toJSON() -> Any { _raw }
}

// MARK: - Elicitation Request

/// CLI 请求用户输入。
public struct ElicitationRequest: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let requestId: String
    public let message: String
    public let requestedSchema: [String: Any]

    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ElicitationRequest")
        self._raw = r.dict
        self.requestId = try r.need("request_id")
        self.message = try r.need("message")
        self.requestedSchema = r.rawDict("requested_schema") ?? [:]
    }

    public func toJSON() -> Any { _raw }
}

// MARK: - Initialize Response

/// `initialize` control_response 的 `response.response` 部分。
public struct InitializeResponse: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let commands: [SlashCommandInfo]?
    public let agents: [AgentInfo]?
    public let models: [ModelInfo]?
    public let account: AccountInfo?
    public let outputStyle: String?
    public let availableOutputStyles: [String]?
    public let pid: Int?

    public init(json: Any) throws {
        let r = try JSONReader(json, context: "InitializeResponse")
        self._raw = r.dict
        self.commands = try r.decodeArrayIfPresent("commands")
        self.agents = try r.decodeArrayIfPresent("agents")
        self.models = try r.decodeArrayIfPresent("models")
        self.account = r.decodeIfPresent("account")
        self.outputStyle = r.string("output_style")
        self.availableOutputStyles = r.stringArray("available_output_styles")
        self.pid = r.int("pid")
    }

    public func toJSON() -> Any { _raw }
}

public struct SlashCommandInfo: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let name: String
    public let description: String?
    public let argumentHint: String?

    public init(json: Any) throws {
        let r = try JSONReader(json, context: "SlashCommandInfo")
        self._raw = r.dict
        self.name = try r.need("name")
        self.description = r.string("description")
        self.argumentHint = r.string("argumentHint")
    }

    public func toJSON() -> Any { _raw }
}

public struct AgentInfo: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let name: String
    public let description: String?
    public let model: String?

    public init(json: Any) throws {
        let r = try JSONReader(json, context: "AgentInfo")
        self._raw = r.dict
        self.name = try r.need("name")
        self.description = r.string("description")
        self.model = r.string("model")
    }

    public func toJSON() -> Any { _raw }
}

public struct ModelInfo: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let value: String
    public let displayName: String
    public let description: String?
    public let supportsEffort: Bool?
    public let supportedEffortLevels: [String]?
    public let supportsAdaptiveThinking: Bool?
    public let supportsFastMode: Bool?
    public let supportsAutoMode: Bool?

    public init(json: Any) throws {
        let r = try JSONReader(json, context: "ModelInfo")
        self._raw = r.dict
        self.value = try r.need("value")
        self.displayName = try r.need("displayName")
        self.description = r.string("description")
        self.supportsEffort = r.bool("supportsEffort")
        self.supportedEffortLevels = r.stringArray("supportedEffortLevels")
        self.supportsAdaptiveThinking = r.bool("supportsAdaptiveThinking")
        self.supportsFastMode = r.bool("supportsFastMode")
        self.supportsAutoMode = r.bool("supportsAutoMode")
    }

    public func toJSON() -> Any { _raw }
}

public struct AccountInfo: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let email: String
    public let organization: String?
    public let subscriptionType: String?
    public let apiProvider: String?

    public init(json: Any) throws {
        let r = try JSONReader(json, context: "AccountInfo")
        self._raw = r.dict
        self.email = try r.need("email")
        self.organization = r.string("organization")
        self.subscriptionType = r.string("subscriptionType")
        self.apiProvider = r.string("apiProvider")
    }

    public func toJSON() -> Any { _raw }
}

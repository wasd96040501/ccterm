import Foundation

/// 一次性 prompt 配置。对应 `claude -p` 模式。
public struct PromptConfiguration {
    /// CLI 工作目录。对应 `--cwd`。
    public var workingDirectory: URL

    /// 模型名称。对应 `--model`。
    public var model: String?

    /// 系统提示。对应 `--system-prompt`。
    public var systemPrompt: String?

    /// 工具列表。空数组 = `--tools ''`（禁用所有工具）。nil = CLI 默认。
    public var tools: [String]?

    /// 结构化输出 JSON Schema 字符串。对应 `--json-schema`。
    public var jsonSchema: String?

    /// claude 二进制路径。nil 自动查找。
    public var binaryPath: String?

    /// 额外环境变量。
    public var env: [String: String]

    /// 用户自定义命令前缀，如 "trae-proxy claude --"。非空时替代默认 claude 二进制。
    public var customCommand: String?

    /// 禁用斜杠命令解析。对应 `--disable-slash-commands`。
    public var disableSlashCommands: Bool

    /// 推理投入等级。对应 `--effort`。
    public var effort: String?

    public init(
        workingDirectory: URL,
        model: String? = nil,
        systemPrompt: String? = nil,
        tools: [String]? = nil,
        jsonSchema: String? = nil,
        binaryPath: String? = nil,
        env: [String: String] = [:],
        customCommand: String? = nil,
        disableSlashCommands: Bool = false,
        effort: String? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.model = model
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.jsonSchema = jsonSchema
        self.binaryPath = binaryPath
        self.env = env
        self.customCommand = customCommand
        self.disableSlashCommands = disableSlashCommands
        self.effort = effort
    }
}

import Foundation

/// One-shot prompt configuration. Drives `claude -p` mode.
public struct PromptConfiguration {
    /// CLI working directory. Maps to `--cwd`.
    public var workingDirectory: URL

    /// Maps to `--model`.
    public var model: String?

    /// Maps to `--system-prompt`.
    public var systemPrompt: String?

    /// Tool list. Empty array = `--tools ''` (disables all tools); nil = CLI default.
    public var tools: [String]?

    /// Structured-output JSON Schema string. Maps to `--json-schema`.
    public var jsonSchema: String?

    /// Path to the `claude` binary. nil = auto-locate.
    public var binaryPath: String?

    /// Extra environment variables.
    public var env: [String: String]

    /// Custom command prefix, e.g. `"trae-proxy claude --"`. When non-empty, replaces the default `claude` binary.
    public var customCommand: String?

    /// Maps to `--disable-slash-commands`.
    public var disableSlashCommands: Bool

    /// Reasoning effort level. Maps to `--effort`.
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

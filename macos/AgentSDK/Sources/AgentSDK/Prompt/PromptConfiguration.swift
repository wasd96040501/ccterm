import Foundation

/// Launch options for ``Prompt/run(_:configuration:)``.
public struct PromptConfiguration: Sendable {
    public var workingDirectory: URL
    /// `--model`; `nil` uses the CLI default.
    public var model: String?
    /// Replaces the default system prompt (`--system-prompt`).
    public var systemPrompt: String?
    /// The tools the model may use; empty disables all tools, `nil` keeps
    /// the default set (`--tools`).
    public var tools: [String]?
    /// JSON Schema the answer must match; it arrives as
    /// ``ResultMessage/structuredOutput`` (`--json-schema`).
    public var jsonSchema: JSONValue?
    /// `--effort`.
    public var effort: Effort?
    /// Settings layered above user, project and local settings (`--settings`).
    public var settings: Settings
    /// `--disable-slash-commands`.
    public var disableSlashCommands: Bool
    /// Terminates the CLI after this many seconds.
    public var timeout: TimeInterval?
    /// Path to the `claude` binary; `nil` locates it.
    public var binaryPath: String?
    /// A command that replaces the binary, run through the login shell
    /// (e.g. `"my-proxy claude --"`).
    public var customCommand: String?
    /// Extra environment variables.
    public var env: [String: String]
    /// Use this process's environment instead of probing the login shell.
    public var inheritsParentEnvironment: Bool

    public init(
        workingDirectory: URL, model: String? = nil, systemPrompt: String? = nil, tools: [String]? = nil,
        jsonSchema: JSONValue? = nil, effort: Effort? = nil, settings: Settings = Settings(),
        disableSlashCommands: Bool = false, timeout: TimeInterval? = nil, binaryPath: String? = nil,
        customCommand: String? = nil, env: [String: String] = [:], inheritsParentEnvironment: Bool = false
    ) {
        self.workingDirectory = workingDirectory
        self.model = model
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.jsonSchema = jsonSchema
        self.effort = effort
        self.settings = settings
        self.disableSlashCommands = disableSlashCommands
        self.timeout = timeout
        self.binaryPath = binaryPath
        self.customCommand = customCommand
        self.env = env
        self.inheritsParentEnvironment = inheritsParentEnvironment
    }

    /// How to start the CLI for `message`. Blocking (the login-shell
    /// environment probe).
    func launch(message: String) throws -> CLILaunch {
        try CLILaunch(
            arguments: arguments(message: message), workingDirectory: workingDirectory, binaryPath: binaryPath,
            customCommand: customCommand, env: env, inheritsParentEnvironment: inheritsParentEnvironment)
    }

    /// The CLI command line for a one-shot run of `message`.
    func arguments(message: String) -> [String] {
        var args = ["-p", "--output-format", "json", "--no-session-persistence"]
        if let model { args += ["--model", model] }
        if let systemPrompt { args += ["--system-prompt", systemPrompt] }
        if let tools { args += ["--tools", tools.joined(separator: ",")] }
        if let jsonSchema, let data = try? JSONEncoder().encode(jsonSchema) {
            args += ["--json-schema", String(decoding: data, as: UTF8.self)]
        }
        if let effort { args += ["--effort", effort.rawValue] }
        if let settings = settings.launchArgument { args += ["--settings", settings] }
        if disableSlashCommands { args += ["--disable-slash-commands"] }
        return args + ["--", message]
    }
}

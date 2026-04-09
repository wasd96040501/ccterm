import Foundation

public struct Init: JSONParseable, UnknownStrippable {
    public let _raw: [String: Any]
    public let agents: [String]?
    public let apiKeySource: String?
    public let claudeCodeVersion: String?
    public let cwd: String?
    public let fastModeState: String?
    public let mcpServers: [McpServers]?
    public let model: String?
    public let outputStyle: String?
    public let permissionMode: String?
    public let plugins: [Plugins]?
    public let sessionId: String?
    public let skills: [String]?
    public let slashCommands: [String]?
    public let tools: [String]?
    public let uuid: String?
}

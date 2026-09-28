import Foundation

// MCP server approval for the project's `.mcp.json`.

extension SettingsKey where Value == Bool {
    /// Approves every server in the project's `.mcp.json`.
    public static var enableAllProjectMCPServers: Self { Self("enableAllProjectMcpServers") }
}

extension SettingsKey where Value == [String] {
    /// Approved servers from the project's `.mcp.json`, by name.
    public static var enabledMCPJSONServers: Self { Self("enabledMcpjsonServers") }

    /// Rejected servers from the project's `.mcp.json`, by name.
    public static var disabledMCPJSONServers: Self { Self("disabledMcpjsonServers") }
}

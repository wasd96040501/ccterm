import Foundation

/// Response to an MCP message.
public enum MCPResponse {
    case success(response: [String: Any]? = nil)
    case error(message: String)
}

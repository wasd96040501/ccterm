import Foundation

/// MCP 消息的响应结果。
public enum MCPResponse {
    case success(response: [String: Any]? = nil)
    case error(message: String)
}

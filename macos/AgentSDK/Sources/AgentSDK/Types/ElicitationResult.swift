import Foundation

/// Elicitation 请求的响应结果。
public enum ElicitationResult {
    case respond(data: [String: Any])
    case cancel
}

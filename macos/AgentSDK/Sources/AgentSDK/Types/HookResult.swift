import Foundation

/// Hook 回调的返回结果。
public enum HookResult {
    case success(output: [String: Any]? = nil)
    case error(message: String)
}

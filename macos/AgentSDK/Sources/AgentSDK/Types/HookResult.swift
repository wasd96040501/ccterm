import Foundation

/// Return value from a hook callback.
public enum HookResult {
    case success(output: [String: Any]? = nil)
    case error(message: String)
}

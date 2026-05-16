import Foundation

/// Response to an `apply_flag_settings` control request.
public enum FlagSettingsResponse {
    case success
    case error(String)

    /// Parses the raw `response` dictionary returned by the CLI.
    init(_ response: [String: Any]) {
        let subtype = response["subtype"] as? String
        if subtype == "error", let message = response["error"] as? String {
            self = .error(message)
        } else {
            self = .success
        }
    }

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    /// Error message; nil on success.
    public var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }
}

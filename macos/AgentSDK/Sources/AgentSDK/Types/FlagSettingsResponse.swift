import Foundation

/// `apply_flag_settings` 控制请求的响应。
public enum FlagSettingsResponse {
    /// 设置已成功应用。
    case success
    /// 设置应用失败。
    case error(String)

    /// 从 CLI 返回的原始 response 字典解析。
    init(_ response: [String: Any]) {
        let subtype = response["subtype"] as? String
        if subtype == "error", let message = response["error"] as? String {
            self = .error(message)
        } else {
            self = .success
        }
    }

    /// 是否成功。
    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    /// 错误信息（成功时为 nil）。
    public var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }
}

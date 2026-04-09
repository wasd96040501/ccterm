import Foundation

/// 权限请求的决策结果。
public enum PermissionDecision {
    /// 允许本次工具调用，可选修改输入。
    case allow(updatedInput: [String: Any]? = nil)
    /// 允许并记住规则（自动应用 permissionSuggestions），可选修改输入和自定义权限更新。
    case allowAlways(updatedInput: [String: Any]? = nil, updatedPermissions: [[String: Any]]? = nil)
    /// 拒绝本次工具调用，附带原因。interrupt 为 true 时中断当前执行。
    case deny(reason: String = "", interrupt: Bool = false)
}

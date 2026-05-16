import AgentSDK
import Foundation

/// CLI 发来的待决策权限请求。包含请求内容和响应闭包。
/// UI 展示请求内容，用户决策后调用 respond 闭包，自动回调 CLI 并从列表中移除。
struct PendingPermission: Identifiable {
    let id: String
    let request: PermissionRequest
    /// 调用此闭包响应 CLI。闭包内部会自动从 pendingPermissions 中移除本条。
    let respond: (PermissionDecision) -> Void
}

/// CLI initialize 阶段宣告的可用 slash 指令。
struct SlashCommand {
    let name: String
    let description: String?
}

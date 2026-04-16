import Foundation
import AgentSDK

// MARK: - Value Types

/// 工作区：cwd + 是否 worktree。始终一起变化，一起读取。
struct Workspace: Equatable {
    var cwd: String
    var isWorktree: Bool
}

/// 上下文用量。window == 0 时视为未就绪（首条 assistant 消息之前）。
struct ContextUsage: Equatable {
    var used: Int
    var window: Int

    var percent: Double {
        guard window > 0 else { return 0 }
        return Double(used) / Double(window) * 100
    }
}

// MARK: - Backend Protocols

/// CLI 后端协议。生产环境由 AgentSDK.Session 实现，测试环境可注入 fake。
protocol SessionBackend: AnyObject {
    func sendMessage(_ text: String, extra: [String: Any])
    func interrupt(completion: @escaping (Bool) -> Void)
    func setModel(_ model: String)
    func setEffort(_ effort: Effort)
    func setPermissionMode(_ mode: AgentSDK.PermissionMode)
    func close()

    var onMessage: ((Message2, [String: Any]) -> Void)? { get set }
    var onPermissionRequest: ((PermissionRequest, @escaping (PermissionDecision) -> Void) -> Void)? { get set }
    var onPermissionCancelled: ((String) -> Void)? { get set }
    var onProcessExit: ((Int32) -> Void)? { get set }
    var onStderr: ((String) -> Void)? { get set }
}

/// 渲染桥接协议。生产环境由 WebViewBridge 实现。
protocol SessionBridge: AnyObject {
    func forwardRawMessage(conversationId: String, messageJSON: [String: Any])
    func setTurnActive(conversationId: String, isTurnActive: Bool, interrupted: Bool)
}

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

// MARK: - Backend Protocol

/// CLI 后端协议。生产环境由 AgentSDK.Session 的适配器实现，测试环境注入 fake。
///
/// 配置写回 CLI 分两种 control request：
/// - `setModel` / `setPermissionMode`：各自独立 subtype（`set_model` / `set_permission_mode`）。
/// - `applyFlagSettings`：统一 `apply_flag_settings` 通道，承载 effort / additionalDirectories /
///   enabledPlugins / fastMode / thinking 等一切 flag 层配置。SessionHandle2 的对应 setter 内部
///   构造 `FlagSettings` 调这一个入口，不在 backend 上为每项加专用方法。
protocol SessionBackend: AnyObject {
    func sendMessage(_ text: String, planContent: String?)
    func interrupt(completion: @escaping () -> Void)
    func setModel(_ model: String)
    func setPermissionMode(_ mode: AgentSDK.PermissionMode)
    func applyFlagSettings(_ settings: FlagSettings)
    func close()

    var onMessage: ((Message2) -> Void)? { get set }
    var onPermissionRequest: ((PermissionRequest, @escaping (PermissionDecision) -> Void) -> Void)? { get set }
    var onPermissionCancelled: ((String) -> Void)? { get set }
    var onProcessExit: ((Int32) -> Void)? { get set }
    var onStderr: ((String) -> Void)? { get set }
}

// MARK: - Bridge Protocol

/// 渲染桥接协议。生产环境由 WebViewBridge 实现。
protocol SessionBridge: AnyObject {
    func forwardRawMessage(conversationId: String, messageJSON: [String: Any])
    func setRawMessages(conversationId: String, messagesJSON: [[String: Any]])
    func setTurnActive(conversationId: String, isTurnActive: Bool, interrupted: Bool)
}

import Foundation
import Observation
import AgentSDK

/// 单个会话的运行时 Model。
///
/// 职责：
/// - 持有会话状态（全 @Observable，UI 直接观察）
/// - 暴露命令（写 CLI stdin）
/// - 管理消息队列
/// - 处理 CLI 回调并更新自身状态（见 +CLIBinding）
///
/// 非职责：
/// - 不做渲染过滤（原始消息无脑转发 bridge，React 负责过滤）
/// - 不做消息配对（tool_use ↔ tool_result 配对由 React 做）
/// - 不做持久化（SessionService 订阅状态变化做持久化）
///
/// 生命周期：会话创建时即诞生（status=.inactive），持续到用户删除会话。
/// attach/detach 只切换"是否有活跃子进程"，不影响 handle 存在。
@Observable
@MainActor
final class SessionHandle2 {

    // MARK: - Identity

    let sessionId: String

    // MARK: - Runtime State

    /// 子进程运行时状态。
    private(set) var status: Status = .inactive

    /// 工作区（cwd + isWorktree）。attach 后由 sessionInit / pathChange 更新。
    private(set) var workspace: Workspace

    /// 上下文 token 用量。首条 assistant 消息到达前为 nil。
    private(set) var contextUsage: ContextUsage? = nil

    /// sessionInit 返回的可用 slash commands。
    private(set) var slashCommands: [SlashCommand] = []

    /// 等待用户决策的权限请求。
    private(set) var pendingPermissions: [PendingPermission] = []

    /// 排队中的待发送消息。
    private(set) var queuedMessages: [String] = []

    /// 是否正在异步生成 worktree 分支名。
    private(set) var branchGenerating: Bool = false

    /// 历史消息加载状态。
    private(set) var historyLoadState: HistoryLoadState = .notLoaded

    // MARK: - Configuration

    /// 权限模式。用户可改，CLI 也可能推送覆盖。
    private(set) var permissionMode: PermissionMode

    /// 当前模型。
    private(set) var model: String?

    /// 当前 effort 级别。nil = 使用 CLI 默认。
    private(set) var effort: Effort?

    // MARK: - UI State (self-managing closed loops)

    /// 当前是否被用户聚焦。由 ChatRouter 通过 setFocused 维护"全局唯一 focused"不变量。
    private(set) var isFocused: Bool = false

    /// 有未读内容。未聚焦状态下响应完成时自动置 true；聚焦时自动清零。
    private(set) var hasUnread: Bool = false

    /// 待展示的异常退出信息。非零退出时设置，用户关闭 alert 后清零。
    private(set) var unshownExitError: ProcessExit? = nil

    // MARK: - Init

    /// 创建会话。所有初始上下文必须在此提供，对象创建即完整。
    init(
        sessionId: String,
        workspace: Workspace,
        permissionMode: PermissionMode,
        model: String?,
        effort: Effort?
    ) {
        self.sessionId = sessionId
        self.workspace = workspace
        self.permissionMode = permissionMode
        self.model = model
        self.effort = effort
    }

    // MARK: - Commands

    /// 发送消息。idle 时立即发送，非 idle 自动入队。
    /// 首次发送自动将内容设为会话标题。
    func send(_ text: String, extra: MessageExtra? = nil) {
        fatalError("TODO")
    }

    /// 中断当前响应。仅 .responding 时有效。
    func interrupt() {
        fatalError("TODO")
    }

    /// 变更会话配置，写 stdin 通知 CLI。
    func configure(_ change: ConfigChange) {
        fatalError("TODO")
    }

    // MARK: - Queue

    func enqueue(_ text: String) {
        fatalError("TODO")
    }

    func dequeue(at index: Int) {
        fatalError("TODO")
    }

    // MARK: - UI State Control

    /// 由 ChatRouter 调用。聚焦时自动清 hasUnread。
    func setFocused(_ focused: Bool) {
        fatalError("TODO")
    }

    /// 用户关闭错误 alert 后调用。
    func dismissExitError() {
        fatalError("TODO")
    }
}

// MARK: - Nested Types

extension SessionHandle2 {

    enum Status {
        case inactive       // 无子进程
        case starting       // 已 attach，等待 sessionInit
        case idle           // 就绪，等待用户输入
        case responding     // 模型生成中
        case interrupting   // 已发中断，等待模型停止

        var isActive: Bool { self != .inactive }
    }

    enum ConfigChange {
        case permissionMode(PermissionMode)
        case model(String)
        case effort(Effort)
    }

    enum HistoryLoadState {
        case notLoaded, loading, loaded
    }

    enum SessionInitError: Error {
        case timeout
        case superseded
    }
}

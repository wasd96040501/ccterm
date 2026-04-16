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
/// - 不做消息配对（tool_use ↔ tool_result 配对由 React 做）
/// - 不做持久化（SessionService 观察状态变化做持久化）
///
/// 生命周期：会话创建时即诞生（status=.inactive），持续到用户删除会话。
/// attach/detach 只切换"是否有活跃子进程"，不影响 handle 存在。
@Observable
@MainActor
final class SessionHandle2 {

    // MARK: - Identity

    let sessionId: String

    // MARK: - Runtime State

    internal(set) var status: Status = .inactive
    internal(set) var workspace: Workspace
    internal(set) var contextUsage: ContextUsage? = nil
    internal(set) var slashCommands: [SlashCommand] = []
    internal(set) var pendingPermissions: [PendingPermission] = []
    internal(set) var queuedMessages: [String] = []
    internal(set) var branchGenerating: Bool = false
    internal(set) var historyLoadState: HistoryLoadState = .notLoaded

    // MARK: - Configuration

    internal(set) var permissionMode: PermissionMode
    internal(set) var model: String?
    internal(set) var effort: Effort?

    // MARK: - UI State (self-managing closed loops)

    internal(set) var isFocused: Bool = false
    internal(set) var hasUnread: Bool = false
    internal(set) var unshownExitError: ProcessExit? = nil

    // MARK: - Implementation State (cross-file access by extensions)

    @ObservationIgnored internal var backend: SessionBackend?
    @ObservationIgnored internal weak var bridge: SessionBridge?
    @ObservationIgnored internal var filterState = MessageFilter.State()
    @ObservationIgnored internal var stderrBuffer: String = ""
    @ObservationIgnored internal var sessionInitContinuation: CheckedContinuation<Void, Error>?

    // MARK: - Init

    /// 创建会话。所有初始上下文必须在此提供，对象创建即完整。
    init(
        sessionId: String,
        workspace: Workspace,
        permissionMode: PermissionMode,
        model: String?,
        effort: Effort?,
        bridge: SessionBridge
    ) {
        self.sessionId = sessionId
        self.workspace = workspace
        self.permissionMode = permissionMode
        self.model = model
        self.effort = effort
        self.bridge = bridge
    }

    // MARK: - Commands

    /// 发送消息。idle 时立即发送，非 idle 自动入队。
    func send(_ text: String, extra: MessageExtra? = nil) {
        guard let backend else { return }

        if status != .idle {
            enqueue(text)
            return
        }

        renderUserMessage(text)

        var extraDict: [String: Any] = [:]
        if let planContent = extra?.planContent {
            extraDict["planContent"] = planContent
        }
        backend.sendMessage(text, extra: extraDict)

        status = .responding
        notifyTurnActive()
    }

    /// 中断当前响应。仅 .responding 时有效。
    func interrupt() {
        guard status == .responding, let backend else { return }
        status = .interrupting
        backend.interrupt { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status = .idle
                self.notifyTurnActive(interrupted: true)
                self.flushQueueIfNeeded()
            }
        }
    }

    /// 变更会话配置。本地状态立即更新（乐观），若有 backend 则同步写 stdin。
    func configure(_ change: ConfigChange) {
        switch change {
        case .permissionMode(let mode):
            permissionMode = mode
            backend?.setPermissionMode(mode.toSDK())
        case .model(let newModel):
            model = newModel
            backend?.setModel(newModel)
        case .effort(let newEffort):
            effort = newEffort
            backend?.setEffort(newEffort)
        }
    }

    // MARK: - Queue

    func enqueue(_ text: String) {
        queuedMessages.append(text)
    }

    func dequeue(at index: Int) {
        guard queuedMessages.indices.contains(index) else { return }
        queuedMessages.remove(at: index)
    }

    // MARK: - UI State Control

    /// 由 ChatRouter 调用，维护"全局唯一 focused"不变量。聚焦时自动清 hasUnread。
    func setFocused(_ focused: Bool) {
        isFocused = focused
        if focused {
            hasUnread = false
        }
    }

    /// 用户关闭错误 alert 后调用。
    func dismissExitError() {
        unshownExitError = nil
    }

    // MARK: - Internal Helpers (shared across extensions)

    /// 合并队列消息并一次性发送。idle 且有排队消息时调用。
    internal func flushQueueIfNeeded() {
        guard status == .idle, !queuedMessages.isEmpty, let backend else { return }
        let merged = queuedMessages.joined(separator: "\n\n")
        queuedMessages.removeAll()
        renderUserMessage(merged)
        backend.sendMessage(merged, extra: [:])
        status = .responding
        notifyTurnActive()
    }

    /// 合成 user 消息 JSON 发送给 React。
    internal func renderUserMessage(_ text: String) {
        let userJSON: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": text,
            ],
        ]
        bridge?.forwardRawMessage(conversationId: sessionId, messageJSON: userJSON)
    }

    /// 通知 React 当前是否处于 turn active 状态。
    internal func notifyTurnActive(interrupted: Bool = false) {
        bridge?.setTurnActive(
            conversationId: sessionId,
            isTurnActive: status == .responding || status == .interrupting,
            interrupted: interrupted
        )
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

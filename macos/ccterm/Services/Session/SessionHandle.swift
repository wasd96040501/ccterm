import Foundation
import Observation
import AgentSDK

// MARK: - SessionMessage

/// 发送给 CLI 的消息类型。
enum SessionMessage {
    /// 文本消息，可附带元数据。
    case text(String, extra: MessageExtra? = nil)
    /// 图片消息。
    case image(Data, mediaType: String)
}

/// 文本消息的附加元数据。
struct MessageExtra {
    var planContent: String?
}

// MARK: - PendingPermission

/// CLI 发来的待决策权限请求。包含请求内容和响应闭包。
/// UI 展示请求内容，用户决策后调用 respond 闭包，自动回调 CLI 并从列表中移除。
struct PendingPermission: Identifiable {
    let id: String
    let request: PermissionRequest
    /// 调用此闭包响应 CLI。闭包内部会自动从 pendingPermissions 中移除本条。
    let respond: (PermissionDecision) -> Void
}

// MARK: - ProcessExit

/// 子进程退出信息。
struct ProcessExit {
    let exitCode: Int32
    let stderr: String?
}

// MARK: - SessionHandle

/// 单个会话的运行时句柄：可观察状态 + 交互命令。
///
/// @Observable @MainActor——SwiftUI View 直接观察属性变化。
/// 由 SessionService.session(_:) 创建并缓存，外部不直接构造。
///
/// 一个 SessionHandle 通过 sessionId 对应一个 Session 持久化实体。
/// 无论子进程是否存在都可获取——历史会话的 status 为 .inactive，消息从 JSONL 懒加载。
/// SessionHandle 释放时其消息缓存一并释放。
///
/// 所有 observable 属性由 CLI 推送更新（通过 attach 注册的回调 → 内部 handler）。
/// 本地操作（send/interrupt/setPermissionMode）只写 stdin 请求 CLI 变更，不直接改 observable 值。
///
/// 关系：SessionHandle 1 <-> 1 Session（同 sessionId）
///       SessionHandle 0..1 <-> 1 AgentSDK.Session（运行时子进程，仅 status != .inactive 时存在）
///
/// 消息处理：
///   MessageFilter.swift                — 消息过滤纯函数（live/replay 共用）
///   SessionHandle+HistoryReplay.swift  — JSONL 历史消息懒加载
@Observable
@MainActor
class SessionHandle {

    /// 会话 ID，与 Session 实体的 sessionId 一致。
    let sessionId: String

    /// 持久化层引用，用于更新 title、加载历史消息等。
    internal let repository: SessionRepository

    init(sessionId: String, repository: SessionRepository) {
        self.sessionId = sessionId
        self.repository = repository
    }

    // MARK: - Internal

    /// 运行时子进程引用。attach 时设置，detach 时置 nil。
    internal var agentSession: AgentSDK.Session?

    /// 过滤器状态。仅追踪 context usage 相关字段。
    @ObservationIgnored internal var filterState = MessageFilter.State()

    /// WebViewBridge 引用，转发原始 JSON 到 React。
    weak var bridge: WebViewBridge?

    // MARK: - Observable State (由 CLI 推送更新)

    /// 子进程运行时状态（不持久化，持久化状态见 SessionStatus）。
    internal(set) var status: Status = .inactive {
        didSet {
            guard status != oldValue else { return }
            emit(.statusChanged(old: oldValue, new: status))
        }
    }

    /// 上下文窗口已用 token 数。由 assistant 消息的 usage 字段更新。
    internal(set) var contextUsedTokens: Int = 0

    /// 上下文窗口总 token 数。由 assistant 消息的 usage 字段更新。
    internal(set) var contextWindowTokens: Int = 0

    /// 上下文窗口已用百分比（0~100）。首条 assistant 消息到达前为 nil。
    var contextUsedPercent: Double? {
        guard contextWindowTokens > 0 else { return nil }
        return Double(contextUsedTokens) / Double(contextWindowTokens) * 100
    }

    /// 等待用户决策的权限请求列表。用户决策后通过 PendingPermission.respond 回调 CLI 并自动移除。
    private(set) var pendingPermissions: [PendingPermission] = []

    /// 排队待发送的消息。在模型响应期间入队，空闲时通过 flushQueue() 合并发送。
    private(set) var queuedMessages: [String] = []

    /// sessionInit 返回的可用 slash commands。
    internal(set) var slashCommands: [SlashCommand] = []

    /// sessionInit 返回的实际工作目录。enterWorktree/exitWorktree 时更新。
    private(set) var cwd: String?

    /// 是否处于 worktree 模式。初始值从 SessionConfig 传入，运行中由 enterWorktree/exitWorktree 更新。
    internal(set) var isWorktree: Bool = false

    /// 当前权限模式。初始值从 SessionConfig 传入，运行中由 CLI 推送更新。
    internal(set) var permissionMode: PermissionMode = .default

    /// 子进程最近一次退出的信息。运行中为 nil，进程退出时设置。
    private(set) var lastExit: ProcessExit?

    /// 历史消息加载状态。live session attach 时直接设为 .loaded；inactive 会话首次展示时懒加载。
    internal(set) var historyLoadState: HistoryLoadState = .notLoaded

    // MARK: - Event Stream

    /// 创建事件订阅流。多个消费者可同时订阅。流在 Task cancel 或 handle deinit 时结束。
    func eventStream() -> AsyncStream<SessionEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.eventContinuations.removeValue(forKey: id)
                }
            }
            self.eventContinuations[id] = continuation
        }
    }

    private func emit(_ event: SessionEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    deinit {
        for continuation in eventContinuations.values {
            continuation.finish()
        }
    }

    // MARK: - Messaging

    /// 发送消息（写 stdin）。status 从 .idle 变为 .responding。
    /// 如果 status 不是 .idle，文本消息自动入队（等同于调用 enqueue）。
    /// 首次发送文本消息时自动将消息内容设为会话标题。
    func send(_ message: SessionMessage) {
        guard let agentSession else {
            NSLog("[SessionHandle:%@] send() ignored — no agentSession", sessionId)
            return
        }

        // 非 idle 时文本消息入队
        if status != .idle {
            if case .text(let text, _) = message {
                NSLog("[SessionHandle:%@] send() queued — status=%@ text=%@", sessionId, "\(status)", String(text.prefix(50)))
                enqueue(text)
            }
            return
        }

        switch message {
        case .text(let text, let extra):
            NSLog("[SessionHandle:%@] send() text=%@ bridge=%@", sessionId, String(text.prefix(50)), bridge == nil ? "nil" : "ok")

            // 首次发送：用消息内容作为 title
            updateTitleIfNeeded(text)

            // 立即渲染用户消息到 React
            renderUserMessage(text)

            var extraDict: [String: Any] = [:]
            if let planContent = extra?.planContent {
                extraDict["planContent"] = planContent
            }
            agentSession.sendMessage(text, extra: extraDict)
        case .image(_, _):
            // 图片消息暂不支持直接发送
            return
        }
        status = .responding
        repository.touch(sessionId)
        notifyTurnActive()
        NSLog("[SessionHandle:%@] send() → status=responding, turnActive=true", sessionId)
    }

    /// 是否已设置过 title。避免每次 send 都查 DB。恢复已有会话时由 SessionService 设为 true。
    internal var titleSet = false

    private func updateTitleIfNeeded(_ text: String) {
        guard !titleSet else { return }
        titleSet = true
        repository.updateTitle(sessionId, title: String(text.prefix(100)))
    }

    // MARK: - Control

    /// 中断当前模型响应（写 stdin）。CLI 响应后 status 从 .responding → .interrupting → .idle。
    /// 仅在 .responding 时有效，其他状态调用无效果。
    func interrupt() {
        guard status == .responding, let agentSession else { return }
        NSLog("[SessionHandle:%@] interrupt() → status=interrupting", sessionId)
        status = .interrupting
        agentSession.interrupt { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status = .idle
                self.notifyTurnActive(interrupted: true)
                self.flushQueueIfNeeded()
            }
        }
    }

    /// 请求变更权限模式（写 stdin）。CLI 确认后通过消息推送更新 permissionMode 属性。
    func setPermissionMode(_ mode: PermissionMode) {
        agentSession?.setPermissionMode(mode.toSDK())
    }

    /// 请求变更模型（写 stdin）。
    func setModel(_ model: String?) {
        guard let model else { return }
        agentSession?.setModel(model)
    }

    /// 请求变更 effort 级别（通过 apply_flag_settings）。
    func setEffort(_ effort: Effort) {
        agentSession?.setEffort(effort)
    }

    // MARK: - Message Queue

    /// 将消息加入发送队列。不触发发送，等待 flushQueue() 或 status 回到 .idle 时自动发送。
    func enqueue(_ text: String) {
        queuedMessages.append(text)
    }

    /// 移除队列中指定位置的消息。
    func dequeue(at index: Int) {
        guard queuedMessages.indices.contains(index) else { return }
        queuedMessages.remove(at: index)
    }

    /// 合并队列中所有消息并一次性发送。队列清空，status 变为 .responding。
    /// 队列为空时调用无效果。
    func flushQueue() {
        guard !queuedMessages.isEmpty, let agentSession else { return }
        let merged = queuedMessages.joined(separator: "\n\n")
        queuedMessages.removeAll()
        renderUserMessage(merged)
        agentSession.sendMessage(merged)
        status = .responding
        notifyTurnActive()
    }

    // MARK: - Lifecycle

    /// 绑定 AgentSDK 子进程并设置所有回调。由 SessionService.start() 调用。
    ///
    /// 注册的回调（统一通过 Task { @MainActor in } 回到主线程）：
    /// - onMessage       → handleLiveMessage(_:)
    /// - onPermissionRequest   → 创建 PendingPermission 加入 pendingPermissions
    /// - onPermissionCancelled → 移除对应 PendingPermission
    /// - onProcessExit   → handleProcessExit(_:)
    /// - onStderr        → accumulateStderr(_:)
    /// - onHookRequest / onMCPRequest / onElicitationRequest → 直接处理（未来改异步）
    func attach(_ session: AgentSDK.Session) {
        NSLog("[SessionHandle:%@] attach() → status=starting", sessionId)
        self.agentSession = session
        status = .starting
        historyLoadState = .loaded

        session.onMessage = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleLiveMessage(message)
            }
        }

        session.onPermissionRequest = { [weak self] request, completion in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(.deny(reason: "SessionHandle deallocated"))
                    return
                }
                let pending = PendingPermission(
                    id: request.requestId,
                    request: request,
                    respond: { [weak self] decision in
                        completion(decision)
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.pendingPermissions.removeAll { $0.id == request.requestId }
                            self.emit(.permissionsChanged(self.pendingPermissions))
                        }
                    }
                )
                self.pendingPermissions.append(pending)
                self.emit(.permissionsChanged(self.pendingPermissions))
            }
        }

        session.onPermissionCancelled = { [weak self] requestId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingPermissions.removeAll { $0.id == requestId }
                self.emit(.permissionsChanged(self.pendingPermissions))
            }
        }

        session.onProcessExit = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                self?.handleProcessExit(exitCode)
            }
        }

        session.onStderr = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.accumulateStderr(text)
            }
        }

        session.onHookRequest = { request in
            .success()
        }

        session.onMCPRequest = { request in
            .success()
        }

        session.onElicitationRequest = { request in
            .cancel
        }
    }

    /// 停止子进程并清除引用。status → .inactive。由 SessionService.stop() 调用。
    func detach() {
        NSLog("[SessionHandle:%@] detach() → status=inactive", sessionId)
        // 拒绝所有待决策权限
        for pending in pendingPermissions {
            pending.respond(.deny(reason: "Session stopped"))
        }
        pendingPermissions.removeAll()
        emit(.permissionsChanged(pendingPermissions))

        agentSession?.close()
        agentSession = nil
        status = .inactive
        notifyTurnActive()
        stderrBuffer = ""
    }

    // MARK: - Internal Handlers

    /// 处理 CLI 推送的消息。过滤 + 转发原始 JSON 到 React，不做消息转换。
    internal func handleLiveMessage(_ message: Message2) {
        let msgType: String
        switch message {
        case .user: msgType = "user"
        case .assistant: msgType = "assistant"
        case .result: msgType = "result"
        case .system: msgType = "system"
        default: msgType = "other"
        }

        let result = MessageFilter.filter(message, state: &filterState)
        applyEffects(result.effects)

        if result.shouldForward, let bridge {
            let json = message.toJSON() as? [String: Any] ?? [:]
            bridge.forwardRawMessage(conversationId: sessionId, messageJSON: json)
            NSLog("[SessionHandle:%@] forwardRawMessage type=%@ forward=true", sessionId, msgType)
        } else {
            NSLog("[SessionHandle:%@] handleLiveMessage type=%@ forward=%@ bridge=%@", sessionId, msgType, result.shouldForward ? "true" : "false", bridge == nil ? "nil" : "ok")
        }
    }

    /// 应用消息处理副作用（两条路径共用）。
    private func applyEffects(_ effects: MessageProcessorEffects) {
        if let used = effects.contextUsed {
            contextUsedTokens = used
        }
        if let window = effects.contextWindow {
            contextWindowTokens = window
        }

        if let init_ = effects.sessionInit {
            NSLog("[SessionHandle:%@] sessionInit arrived — cwd=%@ status=%@", sessionId, init_.cwd ?? "nil", "\(status)")
            cwd = init_.cwd
            if let newCwd = init_.cwd {
                emit(.cwdChanged(newCwd))
            }
            if status == .starting {
                status = .idle
            }
            if let cmds = init_.slashCommands {
                slashCommands = cmds.map { SlashCommand(name: $0, description: nil) }
            }
            if let modeStr = init_.permissionMode,
               let mode = PermissionMode(rawValue: modeStr) {
                permissionMode = mode
            }
            // 写回 cwd 并更新持久化状态
            if let cwd = init_.cwd {
                repository.updateCwd(sessionId, cwd: cwd)
            }
            if repository.find(sessionId)?.status == .pending {
                repository.updateStatus(sessionId, to: .created)
            }
            fulfillSessionInit()
        }

        if let change = effects.pathChange {
            cwd = change.cwd
            isWorktree = change.isWorktree
            emit(.cwdChanged(change.cwd))
        }

        if effects.turnEnded {
            NSLog("[SessionHandle:%@] turnEnded → status=idle", sessionId)
            status = .idle
            repository.touch(sessionId)
            notifyTurnActive()
            flushQueueIfNeeded()
        }
    }

    /// 处理子进程退出。设置 lastExit，status → .inactive。
    internal func handleProcessExit(_ exitCode: Int32) {
        NSLog("[SessionHandle:%@] processExit code=%d stderr=%@", sessionId, exitCode, stderrBuffer.isEmpty ? "(empty)" : String(stderrBuffer.prefix(200)))
        lastExit = ProcessExit(
            exitCode: exitCode,
            stderr: stderrBuffer.isEmpty ? nil : stderrBuffer
        )
        emit(.processExited(lastExit!))   // status 仍是退出前的值
        stderrBuffer = ""
        agentSession = nil
        status = .inactive                 // didSet 自动 emit statusChanged
        fulfillSessionInit()

        // 拒绝所有待决策权限
        for pending in pendingPermissions {
            pending.respond(.deny(reason: "Process exited"))
        }
        pendingPermissions.removeAll()
        emit(.permissionsChanged(pendingPermissions))
    }

    /// 累积 stderr 输出。进程退出时写入 lastExit.stderr。
    internal func accumulateStderr(_ text: String) {
        stderrBuffer += text
    }

    // MARK: - Session Init Awaiting

    /// SessionService.start() 用此方法等待 sessionInit 到达。
    /// 超时 30 秒后抛出错误，避免无限等待。
    func waitForSessionInit() async throws {
        try await withCheckedThrowingContinuation { continuation in
            if status != .starting {
                continuation.resume()
                return
            }
            // 如果已有等待中的 continuation（重复调用），先以错误 resume 旧的避免泄漏
            sessionInitContinuation?.resume(throwing: SessionInitError.superseded)
            sessionInitContinuation = continuation

            // 30 秒超时
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, let cont = self.sessionInitContinuation else { return }
                self.sessionInitContinuation = nil
                cont.resume(throwing: SessionInitError.timeout)
            }
        }
    }

    /// sessionInit 到达时 fulfill continuation。
    private func fulfillSessionInit() {
        let cont = sessionInitContinuation
        sessionInitContinuation = nil
        cont?.resume()
    }

    enum SessionInitError: Error {
        case timeout
        case superseded
    }

    // MARK: - Private

    /// sessionInit 的 continuation，由 waitForSessionInit 设置，handleLiveMessage(.sessionInit) 时 fulfill。
    private var sessionInitContinuation: CheckedContinuation<Void, Error>?

    /// stderr 累积缓冲区。
    private var stderrBuffer: String = ""

    /// 事件流 continuations。多订阅者广播。
    @ObservationIgnored
    private var eventContinuations: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]

    /// 立即渲染用户消息到 React。构造合成 Message2 user JSON 格式。
    private func renderUserMessage(_ text: String) {
        guard let bridge else { return }
        let userJSON: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": text,
            ],
        ]
        bridge.forwardRawMessage(conversationId: sessionId, messageJSON: userJSON)
    }

    /// 通知 React 端当前是否处于 turn active 状态。
    private func notifyTurnActive(interrupted: Bool = false) {
        bridge?.setTurnActive(conversationId: sessionId, isTurnActive: status == .responding || status == .interrupting, interrupted: interrupted)
    }

    /// status 回到 idle 时自动发送队列消息。
    private func flushQueueIfNeeded() {
        if status == .idle && !queuedMessages.isEmpty {
            flushQueue()
        }
    }
}

// MARK: - SessionHandle.Status

extension SessionHandle {

    /// 子进程运行时状态（内存中，不持久化）。
    /// 持久化生命周期状态见 SessionStatus。
    enum Status {
        /// 无子进程。历史会话或尚未启动。
        case inactive
        /// 子进程已启动，正在初始化（等待 sessionInit）。
        case starting
        /// 子进程就绪，等待用户输入。
        case idle
        /// 模型正在生成响应。
        case responding
        /// 已发送中断，等待模型停止。
        case interrupting

        /// 是否有活跃的子进程（非 inactive）。
        var isActive: Bool { self != .inactive }
    }
}


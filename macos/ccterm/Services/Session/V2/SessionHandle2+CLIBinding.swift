import Foundation
import AgentSDK

/// CLI 接线层：attach/detach 生命周期 + 所有 CLI 回调处理。
///
/// attach 内注册所有 SessionBackend 回调，回调处理状态提取、pending 权限维护、
/// 进程退出处理、stderr 累积。
extension SessionHandle2 {

    /// 绑定后端。注册所有 CLI 回调，status 从 .inactive → .starting。
    /// 调用方：SessionService。
    func attach(backend: SessionBackend) {
        appLog(.info, "SessionHandle2", "attach \(sessionId)")
        self.backend = backend
        status = .starting
        historyLoadState = .loaded

        backend.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handleMessage(message)
            }
        }

        backend.onPermissionRequest = { [weak self] request, completion in
            Task { @MainActor in
                guard let self else {
                    completion(.deny(reason: "SessionHandle deallocated"))
                    return
                }
                appLog(.info, "SessionHandle2", "permissionRequest id=\(request.requestId) tool=\(request.toolName) \(self.sessionId)")
                var responded = false
                let pending = PendingPermission(
                    id: request.requestId,
                    request: request,
                    respond: { [weak self] decision in
                        guard !responded else { return }
                        responded = true
                        completion(decision)
                        Task { @MainActor in
                            self?.pendingPermissions.removeAll { $0.id == request.requestId }
                        }
                    }
                )
                self.pendingPermissions.append(pending)
            }
        }

        backend.onPermissionCancelled = { [weak self] requestId in
            Task { @MainActor in
                self?.pendingPermissions.removeAll { $0.id == requestId }
            }
        }

        backend.onProcessExit = { [weak self] exitCode in
            Task { @MainActor in
                self?.handleProcessExit(exitCode)
            }
        }

        backend.onStderr = { [weak self] text in
            Task { @MainActor in
                self?.stderrBuffer += text
            }
        }
    }

    /// 用户主动停止。teardown 清 backend，fulfill pending wait 为 terminated。
    /// 调用方：SessionService。
    func detach() {
        appLog(.info, "SessionHandle2", "detach \(sessionId)")
        teardown()
    }

    /// 异步等待 sessionInit 到达。30 秒超时。
    /// 调用方：SessionService（launch 流程阻塞直到就绪）。
    func waitForSessionInit() async throws {
        try await withCheckedThrowingContinuation { continuation in
            if status != .starting {
                continuation.resume()
                return
            }
            // supersede 旧等待
            sessionInitContinuation?.resume(throwing: SessionInitError.superseded)
            sessionInitGeneration += 1
            let gen = sessionInitGeneration
            sessionInitContinuation = continuation

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self,
                      self.sessionInitGeneration == gen,
                      let cont = self.sessionInitContinuation else { return }
                self.sessionInitContinuation = nil
                self.sessionInitGeneration += 1
                cont.resume(throwing: SessionInitError.timeout)
            }
        }
    }

    // MARK: - Message Handling

    /// CLI 推送的消息：抽状态 → 统一原始转发给 bridge。过滤交给 React。
    internal func handleMessage(_ message: Message2) {
        updateContextUsage(for: message)

        switch message {
        case .system(let sys):
            if case .`init`(let info) = sys {
                applySessionInit(info)
            }
        case .result:
            applyTurnEnd()
        case .user(let u):
            applyWorktreeChangeIfAny(u)
        default:
            break
        }

        let raw = (message.toJSON() as? [String: Any]) ?? [:]
        bridge?.forwardRawMessage(conversationId: sessionId, messageJSON: raw)
    }

    private func updateContextUsage(for message: Message2) {
        let (used, window) = Self.usageDelta(for: message, modelContextWindows: &modelContextWindows)
        guard used != nil || window != nil else { return }
        contextUsage = ContextUsage(
            used: used ?? contextUsage?.used ?? 0,
            window: window ?? contextUsage?.window ?? 0
        )
    }

    private func applySessionInit(_ info: Init) {
        appLog(.info, "SessionHandle2", "sessionInit cwd=\(info.cwd ?? "nil") \(sessionId)")
        if let cwd = info.cwd {
            workspace = Workspace(cwd: cwd, isWorktree: workspace.isWorktree)
        }
        if let cmds = info.slashCommands {
            slashCommands = cmds.map { SlashCommand(name: $0, description: nil) }
        }
        if let modeStr = info.permissionMode,
           let mode = PermissionMode(rawValue: modeStr) {
            permissionMode = mode
        }
        if status == .starting {
            status = .idle
        }
        fulfillSessionInit()
    }

    private func applyTurnEnd() {
        let wasResponding = status == .responding
        status = .idle
        notifyTurnActive()
        if wasResponding && !ui.isFocused {
            ui.hasUnread = true
        }
        flushQueueIfNeeded()
    }

    private func applyWorktreeChangeIfAny(_ u: Message2User) {
        guard u.parentToolUseId == nil else { return }
        guard case .object(let obj) = u.toolUseResult else { return }
        switch obj {
        case .EnterWorktree(let o, _):
            if let p = o.worktreePath {
                workspace = Workspace(cwd: p, isWorktree: true)
            }
        case .ExitWorktree(let o, _):
            if let p = o.originalCwd {
                workspace = Workspace(cwd: p, isWorktree: false)
            }
        default:
            break
        }
    }

    // MARK: - Shared with HistoryReplay (nonisolated)

    /// 从单条消息提取 (used, window) 增量。调用方合并进当前 contextUsage。
    /// assistant（非 sub-agent）的 usage 给 used、从缓存取 window；
    /// result 的 modelUsage 更新缓存并返回最大 window。
    nonisolated static func usageDelta(
        for message: Message2,
        modelContextWindows: inout [String: Int]
    ) -> (used: Int?, window: Int?) {
        switch message {
        case .assistant(let a) where a.parentToolUseId == nil:
            guard let usage = a.message?.usage else { return (nil, nil) }
            let used = (usage.inputTokens ?? 0)
                + (usage.cacheCreationInputTokens ?? 0)
                + (usage.cacheReadInputTokens ?? 0)
            let window = a.message?.model.flatMap { modelContextWindows[$0] }
            return (used, window)

        case .result(let r):
            let modelUsage: [String: ModelUsageValue]?
            switch r {
            case .success(let s): modelUsage = s.modelUsage
            case .errorDuringExecution(let e): modelUsage = e.modelUsage
            default: return (nil, nil)
            }
            guard let modelUsage else { return (nil, nil) }
            for (m, v) in modelUsage {
                if let w = v.contextWindow { modelContextWindows[m] = w }
            }
            return (nil, modelUsage.values.compactMap(\.contextWindow).max())

        default:
            return (nil, nil)
        }
    }

    // MARK: - Process Exit

    private func handleProcessExit(_ exitCode: Int32) {
        appLog(.warning, "SessionHandle2", "processExit code=\(exitCode) \(sessionId)")
        if exitCode != 0 {
            ui.unshownExitError = ProcessExit(
                exitCode: exitCode,
                stderr: stderrBuffer.isEmpty ? nil : stderrBuffer
            )
        }
        teardown()
    }

    // MARK: - Teardown (shared by detach + processExit)

    /// 共享清理路径：清 pending → 断 backend → status=inactive → fulfill wait。
    /// CLI 已失联，pending 权限不再回调 completion（CLI 已不再听）。
    private func teardown() {
        pendingPermissions.removeAll()
        stderrBuffer = ""
        backend?.close()
        backend = nil
        status = .inactive
        notifyTurnActive()
        fulfillSessionInit(throwing: .terminated)
    }

    // MARK: - Session Init Continuation

    /// 以成功或失败方式结束当前等待的 sessionInit。递增 generation 让任何未到期超时 Task 作废。
    private func fulfillSessionInit(throwing error: SessionInitError? = nil) {
        sessionInitGeneration += 1
        let cont = sessionInitContinuation
        sessionInitContinuation = nil
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume()
        }
    }
}

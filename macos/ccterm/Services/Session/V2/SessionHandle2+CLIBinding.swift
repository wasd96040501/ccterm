import Foundation
import AgentSDK

/// CLI 接线层：attach/detach 生命周期 + 所有 CLI 回调处理。
///
/// attach 内注册所有 SessionBackend 回调，回调处理状态提取、pending 权限维护、
/// 进程退出处理、stderr 累积。
extension SessionHandle2 {

    /// 绑定后端。注册所有 CLI 回调，status 从 .inactive → .starting。
    /// 调用方：SessionService。
    func attach(backend: SessionBackend, bridge: SessionBridge) {
        self.backend = backend
        self.bridge = bridge
        status = .starting
        historyLoadState = .loaded

        backend.onMessage = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleMessage(message)
            }
        }

        backend.onPermissionRequest = { [weak self] request, completion in
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
                            self?.pendingPermissions.removeAll { $0.id == request.requestId }
                        }
                    }
                )
                self.pendingPermissions.append(pending)
            }
        }

        backend.onPermissionCancelled = { [weak self] requestId in
            Task { @MainActor [weak self] in
                self?.pendingPermissions.removeAll { $0.id == requestId }
            }
        }

        backend.onProcessExit = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                self?.handleProcessExit(exitCode)
            }
        }

        backend.onStderr = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.stderrBuffer += text
            }
        }
    }

    /// 断开后端。拒绝所有 pending 权限，清空 stderr，status → .inactive。
    /// 调用方：SessionService。
    func detach() {
        for pending in pendingPermissions {
            pending.respond(.deny(reason: "Session stopped"))
        }
        pendingPermissions.removeAll()

        backend?.close()
        backend = nil
        status = .inactive
        notifyTurnActive()
        stderrBuffer = ""
    }

    /// 异步等待 sessionInit 到达。30 秒超时。
    /// 调用方：SessionService（launch 流程阻塞直到就绪）。
    func waitForSessionInit() async throws {
        try await withCheckedThrowingContinuation { continuation in
            if status != .starting {
                continuation.resume()
                return
            }
            sessionInitContinuation?.resume(throwing: SessionInitError.superseded)
            sessionInitContinuation = continuation

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, let cont = self.sessionInitContinuation else { return }
                self.sessionInitContinuation = nil
                cont.resume(throwing: SessionInitError.timeout)
            }
        }
    }

    // MARK: - Message Handling

    /// 处理 CLI 推送的消息：提取副作用 → 更新状态 → 转发 JSON 到 bridge。
    internal func handleMessage(_ message: Message2) {
        let result = MessageFilter.filter(message, state: &filterState)

        applyContextUsage(result.effects)
        applySessionInit(result.effects)
        applyPathChange(result.effects)
        applyTurnEnd(result.effects)

        if result.shouldForward {
            let raw = (message.toJSON() as? [String: Any]) ?? [:]
            bridge?.forwardRawMessage(conversationId: sessionId, messageJSON: raw)
        }
    }

    private func applyContextUsage(_ effects: MessageProcessorEffects) {
        guard effects.contextUsed != nil || effects.contextWindow != nil else { return }
        contextUsage = ContextUsage(
            used: effects.contextUsed ?? contextUsage?.used ?? 0,
            window: effects.contextWindow ?? contextUsage?.window ?? 0
        )
    }

    private func applySessionInit(_ effects: MessageProcessorEffects) {
        guard let info = effects.sessionInit else { return }

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

    private func applyPathChange(_ effects: MessageProcessorEffects) {
        guard let change = effects.pathChange else { return }
        workspace = Workspace(cwd: change.cwd, isWorktree: change.isWorktree)
    }

    private func applyTurnEnd(_ effects: MessageProcessorEffects) {
        guard effects.turnEnded else { return }
        let oldStatus = status
        status = .idle
        notifyTurnActive()

        if oldStatus == .responding && !isFocused {
            hasUnread = true
        }

        flushQueueIfNeeded()
    }

    // MARK: - Process Exit

    private func handleProcessExit(_ exitCode: Int32) {
        if exitCode != 0 {
            unshownExitError = ProcessExit(
                exitCode: exitCode,
                stderr: stderrBuffer.isEmpty ? nil : stderrBuffer
            )
        }
        stderrBuffer = ""
        backend = nil
        status = .inactive
        notifyTurnActive()
        fulfillSessionInit()

        for pending in pendingPermissions {
            pending.respond(.deny(reason: "Process exited"))
        }
        pendingPermissions.removeAll()
    }

    // MARK: - Session Init Continuation

    private func fulfillSessionInit() {
        let cont = sessionInitContinuation
        sessionInitContinuation = nil
        cont?.resume()
    }
}

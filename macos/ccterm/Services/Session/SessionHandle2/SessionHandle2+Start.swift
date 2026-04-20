import Foundation
import AgentSDK

// MARK: - Lifecycle

extension SessionHandle2 {

    /// 启动 CLI 子进程。**不触发 loadHistory**（两者正交）。
    ///
    /// - `.notStarted` / `.stopped`：组装 `SessionConfiguration`（基于当前 handle 字段），
    ///   fresh（repository 无记录）→ `repository.save` 完整 record；resume（repository
    ///   有记录）→ 以内存为 authoritative，覆盖写 cwd / title / extra。`status` → `.starting`。
    ///   异步 bootstrap：SDK ready → `.idle` 且 flush queued；SDK 失败 → `.stopped` +
    ///   `termination` + `repository.updateError`。
    /// - 其他 status：no-op。调用方不感知 fresh / resume 区别。
    func start() {
        guard status == .notStarted || status == .stopped else {
            appLog(.info, "SessionHandle2", "start() ignored — status=\(status) \(sessionId)")
            return
        }
        appLog(.info, "SessionHandle2", "start() begin \(sessionId)")

        status = .starting
        termination = nil
        stderrBuffer = ""

        let fresh = (repository.find(sessionId) == nil)

        // stage 2: fresh + isWorktree 时先 provision worktree，同步更新 cwd +
        // 初始 branch（adj-sci-hex）。后续 LLM rename 会改 branch，但不改 cwd。
        // 失败直接走失败路径（status → .stopped，不走 bootstrap，也不写 db）。
        if fresh, isWorktree {
            do {
                let wt = try provisionWorktreeIfNeeded()
                cwd = wt.path
                worktreeBranch = wt.name
            } catch {
                appLog(.error, "SessionHandle2", "worktree provision FAILED \(sessionId) err=\(error)")
                termination = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                status = .stopped
                return
            }
        }

        persistConfiguration(fresh: fresh)

        if skipBootstrapForTesting { return }

        let config = makeAgentConfig(fresh: fresh)
        Task { @MainActor [weak self] in
            await self?.bootstrap(configuration: config, fresh: fresh)
        }
    }

    private func provisionWorktreeIfNeeded() throws -> Worktree {
        guard let origin = originPath else {
            throw Worktree.Error.notGitRepository(path: "(nil originPath)")
        }
        // 已 hydrate 的 worktreeBranch（如果有）用作 sourceBranch——fresh 场景常为 nil，
        // 表示"用 baseRepo 当前 branch"；resume 不走这里。
        return try Worktree.create(from: origin, sourceBranch: worktreeBranch)
    }

    /// 手动停止 CLI 子进程。active 态下调 `close()`；之后由 onProcessExit 回调接管
    /// status/termination/pendingPermissions 清理。其他 status 下 no-op。
    func stop() {
        switch status {
        case .notStarted, .stopped:
            return
        default:
            break
        }
        appLog(.info, "SessionHandle2", "stop() close agent \(sessionId)")
        agentSession?.close()
    }
}

// MARK: - Messaging

extension SessionHandle2 {

    /// 唯一发送入口。无条件 append 一条 user `MessageEntry`（delivery=.queued），
    /// 若 `status == .idle` 则立即 flush；否则保留在队列，待 status 回落 `.idle` 自动发。
    ///
    /// title 生成是正交能力——调用方（fresh + 首条文本场景）显式调 `generateTitle(from:)`。
    func send(_ message: SessionMessage) {
        let entry = makeQueuedEntry(for: message)
        messages.append(entry)

        if status == .idle {
            flushQueueIfNeeded()
        }
    }
}

// MARK: - Queue flush (internal for messaging / configuration callbacks)

extension SessionHandle2 {

    /// 把 `.queued` 的 user entry 合并发往 CLI 并切 `.inFlight`，`status` → `.responding`。
    /// 前置：`status == .idle` 且已 attach agentSession。否则 no-op。
    func flushQueueIfNeeded() {
        guard status == .idle, let session = agentSession else { return }
        var didFlush = false
        for i in messages.indices where messages[i].delivery == .queued {
            guard let text = textFromEntry(messages[i]) else { continue }
            session.sendMessage(text)
            messages[i].delivery = .inFlight
            didFlush = true
        }
        if didFlush {
            status = .responding
        }
    }
}

// MARK: - Title generation (public entry + application)

extension SessionHandle2 {

    /// 生成 title 的唯一入口。与 `start()` 正交——fresh + 空 title 的 policy
    /// 由调用方（ChatRouter）决定，handle 只提供能力。
    ///
    /// 可重入：空 `firstMessage` 或 `isGeneratingTitle == true` 时 no-op，
    /// 调用方失败重试 / 用户手动重生成直接再调即可。
    ///
    /// 生成过程异步（`Task.detached`），不阻塞调用线程。完成后通过
    /// `applyGeneratedTitle` 写回 handle + repository；失败时 `isGeneratingTitle`
    /// 复位、不改 title。
    func generateTitle(from firstMessage: String) {
        guard !firstMessage.isEmpty else { return }
        guard !isGeneratingTitle else { return }
        isGeneratingTitle = true
        launchTitleGenerationTask(firstMessage: firstMessage)
    }

    /// 应用 LLM 生成的 title 到 handle 和 db。
    ///
    /// 总是复位 `isGeneratingTitle`、写 title。worktree 场景下 branch 保持
    /// `start()` 里 provision 出的初始随机名不变（`Prompt.TitleAndBranch.branch`
    /// 字段被丢弃）。
    ///
    /// 拆成独立方法便于测试直接驱动，无需触发真 LLM 调用。
    func applyGeneratedTitle(_ result: Prompt.TitleAndBranch) {
        isGeneratingTitle = false
        title = result.titleI18n
        repository.updateTitle(sessionId, title: result.titleI18n)
        appLog(.info, "SessionHandle2", "title-gen done \(sessionId) title=\(result.titleI18n)")
    }
}

// MARK: - Private impl

private extension SessionHandle2 {

    // MARK: - Title / branch LLM (stage 3)

    func launchTitleGenerationTask(firstMessage: String) {
        let sid = sessionId
        let customCLI = UserDefaults.standard.string(forKey: "customCLICommand")

        Task.detached { [weak self] in
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("title-gen-\(UUID().uuidString.prefix(8))")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let config = PromptConfiguration(
                workingDirectory: tmp,
                customCommand: customCLI
            )
            let result: Prompt.TitleAndBranch?
            do {
                result = try await Prompt.runTitleAndBranch(
                    firstMessage: firstMessage,
                    configuration: config
                )
            } catch {
                appLog(.warning, "SessionHandle2", "title-gen failed \(sid): \(error.localizedDescription)")
                result = nil
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let r = result else {
                    self.isGeneratingTitle = false
                    return
                }
                self.applyGeneratedTitle(r)
            }
        }
    }

    func persistConfiguration(fresh: Bool) {
        if fresh {
            let record = SessionRecord(
                sessionId: sessionId,
                title: title,
                cwd: cwd,
                isWorktree: isWorktree,
                originPath: originPath,
                status: .pending,
                extra: currentExtra(),
                worktreeBranch: worktreeBranch
            )
            repository.save(record)
            appLog(.info, "SessionHandle2", "persistConfiguration fresh save \(sessionId)")
        } else {
            // resume：以内存为 authoritative，整体覆盖 db 涉及字段。
            if let cwd {
                repository.updateCwd(sessionId, cwd: cwd)
            }
            if !title.isEmpty {
                repository.updateTitle(sessionId, title: title)
            }
            repository.updateExtra(sessionId, with: SessionExtraUpdate(
                pluginDirs: pluginDirectories,
                permissionMode: permissionMode.rawValue,
                addDirs: additionalDirectories,
                model: model,
                effort: effort?.rawValue
            ))
            appLog(.info, "SessionHandle2", "persistConfiguration resume overwrite \(sessionId)")
        }
    }

    func currentExtra() -> SessionExtra {
        SessionExtra(
            pluginDirs: pluginDirectories.isEmpty ? nil : pluginDirectories,
            permissionMode: permissionMode.rawValue,
            addDirs: additionalDirectories.isEmpty ? nil : additionalDirectories,
            model: model,
            effort: effort?.rawValue
        )
    }

    func makeAgentConfig(fresh: Bool) -> SessionConfiguration {
        let customCommand = UserDefaults.standard.string(forKey: "customCLICommand")
        let wd = URL(fileURLWithPath: cwd ?? originPath ?? FileManager.default.currentDirectoryPath)
        return SessionConfiguration(
            workingDirectory: wd,
            model: model,
            permissionMode: permissionMode.toSDK(),
            sessionId: fresh ? sessionId : nil,
            resume: fresh ? nil : sessionId,
            effort: effort,
            addDirs: additionalDirectories,
            plugins: pluginDirectories,
            customCommand: customCommand,
            allowDangerouslySkipPermissions: true
        )
    }

    func bootstrap(configuration: SessionConfiguration, fresh: Bool) async {
        let session = AgentSDK.Session(configuration: configuration)
        session.lastKnownSessionId = sessionId
        attachCallbacks(to: session)
        self.agentSession = session

        do {
            try await session.start()
            _ = await withCheckedContinuation { (cont: CheckedContinuation<InitializeResponse?, Never>) in
                session.initialize(promptSuggestions: true) { cont.resume(returning: $0) }
            }
        } catch {
            appLog(.error, "SessionHandle2", "bootstrap FAILED \(sessionId) err=\(error)")
            self.agentSession = nil
            self.termination = error.localizedDescription
            self.status = .stopped
            self.repository.updateError(sessionId, error: error.localizedDescription)
            return
        }

        status = .idle
        if fresh {
            repository.updateStatus(sessionId, to: .created)
        }
        flushQueueIfNeeded()
        appLog(.info, "SessionHandle2", "bootstrap done \(sessionId) fresh=\(fresh)")
    }

    func attachCallbacks(to session: AgentSDK.Session) {
        session.onMessage = { [weak self] msg in
            Task { @MainActor [weak self] in
                self?.receive(msg, mode: .live)
            }
        }

        session.onPermissionRequest = { [weak self] request, completion in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(.deny(reason: "SessionHandle2 deallocated"))
                    return
                }
                self.enqueuePermission(request, completion: completion)
            }
        }

        session.onPermissionCancelled = { [weak self] requestId in
            Task { @MainActor [weak self] in
                self?.pendingPermissions.removeAll { $0.id == requestId }
            }
        }

        session.onProcessExit = { [weak self] code in
            Task { @MainActor [weak self] in
                self?.handleProcessExit(code)
            }
        }

        session.onStderr = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.stderrBuffer += text
            }
        }

        // stage 1 的最小 no-op；hook/mcp/elicitation 按需后续补。
        session.onHookRequest = { _ in HookResult.success() }
        session.onMCPRequest = { _ in MCPResponse.success() }
        session.onElicitationRequest = { _ in .cancel }
    }

    func enqueuePermission(
        _ request: PermissionRequest,
        completion: @escaping (PermissionDecision) -> Void
    ) {
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
        pendingPermissions.append(pending)
    }

    func handleProcessExit(_ code: Int32) {
        let trimmed = stderrBuffer.isEmpty ? nil : String(stderrBuffer.prefix(500))
        let desc = trimmed.map { "process exited (code \(code)): \($0)" }
            ?? "process exited (code \(code))"
        appLog(.warning, "SessionHandle2", "handleProcessExit \(sessionId) \(desc)")

        stderrBuffer = ""
        agentSession = nil
        termination = desc
        status = .stopped

        for pending in pendingPermissions {
            pending.respond(.deny(reason: "Process exited"))
        }
        pendingPermissions.removeAll()

        for i in messages.indices where messages[i].delivery == .inFlight {
            messages[i].delivery = .failed(reason: "session stopped")
        }

        repository.updateError(sessionId, error: desc)
    }

    func makeQueuedEntry(for message: SessionMessage) -> MessageEntry {
        let raw: [String: Any]
        switch message {
        case .text(let text, let extra):
            var dict: [String: Any] = [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": text,
                ],
                "session_id": sessionId,
            ]
            if let plan = extra?.planContent {
                dict["plan_content"] = plan
            }
            raw = dict
        case .image:
            raw = [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "[image]",
                ],
                "session_id": sessionId,
            ]
        }
        let msg = (try? Message2(json: raw)) ?? Message2.unknown(name: "user", raw: raw)
        return MessageEntry(id: UUID(), message: msg, delivery: .queued, toolResults: [:])
    }

    func textFromEntry(_ entry: MessageEntry) -> String? {
        guard case .user(let u) = entry.message,
              let content = u.message?.content else { return nil }
        switch content {
        case .string(let s):
            return s
        case .array(let items):
            let parts = items.compactMap { item -> String? in
                if case .text(let t) = item { return t.text }
                return nil
            }
            return parts.joined(separator: "\n")
        case .other:
            return nil
        }
    }
}

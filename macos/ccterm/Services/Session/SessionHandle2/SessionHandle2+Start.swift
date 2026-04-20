import Foundation
import AgentSDK

// MARK: - Lifecycle (public)

extension SessionHandle2 {

    /// 显式激活 session：确保 CLI 子进程已起、initialize 完毕（拿到 slashCommands /
    /// availableModels / contextWindow）。不会发送消息。
    ///
    /// 幂等：`.notStarted` / `.stopped` → 启动 bootstrap；其他 status 直接 no-op。
    /// UI 打开 session 视图时调用此方法预热 CLI，让 slash 补全等元数据立即可用。
    ///
    /// 与 `send(_:)` 的关系：`send` 内部也会自动确保启动，所以用户如果直接发消息
    /// 不需要显式先调 `activate()`——`activate()` 的价值在于"不发消息也要 CLI 就绪"的场景。
    func activate() {
        ensureStarted()
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

// MARK: - Messaging (public)

extension SessionHandle2 {

    /// 唯一发送入口。语义：
    /// 1. 立即 append 一条 `.queued` user `MessageEntry`（UI 即时看到）。
    /// 2. 如果 session 尚未启动/已停止，自动触发 `ensureStarted()`。
    /// 3. 如果 CLI 已 attach（`agentSession != nil`），立即把文本写到 stdin；
    ///    CLI 侧自己排队，不在 Swift 侧做 flush gating。
    /// 4. CLI 吃到消息后会 echo 回一条带同 uuid 的 user 消息，`receive` 按 uuid
    ///    匹配这个 entry 切换到 `.confirmed`。
    ///
    /// entry.id 作为 `uuid` 字段随消息发给 CLI（`--replay-user-messages` 确保
    /// CLI 原样回显），用于精确匹配。无 id 关联则只能 content 文本启发式，
    /// 那是不可靠的。
    ///
    /// title 生成是正交能力——调用方（fresh + 首条文本场景）显式调 `generateTitle(from:)`。
    func send(_ message: SessionMessage) {
        let single = makeQueuedSingle(for: message)
        messages.append(.single(single))

        ensureStarted()

        if let session = agentSession {
            writeSingleToCLI(single, session: session)
        }
        // 否则 bootstrap 成功后 `drainQueuedEntries` 会把它写到 CLI。
    }
}

// MARK: - Title generation (public)

extension SessionHandle2 {

    /// 生成 title 的唯一入口。与 `activate()` 正交——fresh + 空 title 的 policy
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
    /// `ensureStarted` 里 provision 出的初始随机名不变（`Prompt.TitleAndBranch.branch`
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

// MARK: - Internal bootstrap

extension SessionHandle2 {

    /// 幂等启动入口。`.notStarted` / `.stopped` 下组装 configuration、provision
    /// worktree（fresh + isWorktree）、persist config、启动 bootstrap Task；
    /// 其他 status 直接 no-op。
    ///
    /// 不对外暴露——外部只通过 `activate()` 或 `send(_:)` 进入。
    func ensureStarted() {
        guard status == .notStarted || status == .stopped else { return }
        appLog(.info, "SessionHandle2", "ensureStarted begin \(sessionId)")

        status = .starting
        termination = nil
        stderrBuffer = ""

        let fresh = (repository.find(sessionId) == nil)

        // fresh + isWorktree 时先 provision worktree，同步更新 cwd + 初始 branch
        // （adj-sci-hex）。后续 LLM rename 会改 branch，但不改 cwd。失败直接走
        // 失败路径（status → .stopped，不写 db，不走 bootstrap）。
        if fresh, isWorktree {
            do {
                let wt = try provisionWorktreeIfNeeded()
                cwd = wt.path
                worktreeBranch = wt.name
            } catch {
                appLog(.error, "SessionHandle2", "worktree provision FAILED \(sessionId) err=\(error)")
                termination = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                status = .stopped
                failQueuedEntries(reason: "worktree provision failed")
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

    /// 把所有 `.queued` user entry 写到 CLI。仅在 bootstrap 刚成功、`agentSession`
    /// 就绪那一刻调用一次。此后的 `send(_:)` 走"立即写 CLI"的快路径。
    ///
    /// user 消息永远是 `.single`（不参与 grouping），所以只扫 `.single`。
    func drainQueuedEntries() {
        guard let session = agentSession else { return }
        for entry in messages {
            guard case .single(let single) = entry, single.delivery == .queued else { continue }
            writeSingleToCLI(single, session: session)
        }
    }

    /// 将所有当前 `.queued` 的 user entry 打成 `.failed`（bootstrap 失败 /
    /// 进程异常退出都走这里）。已 `.confirmed` 的保持不变。
    func failQueuedEntries(reason: String) {
        for idx in messages.indices {
            guard case .single(var single) = messages[idx],
                  single.delivery == .queued else { continue }
            single.delivery = .failed(reason: reason)
            messages[idx] = .single(single)
        }
    }
}

// MARK: - Private impl

private extension SessionHandle2 {

    // MARK: Worktree

    func provisionWorktreeIfNeeded() throws -> Worktree {
        guard let origin = originPath else {
            throw Worktree.Error.notGitRepository(path: "(nil originPath)")
        }
        return try Worktree.create(from: origin, sourceBranch: worktreeBranch)
    }

    // MARK: Title generation

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

    // MARK: Configuration persistence

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

    // MARK: Bootstrap

    func bootstrap(configuration: SessionConfiguration, fresh: Bool) async {
        let session = AgentSDK.Session(configuration: configuration)
        session.lastKnownSessionId = sessionId
        attachCallbacks(to: session)

        do {
            try await session.start()
        } catch {
            appLog(.error, "SessionHandle2", "bootstrap FAILED \(sessionId) err=\(error)")
            self.termination = error.localizedDescription
            self.status = .stopped
            self.repository.updateError(sessionId, error: error.localizedDescription)
            failQueuedEntries(reason: "bootstrap failed")
            return
        }

        // stdin 真正就绪后才暴露 agentSession，避免 send() 在 start() 完成前写入
        // stdin（writeJSON guard 了 nil pipe，但保持不变量更清晰）。
        self.agentSession = session

        _ = await withCheckedContinuation { (cont: CheckedContinuation<InitializeResponse?, Never>) in
            session.initialize(promptSuggestions: true) { cont.resume(returning: $0) }
        }

        status = .idle
        if fresh {
            repository.updateStatus(sessionId, to: .created)
        }
        drainQueuedEntries()
        appLog(.info, "SessionHandle2", "bootstrap done \(sessionId) fresh=\(fresh)")
    }

    // MARK: Callbacks

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

        failQueuedEntries(reason: "session stopped")

        repository.updateError(sessionId, error: desc)
    }

    // MARK: Message construction

    /// 把下游 `SessionMessage` 打包成一条 `.queued` user `SingleEntry`。
    /// entry.id 同时作为随消息发给 CLI 的 `uuid` 字段（CLI echo 时按此匹配）。
    func makeQueuedSingle(for message: SessionMessage) -> SingleEntry {
        let entryId = UUID()
        let uuidString = entryId.uuidString.lowercased()
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
                "uuid": uuidString,
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
                "uuid": uuidString,
            ]
        }
        let msg = (try? Message2(json: raw)) ?? Message2.unknown(name: "user", raw: raw)
        return SingleEntry(id: entryId, message: msg, delivery: .queued, toolResults: [:])
    }

    func writeSingleToCLI(_ entry: SingleEntry, session: AgentSDK.Session) {
        guard let text = textFromEntry(entry) else { return }
        session.sendMessage(text, extra: ["uuid": entry.id.uuidString.lowercased()])
    }

    func textFromEntry(_ entry: SingleEntry) -> String? {
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

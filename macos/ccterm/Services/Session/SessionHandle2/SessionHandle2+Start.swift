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

    /// 发送文本消息。语义见 `enqueueAndSend(_:)`。
    /// `planContent` 透传给 CLI 的 `plan_content` 字段（ExitPlanMode 场景）。
    func send(text: String, planContent: String? = nil) {
        enqueueAndSend(LocalUserInput(text: text, image: nil, planContent: planContent))
    }

    /// 发送图片消息。`caption` 作为文字伴随 block（默认 "[image]"），image
    /// 以 base64 打包进 content array。语义见 `enqueueAndSend(_:)`。
    func send(image data: Data, mediaType: String, caption: String? = nil) {
        enqueueAndSend(LocalUserInput(
            text: caption,
            image: (data: data, mediaType: mediaType),
            planContent: nil
        ))
    }

    /// 统一发送路径：
    /// 1. 立即 append 一条 `.queued` `.localUser(input)` `SingleEntry`（UI 即时看到）。
    /// 2. 如果 session 尚未启动/已停止，自动触发 `ensureStarted()`。
    /// 3. 如果 CLI 已 attach（`agentSession != nil`），立即把消息写到 stdin；
    ///    CLI 侧自己排队，不在 Swift 侧做 flush gating。
    /// 4. CLI 吃到消息后会 echo 回一条带同 uuid 的 user 消息，`receive` 按 uuid
    ///    命中本条 entry 并把 payload 替换成 `.remote(echo)`、delivery 切 `.confirmed`。
    ///
    /// entry.id 作为 `uuid` 字段随消息发给 CLI（`--replay-user-messages` 确保
    /// CLI 原样回显），用于精确匹配。
    ///
    /// title 生成是正交能力——调用方（fresh + 首条文本场景）显式调 `generateTitle(from:)`。
    private func enqueueAndSend(_ input: LocalUserInput) {
        let single = SingleEntry(
            id: UUID(),
            payload: .localUser(input),
            delivery: .queued,
            toolResults: [:]
        )
        messages.append(.single(single))
        let entry = messages.last!
        appLog(.info, "SessionHandle2",
            "[v2-send] enqueue sid=\(sessionId.prefix(8)) entryId=\(single.id.uuidString.prefix(8)) "
            + "status=\(status) hasRecord=\(hasRecord) agentSession=\(agentSession != nil) "
            + "msgCount=\(messages.count) onChange=\(onMessagesChange != nil)")
        // turn 入口 — 在所有副作用之前 +1,view 层的 isRunning 立刻可见。
        // 同步发生在 main,@Observable 自动通知 SwiftUI 重渲染。
        pendingTurnCount += 1
        // 通知 AppKit 渲染端 — Transcript2EntryBridge 是 onMessagesChange 的
        // 唯一消费方。enqueue 必须发,不然 user bubble 要等 CLI echo 回来才
        // 显示(100~300ms 视觉黑屏)。echo 到达时走 `confirmQueuedEntry` 转
        // `.updated`,bridge 用稳定 block id 走 `.update` 通道无感替换文本。
        onMessagesChange?(.appended(entry))

        ensureStarted()

        if let session = agentSession {
            appLog(.info, "SessionHandle2",
                "[v2-send] write-immediate sid=\(sessionId.prefix(8)) entryId=\(single.id.uuidString.prefix(8))")
            writeUserEntryToCLI(single, session: session)
        } else {
            appLog(.info, "SessionHandle2",
                "[v2-send] defer-flush sid=\(sessionId.prefix(8)) entryId=\(single.id.uuidString.prefix(8)) status=\(status)")
        }
        // 否则 bootstrap 成功后 `flushBootstrapBacklog` 会把它写到 CLI。
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
        guard status == .notStarted || status == .stopped else {
            appLog(.info, "SessionHandle2",
                "[v2-send] ensureStarted SKIP sid=\(sessionId.prefix(8)) status=\(status)")
            return
        }
        appLog(.info, "SessionHandle2",
            "[v2-send] ensureStarted begin sid=\(sessionId.prefix(8)) "
            + "fresh=\(repository.find(sessionId) == nil) cwd=\(cwd ?? "(nil)") "
            + "isWorktree=\(isWorktree)")

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

    /// 把所有 `.queued` `.localUser` entry 写到 CLI。仅在 bootstrap 刚成功、
    /// `agentSession` 就绪那一刻调用一次。此后的 `send(_:)` 走"立即写 CLI"
    /// 的快路径。user 消息永远是 `.single`（不参与 grouping），所以只扫 `.single`。
    func flushBootstrapBacklog() {
        guard let session = agentSession else {
            appLog(.warning, "SessionHandle2",
                "[v2-send] flushBacklog SKIP agentSession=nil sid=\(sessionId.prefix(8))")
            return
        }
        var flushed = 0
        for entry in messages {
            guard case .single(let single) = entry,
                  single.delivery == .queued,
                  case .localUser = single.payload else { continue }
            appLog(.info, "SessionHandle2",
                "[v2-send] flushBacklog write sid=\(sessionId.prefix(8)) entryId=\(single.id.uuidString.prefix(8))")
            writeUserEntryToCLI(single, session: session)
            flushed += 1
        }
        appLog(.info, "SessionHandle2",
            "[v2-send] flushBacklog done sid=\(sessionId.prefix(8)) flushed=\(flushed) msgCount=\(messages.count)")
    }

    /// 将所有当前 `.queued` 的 user entry 打成 `.failed`（bootstrap 失败 /
    /// 进程异常退出都走这里）。已 `.confirmed` 的保持不变。
    /// 逐条 emit `.updated` 让 bridge 走 update 通道刷新 delivery 状态。
    func failQueuedEntries(reason: String) {
        for idx in messages.indices {
            guard case .single(var single) = messages[idx],
                  single.delivery == .queued else { continue }
            single.delivery = .failed(reason: reason)
            messages[idx] = .single(single)
            onMessagesChange?(.updated(messages[idx]))
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
            hasRecord = true
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
        var config = SessionConfiguration(
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

        #if DEBUG
        if let override = Self.mockCLIOverride {
            config.binaryPath = override.binaryPath
            config.customCommand = nil
            config.env = override.env
        }
        #endif

        return config
    }

    // MARK: Bootstrap

    func bootstrap(configuration: SessionConfiguration, fresh: Bool) async {
        appLog(.info, "SessionHandle2",
            "[v2-send] bootstrap enter sid=\(sessionId.prefix(8)) fresh=\(fresh) "
            + "resume=\(configuration.resume ?? "(nil)") wd=\(configuration.workingDirectory.path)")
        let session = AgentSDK.Session(configuration: configuration)
        session.lastKnownSessionId = sessionId
        attachCallbacks(to: session)

        do {
            try await session.start()
        } catch {
            // sync 启动失败(chdir 不到 / binary 找不到) — 走统一 failLaunch。
            failLaunch(reason: "\(error)")
            return
        }
        appLog(.info, "SessionHandle2",
            "[v2-send] bootstrap start-ok sid=\(sessionId.prefix(8)) status-before-attach=\(status)")

        // stdin 真正就绪后才暴露 agentSession，避免 send() 在 start() 完成前写入
        // stdin（writeJSON guard 了 nil pipe，但保持不变量更清晰）。
        self.agentSession = session

        // Race:initialize completion vs 进程死亡。CLI 可能起来后秒退
        // (--resume 找不到 JSONL 等),此时 initialize 的 control response
        // 永远不会回来,SDK 的 `pendingControlResponses` 不会被进程退出 fire
        // 掉,光等会一直挂。挂一把 `bootstrapExitHook`,让 handleProcessExit
        // 把死讯转发回这把 continuation,统一走 failLaunch。
        let initResp: InitializeResponse? = await withCheckedContinuation { (cont: CheckedContinuation<InitializeResponse?, Never>) in
            var resumed = false
            let resume: (InitializeResponse?) -> Void = { resp in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: resp)
            }
            self.bootstrapExitHook = { _ in resume(nil) }
            session.initialize(promptSuggestions: true) { resp in
                Task { @MainActor in resume(resp) }
            }
        }
        self.bootstrapExitHook = nil

        // 如果在等 init 的过程中进程死了,handleProcessExit 已经在自己那条
        // 路径上调了 failLaunch(status 翻 .stopped),这里 short-circuit。
        guard status == .starting else {
            appLog(.info, "SessionHandle2",
                "[v2-send] bootstrap aborted-during-init sid=\(sessionId.prefix(8)) status=\(status)")
            return
        }

        appLog(.info, "SessionHandle2",
            "[v2-send] bootstrap initialize-done sid=\(sessionId.prefix(8)) "
            + "respNil=\(initResp == nil) status=\(status)")

        status = .idle
        if fresh {
            repository.updateStatus(sessionId, to: .created)
        }
        flushBootstrapBacklog()
        appLog(.info, "SessionHandle2", "[v2-send] bootstrap done sid=\(sessionId.prefix(8)) fresh=\(fresh)")
    }

    /// 所有 CLI launch-time 失败的统一收口:sync `Process.run()` 抛错、init
    /// 完成前 CLI 自己 exit 非零都来这里。
    ///
    /// 副作用按"就让 UI 立即可见"的顺序排:status / pendingTurnCount 先翻,
    /// agentSession 摘掉,queued entries 标失败,repo 写错误,最后 onLaunchFailure
    /// 通知订阅方(SessionManager2)弹 alert。
    ///
    /// 入参 `reason` 直接对外用,**不做本地化处理**——`String(describing: error)`
    /// 给出 SDK enum 完整原貌,`process exited (code N): <stderr>` 给出 CLI 自己
    /// 的原始 stderr。
    func failLaunch(reason: String) {
        appLog(.error, "SessionHandle2",
            "[v2-send] failLaunch sid=\(sessionId.prefix(8)) reason=\(reason)")
        self.termination = reason
        self.status = .stopped
        self.pendingTurnCount = 0
        self.agentSession = nil
        self.stderrBuffer = ""
        for pending in pendingPermissions {
            pending.respond(.deny(reason: "Launch failed"))
        }
        pendingPermissions.removeAll()
        failQueuedEntries(reason: reason)
        repository.updateError(sessionId, error: reason)
        onLaunchFailure?(reason)
    }

    // MARK: Callbacks

    func attachCallbacks(to session: AgentSDK.Session) {
        let sidPrefix = sessionId.prefix(8)
        session.onMessage = { [weak self] msg in
            let kind: String
            switch msg {
            case .user: kind = "user"
            case .assistant: kind = "assistant"
            case .result: kind = "result"
            case .system(.`init`): kind = "system.init"
            case .system: kind = "system.other"
            default: kind = "other"
            }
            appLog(.info, "SessionHandle2", "[v2-send] onMessage sid=\(sidPrefix) kind=\(kind)")
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
        appLog(.warning, "SessionHandle2",
            "[v2-send] processExit sid=\(sessionId.prefix(8)) code=\(code) stderr=\(trimmed ?? "(empty)")")

        // bootstrap init 等待期间死亡 → 解开 init 的 continuation,然后走
        // 统一 failLaunch。bootstrap 那边 short-circuit 收尾。
        if let hook = bootstrapExitHook {
            bootstrapExitHook = nil
            hook(code)
            failLaunch(reason: desc)
            return
        }

        // 已运行后死亡 — 常规清理(无 alert)。
        stderrBuffer = ""
        agentSession = nil
        termination = desc
        status = .stopped
        // 进程死了 — 所有在飞 turn 都不可能再 .result 回来,归零防止 isRunning 卡住。
        pendingTurnCount = 0

        for pending in pendingPermissions {
            pending.respond(.deny(reason: "Process exited"))
        }
        pendingPermissions.removeAll()

        failQueuedEntries(reason: "session stopped")

        repository.updateError(sessionId, error: desc)
    }

    // MARK: Outgoing wire

    /// 把一条 `.localUser` SingleEntry 写到 CLI stdin。`.remote` 或非 user entry
    /// 直接忽略——只有本地尚未 echo 的 entry 才有 outgoing 职责。
    ///
    /// - text-only：走 string-content 的 `sendMessage(_:extra:)`。
    /// - 带 image：构造 text + image(base64) 的 content array，走
    ///   `sendMessage(contentBlocks:extra:)`。
    ///
    /// `entry.id` 作为 `uuid` extra 伴随发出，CLI 在 `--replay-user-messages`
    /// 开启下原样回显，用于 `confirmQueuedEntry` 的精确匹配。
    func writeUserEntryToCLI(_ entry: SingleEntry, session: AgentSDK.Session) {
        guard case .localUser(let input) = entry.payload else {
            appLog(.warning, "SessionHandle2",
                "[v2-send] writeCLI SKIP not-localUser entryId=\(entry.id.uuidString.prefix(8))")
            return
        }
        appLog(.info, "SessionHandle2",
            "[v2-send] writeCLI sid=\(sessionId.prefix(8)) entryId=\(entry.id.uuidString.prefix(8)) "
            + "textLen=\(input.text?.count ?? 0) hasImage=\(input.image != nil)")
        var extra: [String: Any] = ["uuid": entry.id.uuidString.lowercased()]
        if let plan = input.planContent {
            extra["plan_content"] = plan
        }

        if let (data, mediaType) = input.image {
            var blocks: [[String: Any]] = []
            if let text = input.text, !text.isEmpty {
                blocks.append(["type": "text", "text": text])
            }
            blocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": data.base64EncodedString(),
                ],
            ])
            session.sendMessage(contentBlocks: blocks, extra: extra)
        } else {
            session.sendMessage(input.text ?? "", extra: extra)
        }
    }
}

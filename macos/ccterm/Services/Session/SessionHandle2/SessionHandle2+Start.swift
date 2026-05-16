import AgentSDK
import Foundation

// MARK: - Lifecycle (public)

extension SessionHandle2 {

    /// Explicitly activate the session: make sure the CLI subprocess is up
    /// and has finished initialize (slashCommands / availableModels /
    /// contextWindow are populated). Does not send a message.
    ///
    /// Idempotent: `.notStarted` / `.stopped` → kick off bootstrap; other
    /// statuses → no-op. The UI calls this when opening a session view to
    /// warm up the CLI so slash autocomplete etc. is ready.
    ///
    /// Relationship with `send(_:)`: `send` also auto-starts internally, so
    /// users sending a message directly don't need to call `activate()`
    /// first. `activate()` matters when the CLI must be ready *without*
    /// sending a message.
    func activate() {
        ensureStarted()
    }

    /// Manually stop the CLI subprocess. While active, calls `close()`; the
    /// onProcessExit callback then handles status / termination /
    /// pendingPermissions cleanup. No-op otherwise.
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

    /// Send a text message. See `enqueueAndSend(_:)` for semantics.
    /// `planContent` passes through to the CLI's `plan_content` field
    /// (ExitPlanMode scenario).
    func send(text: String, planContent: String? = nil) {
        enqueueAndSend(LocalUserInput(text: text, image: nil, planContent: planContent))
    }

    /// Send an image message. `caption` becomes a companion text block
    /// (default `"[image]"`); the image is packed as base64 into the content
    /// array. See `enqueueAndSend(_:)` for semantics.
    func send(image data: Data, mediaType: String, caption: String? = nil) {
        enqueueAndSend(
            LocalUserInput(
                text: caption,
                image: (data: data, mediaType: mediaType),
                planContent: nil
            ))
    }

    /// Unified send path:
    /// 1. Immediately append a `.queued` `.localUser(input)` `SingleEntry`
    ///    (UI sees it right away).
    /// 2. Auto-trigger `ensureStarted()` if the session is unstarted/stopped.
    /// 3. If the CLI is attached (`agentSession != nil`), write the message
    ///    to stdin immediately. The CLI handles its own queueing — Swift
    ///    does not gate flushes.
    /// 4. After the CLI consumes the message it echoes back a user message
    ///    with the same uuid; `receive` matches the entry by uuid and swaps
    ///    payload to `.remote(echo)`, delivery to `.confirmed`.
    ///
    /// `entry.id` is sent as the `uuid` field on the message (the CLI
    /// echoes it back verbatim under `--replay-user-messages`) so the match
    /// is exact.
    ///
    /// Title generation is orthogonal — the caller (the fresh + first-text
    /// flow) calls `generateTitle(from:)` explicitly.
    private func enqueueAndSend(_ input: LocalUserInput) {
        // Fresh + first text → seed the persisted title from the user's
        // message. `persistConfiguration` (called downstream by
        // `ensureStarted`) reads `self.title` when writing the record, so
        // setting it here is enough; no separate db write needed.
        if !hasRecord, title.isEmpty, let firstText = input.text {
            let derived = Self.deriveTitleFromFirstMessage(firstText)
            if !derived.isEmpty {
                title = derived
            }
        }

        let single = SingleEntry(
            id: UUID(),
            payload: .localUser(input),
            delivery: .queued,
            toolResults: [:]
        )
        messages.append(.single(single))
        let entry = messages.last!
        appLog(
            .info, "SessionHandle2",
            "[v2-send] enqueue sid=\(sessionId.prefix(8)) entryId=\(single.id.uuidString.prefix(8)) "
                + "status=\(status) hasRecord=\(hasRecord) agentSession=\(agentSession != nil) "
                + "msgCount=\(messages.count) onChange=\(onMessagesChange != nil)")
        // Turn entry — bump before any side effect so the view's isRunning
        // is visible immediately. Synchronous on main; @Observable
        // auto-notifies SwiftUI to re-render.
        pendingTurnCount += 1
        // Notify the AppKit renderer — Transcript2EntryBridge is
        // onMessagesChange's only consumer. Must emit on enqueue, otherwise
        // the user bubble would only appear after the CLI echo (100-300ms
        // of visual blank). When the echo arrives, `confirmQueuedEntry`
        // converts it to `.updated`; the bridge uses a stable block id and
        // swaps the text via `.update` invisibly.
        onMessagesChange?(.appended(entry))

        ensureStarted()

        if let session = agentSession {
            appLog(
                .info, "SessionHandle2",
                "[v2-send] write-immediate sid=\(sessionId.prefix(8)) entryId=\(single.id.uuidString.prefix(8))")
            writeUserEntryToCLI(single, session: session)
        } else {
            appLog(
                .info, "SessionHandle2",
                "[v2-send] defer-flush sid=\(sessionId.prefix(8)) entryId=\(single.id.uuidString.prefix(8)) status=\(status)"
            )
        }
        // Otherwise `flushBootstrapBacklog` writes it to the CLI after
        // bootstrap succeeds.
    }
}

// MARK: - Title generation (public)

extension SessionHandle2 {

    /// Sole entry point for title generation. Orthogonal to `activate()` —
    /// the "fresh + empty title" policy lives in the caller (ChatRouter);
    /// the handle just provides the capability.
    ///
    /// Reentrant: empty `firstMessage` or `isGeneratingTitle == true` is a
    /// no-op, so callers can retry on failure or let the user re-trigger
    /// regeneration just by calling again.
    ///
    /// Generation runs asynchronously (`Task.detached`) and does not block
    /// the caller. On success, `applyGeneratedTitle` writes back to handle
    /// and repository; on failure, `isGeneratingTitle` resets and title is
    /// untouched.
    func generateTitle(from firstMessage: String) {
        guard !firstMessage.isEmpty else { return }
        guard !isGeneratingTitle else { return }
        isGeneratingTitle = true
        launchTitleGenerationTask(firstMessage: firstMessage)
    }

    /// Apply the LLM-generated title to handle and db.
    ///
    /// Always resets `isGeneratingTitle` and writes the title. In the
    /// worktree case, the branch keeps the initial random name provisioned
    /// in `ensureStarted` (`Prompt.TitleAndBranch.branch` is discarded).
    ///
    /// Split into a standalone method so tests can drive it directly without
    /// firing a real LLM call.
    func applyGeneratedTitle(_ result: Prompt.TitleAndBranch) {
        isGeneratingTitle = false
        title = result.titleI18n
        repository.updateTitle(sessionId, title: result.titleI18n)
        appLog(.info, "SessionHandle2", "title-gen done \(sessionId) title=\(result.titleI18n)")
    }

    /// Normalize a user message into a single-line sidebar title:
    /// collapse newlines into spaces, trim surrounding whitespace, and
    /// truncate to `maxLength` characters (appending `…` when cut). Result
    /// may be empty when the input is whitespace-only — callers should
    /// guard against that.
    static func deriveTitleFromFirstMessage(_ text: String, maxLength: Int = 80) -> String {
        let oneLine =
            text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count > maxLength {
            return trimmed.prefix(maxLength) + "…"
        }
        return trimmed
    }
}

// MARK: - Internal bootstrap

extension SessionHandle2 {

    /// Idempotent startup entry. In `.notStarted` / `.stopped`, assembles
    /// configuration, provisions a worktree (fresh + isWorktree), persists
    /// config, and launches the bootstrap Task. Other statuses → no-op.
    ///
    /// Not exposed externally — callers use `activate()` or `send(_:)`.
    func ensureStarted() {
        guard status == .notStarted || status == .stopped else {
            appLog(
                .info, "SessionHandle2",
                "[v2-send] ensureStarted SKIP sid=\(sessionId.prefix(8)) status=\(status)")
            return
        }
        appLog(
            .info, "SessionHandle2",
            "[v2-send] ensureStarted begin sid=\(sessionId.prefix(8)) "
                + "fresh=\(repository.find(sessionId) == nil) cwd=\(cwd ?? "(nil)") "
                + "isWorktree=\(isWorktree)")

        status = .starting
        termination = nil
        stderrBuffer = ""

        let fresh = (repository.find(sessionId) == nil)

        // For fresh + isWorktree, provision the worktree first and
        // synchronously update cwd plus the initial branch (adj-sci-hex).
        // Later LLM rename changes branch but not cwd. Failure takes the
        // failure path (status → .stopped, no db write, no bootstrap).
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

    /// Write every `.queued` `.localUser` entry to the CLI. Called once when
    /// bootstrap just succeeded and `agentSession` becomes ready. After
    /// that, `send(_:)` takes the "write CLI immediately" fast path. User
    /// messages are always `.single` (never grouped), so we only scan
    /// `.single`.
    func flushBootstrapBacklog() {
        guard let session = agentSession else {
            appLog(
                .warning, "SessionHandle2",
                "[v2-send] flushBacklog SKIP agentSession=nil sid=\(sessionId.prefix(8))")
            return
        }
        var flushed = 0
        for entry in messages {
            guard case .single(let single) = entry,
                single.delivery == .queued,
                case .localUser = single.payload
            else { continue }
            appLog(
                .info, "SessionHandle2",
                "[v2-send] flushBacklog write sid=\(sessionId.prefix(8)) entryId=\(single.id.uuidString.prefix(8))")
            writeUserEntryToCLI(single, session: session)
            flushed += 1
        }
        appLog(
            .info, "SessionHandle2",
            "[v2-send] flushBacklog done sid=\(sessionId.prefix(8)) flushed=\(flushed) msgCount=\(messages.count)")
    }

    /// Mark every currently `.queued` user entry as `.failed` (bootstrap
    /// failure / process abort). Already-`.confirmed` entries are untouched.
    /// Emits one `.updated` per entry so the bridge's update channel can
    /// refresh delivery state.
    func failQueuedEntries(reason: String) {
        for idx in messages.indices {
            guard case .single(var single) = messages[idx],
                single.delivery == .queued
            else { continue }
            single.delivery = .failed(reason: reason)
            messages[idx] = .single(single)
            onMessagesChange?(.updated(messages[idx]))
        }
    }
}

// MARK: - Private impl

extension SessionHandle2 {

    // MARK: Worktree

    fileprivate func provisionWorktreeIfNeeded() throws -> Worktree {
        guard let origin = originPath else {
            throw Worktree.Error.notGitRepository(path: "(nil originPath)")
        }
        return try Worktree.create(from: origin, sourceBranch: worktreeBranch)
    }

    // MARK: Title generation

    fileprivate func launchTitleGenerationTask(firstMessage: String) {
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

    fileprivate func persistConfiguration(fresh: Bool) {
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
            repository.updateExtra(
                sessionId,
                with: SessionExtraUpdate(
                    pluginDirs: pluginDirectories,
                    permissionMode: permissionMode.rawValue,
                    addDirs: additionalDirectories,
                    model: model,
                    effort: effort?.rawValue
                ))
            appLog(.info, "SessionHandle2", "persistConfiguration resume overwrite \(sessionId)")
        }
    }

    fileprivate func currentExtra() -> SessionExtra {
        SessionExtra(
            pluginDirs: pluginDirectories.isEmpty ? nil : pluginDirectories,
            permissionMode: permissionMode.rawValue,
            addDirs: additionalDirectories.isEmpty ? nil : additionalDirectories,
            model: model,
            effort: effort?.rawValue
        )
    }

    fileprivate func makeAgentConfig(fresh: Bool) -> SessionConfiguration {
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

        return config
    }

    // MARK: Bootstrap

    fileprivate func bootstrap(configuration: SessionConfiguration, fresh: Bool) async {
        appLog(
            .info, "SessionHandle2",
            "[v2-send] bootstrap enter sid=\(sessionId.prefix(8)) fresh=\(fresh) "
                + "resume=\(configuration.resume ?? "(nil)") wd=\(configuration.workingDirectory.path)")
        let session = AgentSDK.Session(configuration: configuration)
        session.lastKnownSessionId = sessionId
        attachCallbacks(to: session)

        do {
            try await session.start()
        } catch {
            // Sync startup failure (chdir / binary missing) — funnel through
            // the unified failLaunch.
            failLaunch(reason: "\(error)")
            return
        }
        appLog(
            .info, "SessionHandle2",
            "[v2-send] bootstrap start-ok sid=\(sessionId.prefix(8)) status-before-attach=\(status)")

        // Only expose `agentSession` once stdin is actually ready, so
        // `send()` can't write before `start()` completes (writeJSON does
        // guard nil pipes, but keeping the invariant tight is clearer).
        self.agentSession = session

        // Race: initialize completion vs process death. The CLI may start
        // and die instantly (e.g. `--resume` can't find the JSONL); in that
        // case the initialize control response never arrives, the SDK's
        // `pendingControlResponses` is not fired by process exit, and we'd
        // hang forever. The `bootstrapExitHook` lets handleProcessExit
        // forward the death back to this continuation so we route through
        // failLaunch.
        let initResp: InitializeResponse? = await withCheckedContinuation {
            (cont: CheckedContinuation<InitializeResponse?, Never>) in
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

        // If the process died while waiting for init, handleProcessExit
        // already called failLaunch on its own path (status flipped to
        // .stopped); short-circuit here.
        guard status == .starting else {
            appLog(
                .info, "SessionHandle2",
                "[v2-send] bootstrap aborted-during-init sid=\(sessionId.prefix(8)) status=\(status)")
            return
        }

        appLog(
            .info, "SessionHandle2",
            "[v2-send] bootstrap initialize-done sid=\(sessionId.prefix(8)) "
                + "respNil=\(initResp == nil) status=\(status)")

        status = .idle
        if fresh {
            repository.updateStatus(sessionId, to: .created)
        }
        flushBootstrapBacklog()
        appLog(.info, "SessionHandle2", "[v2-send] bootstrap done sid=\(sessionId.prefix(8)) fresh=\(fresh)")
    }

    /// Single sink for every CLI launch-time failure: sync `Process.run()`
    /// throwing, or the CLI exiting non-zero before init completes.
    ///
    /// Side effects ordered for "make it visible to UI first":
    /// status / pendingTurnCount flip first, agentSession is detached,
    /// queued entries are failed, repo error is written, then
    /// onLaunchFailure notifies the subscriber (SessionManager2) to show
    /// an alert.
    ///
    /// `reason` is surfaced directly — **no localization**.
    /// `String(describing: error)` preserves the full SDK enum;
    /// `process exited (code N): <stderr>` preserves the CLI's raw stderr.
    fileprivate func failLaunch(reason: String) {
        appLog(
            .error, "SessionHandle2",
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

    fileprivate func attachCallbacks(to session: AgentSDK.Session) {
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

        // Stage-1 minimal no-ops; fill in hook / mcp / elicitation later.
        session.onHookRequest = { _ in HookResult.success() }
        session.onMCPRequest = { _ in MCPResponse.success() }
        session.onElicitationRequest = { _ in .cancel }
    }

    fileprivate func enqueuePermission(
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

    fileprivate func handleProcessExit(_ code: Int32) {
        let trimmed = stderrBuffer.isEmpty ? nil : String(stderrBuffer.prefix(500))
        let desc =
            trimmed.map { "process exited (code \(code)): \($0)" }
            ?? "process exited (code \(code))"
        appLog(
            .warning, "SessionHandle2",
            "[v2-send] processExit sid=\(sessionId.prefix(8)) code=\(code) stderr=\(trimmed ?? "(empty)")")

        // Died during bootstrap init wait → unblock the init continuation,
        // then route through the unified failLaunch. The bootstrap side
        // short-circuits its cleanup.
        if let hook = bootstrapExitHook {
            bootstrapExitHook = nil
            hook(code)
            failLaunch(reason: desc)
            return
        }

        // Died after running — normal cleanup (no alert).
        stderrBuffer = ""
        agentSession = nil
        termination = desc
        status = .stopped
        // Process is dead — no `.result` will arrive for any in-flight turn,
        // so zero this out to keep `isRunning` from getting stuck.
        pendingTurnCount = 0

        for pending in pendingPermissions {
            pending.respond(.deny(reason: "Process exited"))
        }
        pendingPermissions.removeAll()

        failQueuedEntries(reason: "session stopped")

        repository.updateError(sessionId, error: desc)
    }

    // MARK: Outgoing wire

    /// Write one `.localUser` SingleEntry to CLI stdin. `.remote` or
    /// non-user entries are ignored — only locally-not-yet-echoed entries
    /// have outgoing responsibility.
    ///
    /// - text-only: use the string-content `sendMessage(_:extra:)`.
    /// - with image: build a text + image(base64) content array and use
    ///   `sendMessage(contentBlocks:extra:)`.
    ///
    /// `entry.id` is sent as the `uuid` extra; the CLI echoes it back
    /// verbatim under `--replay-user-messages` for `confirmQueuedEntry`'s
    /// exact match.
    fileprivate func writeUserEntryToCLI(_ entry: SingleEntry, session: AgentSDK.Session) {
        guard case .localUser(let input) = entry.payload else {
            appLog(
                .warning, "SessionHandle2",
                "[v2-send] writeCLI SKIP not-localUser entryId=\(entry.id.uuidString.prefix(8))")
            return
        }
        appLog(
            .info, "SessionHandle2",
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

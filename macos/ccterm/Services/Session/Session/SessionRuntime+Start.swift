import AgentSDK
import Foundation

// MARK: - Lifecycle (public)

extension SessionRuntime {

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
        appLog(.info, "SessionRuntime", "stop() close agent \(sessionId)")
        cliClient?.close()
    }
}

// MARK: - Messaging (public)

extension SessionRuntime {

    /// Send a text message. See `enqueueAndSend(_:)` for semantics.
    /// `planContent` passes through to the CLI's `plan_content` field
    /// (ExitPlanMode scenario).
    func send(text: String, planContent: String? = nil) {
        enqueueAndSend(LocalUserInput(text: text, planContent: planContent))
    }

    /// Send a message with one or more inline images plus an optional
    /// caption. The images are packed as base64 blocks alongside the
    /// caption inside a single content array — one CLI write produces one
    /// user message on the wire, matching the JSONL replay shape. See
    /// `enqueueAndSend(_:)` for semantics.
    func send(images: [(data: Data, mediaType: String)], caption: String? = nil) {
        enqueueAndSend(
            LocalUserInput(
                text: caption,
                images: images,
                planContent: nil
            ))
    }

    /// Unified send path:
    /// 1. Immediately append a `.queued` `.localUser(input)` `SingleEntry`
    ///    (UI sees it right away).
    /// 2. Auto-trigger `ensureStarted()` if the session is unstarted/stopped.
    /// 3. If the CLI is attached (`cliClient != nil`), write the message
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
    /// Title-seeding on first-message is owned by the `Session` façade's
    /// draft-to-runtime promotion path (the runtime receives an already-
    /// titled draft); inside the runtime, `send` does not touch `title`.
    private func enqueueAndSend(_ input: LocalUserInput) {
        let single = SingleEntry(
            id: UUID(),
            payload: .localUser(input),
            delivery: .queued,
            toolResults: [:]
        )
        messages.append(.single(single))
        let entry = messages.last!
        appLog(
            .info, "SessionRuntime",
            "[v2-send] enqueue sid=\(sessionId.prefix(8)) entryId=\(single.id.uuidString.prefix(8)) "
                + "status=\(status) hasRecord=\(hasRecord) cliClient=\(cliClient != nil) "
                + "msgCount=\(messages.count) onChange=\(onMessagesChange != nil)")
        // Turn entry — flip isRunning before any side effect so the
        // view shows the spinner immediately, even before the CLI's
        // first message comes back. Synchronous on main; @Observable
        // auto-notifies SwiftUI to re-render. `receive` then takes
        // over once `.assistant` / `.result` start flowing.
        isRunning = true
        // Notify the AppKit renderer — Transcript2EntryBridge is
        // onMessagesChange's only consumer. Must emit on enqueue, otherwise
        // the user bubble would only appear after the CLI echo (100-300ms
        // of visual blank). When the echo arrives, `confirmQueuedEntry`
        // converts it to `.updated`; the bridge uses a stable block id and
        // swaps the text via `.update` invisibly.
        onMessagesChange?(.appended(entry))

        ensureStarted()

        if let session = cliClient {
            appLog(
                .info, "SessionRuntime",
                "[v2-send] write-immediate sid=\(sessionId.prefix(8)) entryId=\(single.id.uuidString.prefix(8))")
            writeUserEntryToCLI(single, session: session)
        } else {
            appLog(
                .info, "SessionRuntime",
                "[v2-send] defer-flush sid=\(sessionId.prefix(8)) entryId=\(single.id.uuidString.prefix(8)) status=\(status)"
            )
        }
        // Otherwise `flushBootstrapBacklog` writes it to the CLI after
        // bootstrap succeeds.
    }
}

// MARK: - Title generation (public)

extension SessionRuntime {

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
        // `title` is `@Observable` and `SidebarHistoryRow` reads it via
        // `session.title`, so the row re-renders on its own; the
        // `refreshRecords()` roundtrip is kept so the persisted `record.title`
        // stays current for sessions whose runtime later gets evicted (sidebar
        // falls back to `record.title`).
        onRecordPersisted?()
        appLog(.info, "SessionRuntime", "title-gen done \(sessionId) title=\(result.titleI18n)")
    }
}

// MARK: - Promotion factory

extension SessionRuntime {

    /// Construct a runtime promoted from a `SessionDraft`. The draft's
    /// `config` / `title` / presence flags are copied verbatim; if
    /// `initialInput` is non-nil it is queued as a `.queued`
    /// `.localUser` entry and `isRunning` is set so the spinner shows
    /// immediately at the moment the façade flips phase.
    ///
    /// **Does NOT kick off bootstrap.** The caller (`Session.send`) must:
    /// 1. Assign the runtime's `onMessagesChange` / `onLaunchFailure` /
    ///    `onRecordPersisted` subscribers BEFORE firing any event,
    /// 2. Fire `onMessagesChange?(.appended(queuedEntry))` if non-nil,
    /// 3. Swap its phase from `.draft` to `.active(runtime)`,
    /// 4. Call `runtime.ensureStarted()` to begin the CLI launch.
    ///
    /// Splitting construction from bootstrap is what lets the manager-
    /// registered `onRecordPersisted` survive the eager fresh-save:
    /// `ensureStarted` fires that callback synchronously, so the sink
    /// must already be attached by the time we kick it off.
    static func fromDraft(
        _ draft: SessionDraft,
        cliClientFactory: @escaping CLIClientFactory,
        initialInput: LocalUserInput? = nil
    ) -> (runtime: SessionRuntime, queuedEntry: MessageEntry?) {
        let runtime = SessionRuntime(
            sessionId: draft.sessionId,
            repository: draft.repository,
            cliClientFactory: cliClientFactory
        )
        runtime.config = draft.config
        runtime.title = draft.title
        runtime.isFocused = draft.isFocused
        runtime.hasUnread = draft.hasUnread
        // A draft-promoted runtime has no on-disk history that isn't
        // already in memory — every message will arrive via live CLI
        // events. Mark it `.loaded` so a later view-mount's
        // `loadHistory()` skips Phase A's JSONL replay; otherwise the
        // replay would re-`receive` echoes whose `.queued` window
        // already closed and `.append` them as duplicate entries.
        runtime.historyLoadState = .loaded

        if let text = initialInput?.text, runtime.title.isEmpty {
            let derived = deriveTitleFromFirstMessage(text)
            if !derived.isEmpty {
                runtime.title = derived
            }
        }

        var queuedEntry: MessageEntry? = nil
        if let initialInput {
            let single = SingleEntry(
                id: UUID(),
                payload: .localUser(initialInput),
                delivery: .queued,
                toolResults: [:]
            )
            runtime.messages.append(.single(single))
            queuedEntry = runtime.messages.last
            // Flip synchronously so `isRunning` is true the moment the
            // façade flips phase. Matches the pre-split behavior where
            // `enqueueAndSend` flipped before any side effect.
            runtime.isRunning = true
        }

        return (runtime, queuedEntry)
    }
}

// MARK: - Internal bootstrap

extension SessionRuntime {

    /// Idempotent startup entry. In `.notStarted` / `.stopped`, assembles
    /// configuration, provisions a worktree (fresh + isWorktree), persists
    /// config, and launches the bootstrap Task. Other statuses → no-op.
    ///
    /// Not exposed externally — callers use `activate()` or `send(_:)`.
    func ensureStarted() {
        guard status == .notStarted || status == .stopped else {
            appLog(
                .info, "SessionRuntime",
                "[v2-send] ensureStarted SKIP sid=\(sessionId.prefix(8)) status=\(status)")
            return
        }
        appLog(
            .info, "SessionRuntime",
            "[v2-send] ensureStarted begin sid=\(sessionId.prefix(8)) "
                + "fresh=\(repository.find(sessionId) == nil) cwd=\(cwd ?? "(nil)") "
                + "isWorktree=\(isWorktree)")

        status = .starting
        termination = nil
        stderrBuffer = ""

        let fresh = (repository.find(sessionId) == nil)

        // For fresh + isWorktree, provision the worktree on a background
        // queue. `Worktree.create` shells out to `git fetch` (15s timeout)
        // and `git worktree add` (60s), and `copyGitignoredClaudeFiles`
        // can take tens of seconds on repos with many gitignored .claude
        // assets — every git call uses `proc.waitUntilExit()` synchronously,
        // so running this on main freezes the whole UI (input bar can't
        // clear, compose card can't dismiss, watchdog logs 20+s stalls).
        //
        // GCD `DispatchQueue.global` is preferred over `Task.detached`
        // here: empirically the detached-task variant still pinned main
        // for the full duration (likely an actor-isolation inheritance
        // quirk — main-stall watchdog confirmed it). GCD has no such
        // ambiguity.
        //
        // The bootstrap dispatch was already async, so callers
        // (`send` → `ensureStarted`) already handle the defer-flush path
        // (cliClient == nil → message queued → flushed when bootstrap
        // finishes).
        if fresh, isWorktree {
            // Pre-compute the worktree name and path so the eager db row
            // already carries the final cwd / worktreeBranch — not a
            // placeholder. `Worktree.create` then takes `preferredName` and
            // uses it on the first attempt; on the (rare) branch-name
            // collision the retry loop picks a fresh name and we patch the
            // row afterwards.
            let origin = originPath
            let source = sourceBranch  // parent branch the worktree is forked from
            let proposedName = Worktree.generateName()
            let proposedBaseRepo = origin.map { Worktree.resolveBaseRepo($0) }
            let proposedPath = proposedBaseRepo.map {
                Worktree.worktreeDir(baseRepo: $0, name: proposedName)
            }

            // Eager persist: cwd / worktreeBranch reflect the proposed
            // worktree. Sidebar gets a complete row within a frame of
            // hitting send. `persistConfiguration` keys off `hasRecord`, so
            // this lands as a fresh `save` and flips `hasRecord = true`;
            // the post-worktree call below will take the update branch.
            if let proposedPath {
                self.cwd = proposedPath
            }
            self.worktreeBranch = proposedName
            persistConfiguration()

            Task { @MainActor [weak self] in
                let outcome = await WorktreeProvisioner.provision(
                    origin: origin,
                    sourceBranch: source,
                    preferredName: proposedName
                )
                guard let self else { return }
                switch outcome {
                case .success(let wt):
                    // Patch only if the collision-retry loop ended up
                    // with a different name than we proposed — rare.
                    if wt.name != proposedName {
                        appLog(
                            .info, "SessionRuntime",
                            "worktree name collision recovered: proposed=\(proposedName) actual=\(wt.name)"
                        )
                        self.cwd = wt.path
                        self.worktreeBranch = wt.name
                        self.repository.updateCwd(self.sessionId, cwd: wt.path)
                        self.repository.updateWorktreeBranch(self.sessionId, branch: wt.name)
                        self.onRecordPersisted?()
                    }
                    // The CLI conversation has never been created for
                    // this session — `makeAgentConfig` will read the
                    // `.pending` record and pick fresh mode. Do NOT
                    // try to be clever about "skip resave" here: the
                    // resume/fresh decision is owned by
                    // `shouldResumeBootstrap`, not by a flag flowing in.
                    self.continueStartup()
                case .failure(let error):
                    appLog(
                        .error, "SessionRuntime",
                        "worktree provision FAILED \(self.sessionId) err=\(error)")
                    let desc =
                        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.termination = desc
                    self.status = .stopped
                    // Persist the failure on the eagerly-saved row so
                    // the user sees the error rather than a row that
                    // silently never starts.
                    self.repository.updateError(self.sessionId, error: desc)
                    self.failQueuedEntries(reason: "worktree provision failed")
                }
            }
            return
        }

        continueStartup()
    }

    /// Tail of `ensureStarted`: persist the session config and launch the
    /// bootstrap task. Split out so the worktree async path and the local
    /// (sync) path share the same downstream handling.
    ///
    /// No `fresh` parameter: persistence keys off `hasRecord` (in-memory)
    /// and the fresh-vs-resume bootstrap decision keys off the durable
    /// `record.status` via `shouldResumeBootstrap`. Single source of truth,
    /// no caller can put the two in disagreement.
    fileprivate func continueStartup() {
        persistConfiguration()

        // UserDefaults read kept at the call site, not inside
        // `makeAgentConfig`. The tests in `SessionRuntimeBootstrapModeTests`
        // exercise `makeAgentConfig` directly; under hosted XCTest on CI
        // (macos-26 runner, no full app launch), `UserDefaults.standard`
        // reads can fault — see `cctermTests/CLAUDE.md` "No UserDefaults"
        // rule. Hoisting the read here keeps the pure-derivation function
        // safe to call from tests.
        let customCommand = UserDefaults.standard.string(forKey: "customCLICommand")
        let config = makeAgentConfig(customCommand: customCommand)
        Task { @MainActor [weak self] in
            await self?.bootstrap(configuration: config)
        }
    }

    /// Write every `.queued` `.localUser` entry to the CLI. Called once when
    /// bootstrap just succeeded and `cliClient` becomes ready. After
    /// that, `send(_:)` takes the "write CLI immediately" fast path. User
    /// messages are always `.single` (never grouped), so we only scan
    /// `.single`.
    func flushBootstrapBacklog() {
        guard let session = cliClient else {
            appLog(
                .warning, "SessionRuntime",
                "[v2-send] flushBacklog SKIP cliClient=nil sid=\(sessionId.prefix(8))")
            return
        }
        var flushed = 0
        for entry in messages {
            guard case .single(let single) = entry,
                single.delivery == .queued,
                case .localUser = single.payload
            else { continue }
            appLog(
                .info, "SessionRuntime",
                "[v2-send] flushBacklog write sid=\(sessionId.prefix(8)) entryId=\(single.id.uuidString.prefix(8))")
            writeUserEntryToCLI(single, session: session)
            flushed += 1
        }
        appLog(
            .info, "SessionRuntime",
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

extension SessionRuntime {

    // MARK: Title generation

    fileprivate func launchTitleGenerationTask(firstMessage: String) {
        // UserDefaults read kept on MainActor (not inside the detached
        // task) so the LLM-call path stays pure for testability and so
        // hosted XCTest on CI does not fault on a background
        // `UserDefaults.standard` access — see cctermTests/CLAUDE.md.
        let customCLI = UserDefaults.standard.string(forKey: "customCLICommand")

        Task.detached { [weak self] in
            let result = await TitleGenerator.generate(
                firstMessage: firstMessage,
                customCLICommand: customCLI
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let r = result {
                    self.applyGeneratedTitle(r)
                } else {
                    self.isGeneratingTitle = false
                }
            }
        }
    }

    // MARK: Configuration persistence

    fileprivate func persistConfiguration() {
        if !hasRecord {
            let record = config.toSessionRecord(sessionId: sessionId, title: title)
            repository.save(record)
            hasRecord = true
            appLog(
                .info, "SessionRuntime",
                "persistConfiguration fresh save sid=\(sessionId.prefix(8)) "
                    + "isWorktree=\(isWorktree) cwd=\(cwd ?? "(nil)") "
                    + "onRecordPersisted=\(onRecordPersisted != nil)")
            onRecordPersisted?()
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
            appLog(.info, "SessionRuntime", "persistConfiguration resume overwrite \(sessionId)")
        }
    }

    /// Build the SDK config for the next CLI launch. Consults the durable
    /// record state via `shouldResumeBootstrap` so resume vs fresh mode is
    /// derived from one source of truth — no `fresh: Bool` parameter
    /// flowing in from the caller.
    ///
    /// `customCommand` is injected rather than read from `UserDefaults`
    /// inside the function so this stays a pure derivation of handle state
    /// + caller-supplied environment. Production reads
    /// `UserDefaults.standard["customCLICommand"]` in `continueStartup`;
    /// tests pass `nil` and assert on the produced config without tripping
    /// hosted-XCTest UserDefaults faults on CI.
    func makeAgentConfig(customCommand: String?) -> SessionConfiguration {
        let useResume = Self.shouldResumeBootstrap(for: repository.find(sessionId))
        return config.toAgentSDKConfig(
            sessionId: sessionId,
            resume: useResume,
            customCommand: customCommand
        )
    }

    /// Whether the next CLI launch should resume an existing conversation
    /// (`--resume <id>`) or create a new one (`--session-id <id>`). Resume
    /// mode is valid only after the CLI has previously created a JSONL for
    /// this session — captured as `status == .created`, the marker
    /// `bootstrap` writes once `session.start()` succeeds.
    ///
    /// History: a previous design threaded a `fresh: Bool` through
    /// `continueStartup` / `makeAgentConfig` / `bootstrap`. The worktree-
    /// fresh path's success continuation passed `fresh: false` (to skip a
    /// redundant repo save) and inadvertently switched the CLI to resume
    /// mode on its very first launch — the CLI exited 1 with "No
    /// conversation found with session ID". Centralising the rule here,
    /// driven by durable state, makes that class of bug impossible.
    static func shouldResumeBootstrap(for record: SessionRecord?) -> Bool {
        record?.status == .created
    }

    // MARK: Bootstrap

    fileprivate func bootstrap(configuration: SessionConfiguration) async {
        // Snapshot the resume/fresh decision NOW so the post-init
        // `.created` update mirrors what `makeAgentConfig` just wired into
        // `configuration`. (No mutation between these reads — both happen
        // inside the same `continueStartup` on MainActor — but recomputing
        // here keeps the function self-contained.)
        let wasFresh = !Self.shouldResumeBootstrap(for: repository.find(sessionId))
        appLog(
            .info, "SessionRuntime",
            "[v2-send] bootstrap enter sid=\(sessionId.prefix(8)) fresh=\(wasFresh) "
                + "resume=\(configuration.resume ?? "(nil)") wd=\(configuration.workingDirectory.path)")
        let session: any CLIClient = cliClientFactory(configuration)
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
            .info, "SessionRuntime",
            "[v2-send] bootstrap start-ok sid=\(sessionId.prefix(8)) status-before-attach=\(status)")

        // Only expose `cliClient` once stdin is actually ready, so
        // `send()` can't write before `start()` completes (writeJSON does
        // guard nil pipes, but keeping the invariant tight is clearer).
        self.cliClient = session

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
                .info, "SessionRuntime",
                "[v2-send] bootstrap aborted-during-init sid=\(sessionId.prefix(8)) status=\(status)")
            return
        }

        appLog(
            .info, "SessionRuntime",
            "[v2-send] bootstrap initialize-done sid=\(sessionId.prefix(8)) "
                + "respNil=\(initResp == nil) status=\(status)")

        // Per-session model catalog snapshot. We deliberately do NOT
        // pipe this into `ModelStore.shared` — model-list discovery is
        // an app-launch concern owned by `ModelStore.prefetchIfNeeded()`.
        // Entangling it with session bootstrap caused the picker to
        // appear "loading" again every time a new CLI subprocess
        // started.
        if let models = initResp?.models, !models.isEmpty {
            availableModels = models
        }

        status = .idle
        if wasFresh {
            repository.updateStatus(sessionId, to: .created)
        }
        flushDeferredFastMode()
        flushBootstrapBacklog()
        appLog(.info, "SessionRuntime", "[v2-send] bootstrap done sid=\(sessionId.prefix(8)) fresh=\(wasFresh)")
    }

    /// Single sink for every CLI launch-time failure: sync `Process.run()`
    /// throwing, or the CLI exiting non-zero before init completes.
    ///
    /// Side effects ordered for "make it visible to UI first":
    /// status / isRunning flip first, cliClient is detached,
    /// queued entries are failed, repo error is written, then
    /// onLaunchFailure notifies the subscriber (SessionManager) to show
    /// an alert.
    ///
    /// `reason` is surfaced directly — **no localization**.
    /// `String(describing: error)` preserves the full SDK enum;
    /// `process exited (code N): <stderr>` preserves the CLI's raw stderr.
    fileprivate func failLaunch(reason: String) {
        appLog(
            .error, "SessionRuntime",
            "[v2-send] failLaunch sid=\(sessionId.prefix(8)) reason=\(reason)")
        self.termination = reason
        self.status = .stopped
        self.isRunning = false
        self.cliClient = nil
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

    fileprivate func attachCallbacks(to session: any CLIClient) {
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
            appLog(.info, "SessionRuntime", "[v2-send] onMessage sid=\(sidPrefix) kind=\(kind)")
            Task { @MainActor [weak self] in
                self?.receive(msg, mode: .live)
            }
        }

        session.onPermissionRequest = { [weak self] request, completion in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(.deny(reason: "SessionRuntime deallocated"))
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
            .warning, "SessionRuntime",
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
        cliClient = nil
        termination = desc
        status = .stopped
        // Process is dead — no `.result` will arrive for any in-flight turn,
        // so clear isRunning explicitly to keep the spinner from getting stuck.
        isRunning = false

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
    fileprivate func writeUserEntryToCLI(_ entry: SingleEntry, session: any CLIClient) {
        guard case .localUser(let input) = entry.payload else {
            appLog(
                .warning, "SessionRuntime",
                "[v2-send] writeCLI SKIP not-localUser entryId=\(entry.id.uuidString.prefix(8))")
            return
        }
        appLog(
            .info, "SessionRuntime",
            "[v2-send] writeCLI sid=\(sessionId.prefix(8)) entryId=\(entry.id.uuidString.prefix(8)) "
                + "textLen=\(input.text?.count ?? 0) imageCount=\(input.images.count)")
        var extra: [String: Any] = ["uuid": entry.id.uuidString.lowercased()]
        if let plan = input.planContent {
            extra["plan_content"] = plan
        }

        if !input.images.isEmpty {
            var blocks: [[String: Any]] = []
            if let text = input.text, !text.isEmpty {
                blocks.append(["type": "text", "text": text])
            }
            for (data, mediaType) in input.images {
                blocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mediaType,
                        "data": data.base64EncodedString(),
                    ],
                ])
            }
            session.sendMessage(contentBlocks: blocks, extra: extra)
        } else {
            session.sendMessage(input.text ?? "", extra: extra)
        }
    }
}

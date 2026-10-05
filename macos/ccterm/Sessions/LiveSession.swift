import AgentSDK
import Combine
import Foundation

/// One session a CLI runs (or is about to run) for ccterm: owns the AgentSDK
/// `Session` and folds its events, and the answers of its RPCs, into `state`.
/// Only `SessionStore` makes and holds these; everything else reaches a
/// session through the store, by transcript URL.
///
/// It exists from the moment a launch is asked for — in `.starting`, holding
/// what is sent meanwhile — until the store drops it, so the transcript URL
/// never passes through "at rest" while a CLI is coming or being replaced. A
/// restart into another account replaces the process inside this instance
/// (`restart(_:configuration:)`), for the same reason.
@MainActor
final class LiveSession {
    /// Where the CLI writes this session — its identity everywhere in the app.
    let transcriptURL: URL

    /// The session as it stands; set on the main actor only, so a subscriber
    /// gets the current value at once.
    @Published private(set) var state: SessionState

    /// What the catalog offers now: the store keeps it current. The rules of
    /// a change (what it brings along) read it.
    var catalog = ModelCatalog()

    private var session: Session?
    private var events: Task<Void, Never>?
    private var launching: Task<Void, Never>?
    /// Counts the processes this instance has asked for: what an earlier
    /// one reports never lands.
    private var generation = 0
    /// What the CLI was launched with, to find the changes made while it
    /// was starting.
    private var launchedSettings: SessionSettings?
    /// A `set_model` is in flight: the CLI's own `init` must not undo the chip.
    private var isSettingModel = false
    /// The requests in flight to the CLI (see `track`).
    private var rpcs: [UUID: Task<Void, Never>] = [:]

    /// A session going on from `history` — empty for a new one — on
    /// `settings`, in `.starting`. Nothing runs until `launch(_:)`.
    init(transcriptURL: URL, history: Transcript, settings: SessionSettings?) {
        self.transcriptURL = transcriptURL
        var state = SessionState(transcript: history, settings: settings)
        state.didBeginLaunch()
        self.state = state
    }

    /// Launches the CLI on whatever `configuration` resolves to — the store's
    /// account environment, the git step, the launch flags from `settings`
    /// — while `state` is `.starting`. A failure anywhere becomes `.failed`;
    /// prompts held meanwhile are sent once `initialize` answers, then any
    /// change chosen while starting.
    func launch(_ configuration: @escaping @MainActor () async throws -> SessionConfiguration) {
        generation += 1
        let mine = generation
        launching = Task { [weak self] in
            do {
                let resolved = try await configuration()
                guard let self, mine == generation, !Task.isCancelled else { return }
                let session = Session(configuration: resolved)
                self.session = session
                launchedSettings = state.settings
                events = Task { [weak self, stream = session.events] in
                    for await event in stream {
                        guard let self, mine == generation else { return }
                        didReceive(event)
                    }
                }
                let result = try await session.start()
                guard mine == generation else { return }
                await didInitialize(result, session: session, generation: mine)
            } catch {
                guard let self, mine == generation, !(error is CancellationError) else { return }
                appLog(.error, "LiveSession", "launch of \(transcriptURL.lastPathComponent) failed — \(error)")
                // A process that exited reports itself through its event.
                if case .failed = state.phase { return }
                state.didFailToLaunch(SessionFailure(launchError: error))
            }
        }
    }

    private func didInitialize(_ result: InitializationResult, session: Session, generation mine: Int) async {
        state.didLaunch(result)
        // Changes chosen while starting go first, so the prompts run on them.
        if let wanted = state.settings, let launched = launchedSettings {
            for change in Self.differences(from: launched, to: wanted) { send(change, to: session, previous: launched) }
        }
        for prompt in state.prompts where prompt.delivery == .held {
            do {
                try session.send(UserInput(prompt.text, uuid: prompt.id))
                state.didRelease(prompt: prompt.id)
            } catch {
                state.didNotSend(prompt: prompt.id, reason: String(localized: "the session ended"))
            }
        }
    }

    /// Sends a prompt — held while starting, queued while a turn runs — and
    /// shows it at once as a `LocalPrompt`.
    func send(_ text: String) {
        let input = UserInput(text)
        let delivery: LocalPrompt.Delivery
        switch state.phase {
        case .starting: delivery = .held
        case .idle: delivery = .sent
        default: delivery = .queued
        }
        state.didSend(LocalPrompt(id: input.uuid, text: text, delivery: delivery))
        guard delivery != .held else { return }
        do {
            try session?.send(input)
        } catch {
            state.didNotSend(prompt: input.uuid, reason: String(localized: "the session ended"))
        }
    }

    /// Applies `change` as its timing in the current phase says: kept for the
    /// next launch, sent now (`set_model` / `set_permission_mode` /
    /// `apply_flag_settings`, reverting on a refusal), or held until the
    /// turn's `result`. `.restart` is the store's (`restart(_:configuration:)`):
    /// here it only records the choice.
    func update(_ change: SessionSettings.Change, catalog: ModelCatalog) {
        self.catalog = catalog
        guard let before = state.settings else { return }
        let timing = state.timing(of: change)
        let after = before.applying(change, catalog: catalog)
        state.didChoose(change, timing: timing == .restart ? .atLaunch : timing, catalog: catalog)
        guard let session, timing != .atLaunch, timing != .restart else { return }
        // What the change brought along goes with it.
        var sent = [change]
        if after.fastMode != before.fastMode, change != .fastMode(after.fastMode) {
            sent.append(.fastMode(after.fastMode))
        }
        if after.permissionMode != before.permissionMode, change != .permissionMode(after.permissionMode) {
            sent.append(.permissionMode(after.permissionMode))
        }
        for item in sent where timing != .afterTurn || item == .permissionMode(after.permissionMode) {
            send(item, to: session, previous: before)
        }
    }

    /// Writes one change to the CLI; its answer or refusal lands in `state`.
    private func send(_ change: SessionSettings.Change, to session: Session, previous: SessionSettings) {
        let mine = generation
        if case .model = change { isSettingModel = true }
        track { [weak self] in
            guard let self, mine == generation else { return }
            do {
                switch change {
                case .model(let choice):
                    try await session.setModel(choice.value == "default" ? nil : choice.value)
                case .permissionMode(let mode):
                    try await session.setPermissionMode(mode)
                case .effort(let effort):
                    var settings = Settings()
                    if let effort { settings[.effortLevel] = effort } else { settings.unset(.effortLevel) }
                    try await session.applySettings(settings)
                case .fastMode(let on):
                    var settings = Settings()
                    settings[.fastMode] = on
                    try await session.applySettings(settings)
                }
                guard mine == generation else { return }
                if case .model = change { isSettingModel = false }
                state.didApply(change)
            } catch {
                guard mine == generation, !(error is CancellationError) else { return }
                if case .model = change { isSettingModel = false }
                state.didRefuse(
                    change, previous: previous, reason: Self.words(for: error, change: change, catalog: catalog))
            }
        }
    }

    /// The changes that take `launched` to `wanted`, in the order they are sent.
    static func differences(from launched: SessionSettings, to wanted: SessionSettings) -> [SessionSettings.Change] {
        var changes: [SessionSettings.Change] = []
        if wanted.model != launched.model { changes.append(.model(wanted.model)) }
        if wanted.fastMode != launched.fastMode { changes.append(.fastMode(wanted.fastMode)) }
        if wanted.effort != launched.effort { changes.append(.effort(wanted.effort)) }
        if wanted.permissionMode != launched.permissionMode { changes.append(.permissionMode(wanted.permissionMode)) }
        return changes
    }

    /// A refusal in the design's words: by the CLI's `error_code`, else its own.
    static func words(for error: Error, change: SessionSettings.Change, catalog: ModelCatalog) -> String {
        let model: String
        if case .model(let choice) = change {
            model = catalog.shortName(of: choice) ?? choice.value
        } else {
            model = ""
        }
        switch (error as? AgentSDKError)?.refusalCode {
        case "restricted_by_org", "not_offered", "unavailable_for_account":
            return String(localized: "\(model) isn’t available to your organization.")
        case "catalog_unknown", "invalid_request":
            return String(localized: "\(model) isn’t a model Claude Code knows.")
        case "auth_failed":
            return String(localized: "Claude Code couldn’t check this account for \(model).")
        case "bypass_not_launched", "bypass_restricted", "bypass_disabled":
            return String(localized: "Bypass Permissions isn’t allowed. Allow it in Settings › General, then restart.")
        case "auto_mode_fast_mode":
            return String(localized: "Auto mode isn’t available while Fast Mode is on.")
        case let code? where code.hasPrefix("auto_mode"):
            return String(localized: "Auto mode isn’t available here.")
        default:
            if case .controlRequestFailed(_, let message, _)? = error as? AgentSDKError { return message }
            return error.localizedDescription
        }
    }

    /// Withdraws the queued prompt `uuid` (`cancel_async_message`); a prompt
    /// that already left the queue stays.
    func withdraw(prompt uuid: String) {
        guard let session, state.prompts.contains(where: { $0.id == uuid && $0.delivery == .queued }) else { return }
        state.didBeginWithdraw(prompt: uuid)
        let mine = generation
        track { [weak self] in
            guard let self, mine == generation else { return }
            let cancelled = (try? await session.cancelAsyncMessage(uuid: uuid)) ?? false
            guard mine == generation else { return }
            if cancelled { state.didWithdraw(prompt: uuid) } else { state.didFailToWithdraw(prompt: uuid) }
        }
    }

    /// Forgets a returned prompt once the tab has taken its words.
    func dismiss(prompt uuid: String) {
        state.didDismiss(prompt: uuid)
    }

    /// Stops a launch in progress; the texts of the prompts it held, oldest
    /// first. Nothing (and `[]`) unless starting.
    func cancelLaunch() -> [String] {
        guard state.phase == .starting else { return [] }
        stopProcess()
        return state.didCancelLaunch()
    }

    /// Ends the process and launches again on `configuration` — resuming this
    /// session, as another account — recording `restart` as a divider. The
    /// state stays live throughout (`.starting`), never at rest.
    func restart(
        _ restart: SessionState.Restart,
        configuration: @escaping @MainActor () async throws -> SessionConfiguration
    ) {
        stopProcess()
        state.didRestart(restart)
        launch(configuration)
    }

    /// Cuts the current process loose: nothing it says counts any more.
    private func stopProcess() {
        generation += 1
        launching?.cancel()
        launching = nil
        events?.cancel()
        events = nil
        for task in rpcs.values { task.cancel() }
        rpcs = [:]
        session?.terminate()
        session = nil
        isSettingModel = false
    }

    /// Interrupts the running turn.
    func interrupt() {
        guard let session else { return }
        track {
            do { try await session.interrupt() } catch {
                appLog(.warning, "LiveSession", "interrupt failed: \(error.localizedDescription)")
            }
        }
    }

    /// Answers the request waiting on call `callID` with what `answer` makes
    /// of it, and takes it out of `state`; nothing if none waits.
    func respond(toCall callID: String, with answer: (PermissionRequest) -> PermissionDecision) {
        guard let request = state.requests.first(where: { $0.toolUseID == callID }) else { return }
        request.respond(answer(request))
        state.requests.removeAll { $0.id == request.id }
    }

    /// The uuid of the conversation's last message, for a restart's divider.
    var lastMessageUUID: String? {
        switch state.transcript.messages.last {
        case .user(let user)?: user.uuid
        case .assistant(let assistant)?: assistant.uuid
        default: nil
        }
    }

    /// Adopts the history of a resume that began before it was read.
    func adopt(history: Transcript, settings: SessionSettings?) {
        state.didReadHistory(history, settings: settings)
    }

    /// Ends the session: the CLI finishes its turn and exits.
    func close() async {
        // Stopped first: the CLI's own goodbye is not news, and its exit must
        // not show as a failure while the store is about to drop the session.
        generation += 1
        launching?.cancel()
        launching = nil
        events?.cancel()
        events = nil
        // Requests in flight are withdrawn while stdin is still open: a request
        // written after it closes is an error the SDK can't survive.
        let pending = Array(rpcs.values)
        rpcs = [:]
        for task in pending { task.cancel() }
        for task in pending { await task.value }
        let session = session
        self.session = nil
        await session?.close()
    }

    /// Runs `body` as one of this session's requests to the CLI, which
    /// `close()` and a restart let go of.
    private func track(_ body: @escaping @MainActor () async -> Void) {
        let id = UUID()
        rpcs[id] = Task { @MainActor [weak self] in
            await body()
            self?.rpcs[id] = nil
        }
    }

    // MARK: - What the CLI says

    private func didReceive(_ event: SessionEvent) {
        state.apply(event)
        guard let session else { return }
        switch event {
        case .message(.result):
            flushPendingChanges(to: session)
            readContextUsage(from: session)
        case .message(.system(.initialized(let initialized))):
            followTypedModel(initialized.model)
        default:
            break
        }
    }

    /// A turn ended: the model and Fast Mode chosen while it ran go out now.
    private func flushPendingChanges(to session: Session) {
        guard let previous = state.runningSettings else { return }
        if let model = state.pendingModel { send(.model(model), to: session, previous: previous) }
        if let fast = state.pendingFastMode { send(.fastMode(fast), to: session, previous: previous) }
    }

    private func readContextUsage(from session: Session) {
        let mine = generation
        track { [weak self] in
            // Nothing is written to a process this session has let go of.
            guard let self, mine == generation else { return }
            guard let usage = try? await session.contextUsage() else { return }
            guard mine == generation else { return }
            state.didReadContextUsage(usage)
        }
    }

    /// A `/model` typed in the session changed the model the CLI reports at
    /// each turn's start: the chip follows, unless it already shows it.
    private func followTypedModel(_ name: String) {
        guard !name.isEmpty, !isSettingModel, state.pendingModel == nil, let current = state.settings else { return }
        if let entry = catalog.model(current.model), entry.value == name || entry.resolvedModel == name { return }
        guard let choice = catalog.choice(forModelNamed: name, on: current.model.account), choice != current.model
        else { return }
        state.didApply(.model(choice))
    }
}

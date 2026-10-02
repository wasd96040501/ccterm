import AgentSDK
import Foundation

/// A session as it stands: its conversation, and — while a CLI runs it — the
/// response streaming in, the requests waiting for the reader, the prompts
/// sent from here and not yet in the transcript, and the settings it runs on.
/// A value; `SessionStore` hands out one per change.
///
/// Read from disk, it is `transcript` and the settings it last ran on
/// (`phase` `.atRest`). Kept live, it changes only through the mutators below
/// — `apply(_:)` for the CLI's events, the `did…` family for what
/// `LiveSession` did or was told by an RPC's answer. All are pure: everything
/// `LiveSession` knows about the CLI goes through them, and a test drives
/// them without a process.
nonisolated struct SessionState: Sendable {
    /// What the sidebar and the tab bar show of a live session. A session no
    /// CLI runs has none (`activity` is `nil`).
    enum Activity: Sendable, Equatable {
        /// Running, no turn.
        case idle
        /// Starting, a turn running, or compacting: the turning arc.
        case responding
        /// A request waits for the reader; wins over `responding`.
        case needsInput
        /// The CLI exited without being asked to; its message.
        case failed(message: String)
    }

    /// Where the session is in its life (design 08 *States of a session tab*).
    /// *Waiting for you* is not a phase: it is `requests` not being empty,
    /// during `responding`.
    enum Phase: Sendable, Equatable {
        /// No CLI: never started here, `/exit`, End Session, quit. The next
        /// Send resumes it.
        case atRest
        /// The CLI is launching (login-shell probe, `initialize`); prompts are
        /// held. Also after a restart until `initialize` answers again.
        case starting
        case idle
        case responding
        /// `system/status` = `compacting`.
        case compacting
        /// The CLI exited non-zero, or never launched.
        case failed(SessionFailure)
    }

    /// When a control's change lands, by phase (design 08 *Settings × state*) —
    /// what the composer says on the control (*after this turn* ◷).
    enum ChangeTiming: Sendable, Equatable {
        /// No process: kept, and passed as a flag at the next launch (resume,
        /// restart) — or held until `initialize` answers while starting.
        case atLaunch
        /// Sent now and in effect now (mode; model and Fast while idle, after
        /// the CLI's check).
        case now
        /// Sent now; the next request uses it (effort).
        case nextRequest
        /// Kept until the running turn's `result`, then sent (model and Fast
        /// while working). The chip shows it with a clock.
        case afterTurn
        /// Another account while a process runs: ends it and resumes in the
        /// new account. The tab confirms first.
        case restart
    }

    /// A restart into another account: a divider in the transcript after the
    /// message that was last when it happened.
    struct Restart: Sendable, Equatable {
        /// The uuid of the transcript's last message at the restart; `nil` when
        /// it had none.
        var afterMessage: String?
        var accountName: String
        var modelName: String
    }

    /// The conversation: what was on disk, then what the live session added.
    var transcript: Transcript
    /// The response streaming in, only the blocks `transcript` doesn't have
    /// yet; `nil` between responses. The fold that appends a finished block's
    /// message drops that block from here, so no state holds a block twice.
    /// Stream events of a subagent (`parentToolUseID`) never fold in here.
    var partial: AssistantMessage?
    /// Permission requests waiting for the reader, oldest first.
    var requests: [PermissionRequest] = []
    /// Prompts sent from here that the transcript doesn't have yet, oldest
    /// first; each leaves when the replay with its uuid is appended (or the
    /// tab dismisses a returned one).
    var prompts: [LocalPrompt] = []
    /// The settings the composer shows: what the CLI runs, with any change
    /// chosen and not yet applied folded in (`pendingModel` / `pendingFastMode`
    /// say which are waiting for the turn to end).
    var settings: SessionSettings?
    /// A model chosen while a turn runs, sent at its `result`.
    var pendingModel: ModelChoice?
    /// Fast Mode toggled while a turn runs, sent at its `result`.
    var pendingFastMode: Bool?
    /// The CLI's name for the session (`session_title_changed`).
    var title: String?
    /// How full the context is, 0…1, after the last turn (`get_context_usage`).
    var contextUsage: Double?
    /// The slash commands this session's CLI knows (`initialize`,
    /// `commands_changed`).
    var commands: [SlashCommand] = []
    /// The last choice or send the CLI refused, in words — the red line under
    /// the composer. Cleared by the next choice or send.
    var refusal: String?
    /// Restarts into another account, oldest first.
    var restarts: [Restart] = []

    /// Where the session is in its life; set by the mutators below only.
    private(set) var phase: Phase = .atRest
    /// From a prompt's `started` to its turn's result.
    private(set) var isTurnRunning = false
    /// Prompts sent that have neither started nor ended, by uuid.
    private var waitingPrompts: Set<String> = []
    /// Whether `system/status` says the CLI is compacting.
    private var isCompacting = false
    /// Queued prompts whose withdrawal is in flight: the CLI's `cancelled` for
    /// them is our own doing, not a stop that hands the words back.
    private var withdrawing: Set<String> = []
    /// What the CLI runs now of the two settings that wait for a turn's end —
    /// `settings` shows the choice, these the fact.
    private var appliedModel: ModelChoice?
    private var appliedFastMode: Bool?
    /// Whether the response in `partial` has stopped streaming (its
    /// `messageStop` came), so that dropping its last finished block ends it.
    private var partialHasStopped = false

    /// A session at rest: `transcript` as read, on `settings` — the ones it
    /// last ran on (`SessionSettings(lastOf:catalog:)`), `nil` when unknown.
    init(transcript: Transcript, settings: SessionSettings? = nil) {
        self.transcript = transcript
        self.settings = settings
    }

    /// `settings` as the CLI runs them now: without a model or Fast Mode choice
    /// that waits for the turn's end.
    var runningSettings: SessionSettings? {
        guard var running = settings else { return nil }
        if let appliedModel { running.model = appliedModel }
        if let appliedFastMode { running.fastMode = appliedFastMode }
        return running
    }

    /// Whether a CLI runs this session (or is being started for it).
    var hasProcess: Bool { phase.isRunning }

    /// `nil` while no CLI runs it; otherwise the most urgent thing true of it.
    var activity: Activity? {
        switch phase {
        case .atRest: return nil
        case .failed(let failure): return .failed(message: failure.message)
        case .starting, .responding, .compacting: return requests.isEmpty ? .responding : .needsInput
        case .idle: return requests.isEmpty ? .idle : .needsInput
        }
    }

    /// When `change` would land now (design 08 *Settings × state*). Another
    /// account is `.restart` only while a process runs; at rest, failed or
    /// starting it is `.atLaunch`.
    func timing(of change: SessionSettings.Change) -> ChangeTiming {
        settings.map { phase.timing(of: change, from: $0) } ?? .atLaunch
    }

    // MARK: - What LiveSession did, or was answered

    /// The CLI is being launched (a start, a resume, a restart).
    mutating func didBeginLaunch() {
        phase = .starting
        isTurnRunning = false
        waitingPrompts = []
        isCompacting = false
        withdrawing = []
        requests = []
        partial = nil
        partialHasStopped = false
        pendingModel = nil
        pendingFastMode = nil
    }

    /// `initialize` answered: idle, on the settings it was launched with —
    /// the CLI reports no model over stdio, and choices made while starting
    /// stay (`LiveSession` sends them next, then the held prompts).
    mutating func didLaunch(_ result: InitializationResult) {
        commands = result.commands
        appliedModel = settings?.model
        appliedFastMode = settings?.fastMode
        // The held prompts are written next: the session responds from now,
        // without an idle in between.
        for prompt in prompts where prompt.delivery == .held { waitingPrompts.insert(prompt.id) }
        phase = .idle
        refreshPhase()
    }

    /// The launch failed before `initialize` (bad folder, git refused, the CLI
    /// would not start).
    mutating func didFailToLaunch(_ failure: SessionFailure) {
        endProcessState()
        phase = .failed(failure)
        failPrompts(reason: String(localized: "Claude didn't start"), where: { $0 == .held })
    }

    /// A prompt was sent (or held, while starting): it shows at once as
    /// `prompt.delivery` says, and the session responds from now.
    mutating func didSend(_ prompt: LocalPrompt) {
        prompts.removeAll { $0.id == prompt.id }
        prompts.append(prompt)
        if prompt.delivery != .held, !prompt.delivery.isFinal { waitingPrompts.insert(prompt.id) }
        refusal = nil
        refreshPhase()
    }

    /// A held prompt was written to the CLI (`initialize` answered): queued
    /// behind a turn that runs, else sent.
    mutating func didRelease(prompt uuid: String) {
        guard let index = prompts.firstIndex(where: { $0.id == uuid }) else { return }
        prompts[index].delivery = isTurnRunning ? .queued : .sent
        waitingPrompts.insert(uuid)
        refreshPhase()
    }

    /// A prompt could not be written to the CLI.
    mutating func didNotSend(prompt uuid: String, reason: String) {
        guard let index = prompts.firstIndex(where: { $0.id == uuid }) else { return }
        prompts[index].delivery = .notSent(reason: reason)
        waitingPrompts.remove(uuid)
        refreshPhase()
    }

    /// The reader chose `change`, landing as `timing` says: the settings show
    /// it at once; `.afterTurn` keeps it pending.
    mutating func didChoose(_ change: SessionSettings.Change, timing: ChangeTiming, catalog: ModelCatalog) {
        refusal = nil
        guard let current = settings else { return }
        let next = current.applying(change, catalog: catalog)
        settings = next
        guard timing == .afterTurn else { return }
        switch change {
        case .model(let choice): pendingModel = choice == appliedModel ? nil : choice
        case .fastMode(let on): pendingFastMode = on == appliedFastMode ? nil : on
        case .effort, .permissionMode: break
        }
        // A cascade the change brought along waits with it.
        if case .model = change, next.fastMode != current.fastMode {
            pendingFastMode = next.fastMode == appliedFastMode ? nil : next.fastMode
        }
    }

    /// The CLI applied `change` (a pending one at turn end included).
    mutating func didApply(_ change: SessionSettings.Change) {
        switch change {
        case .model(let choice):
            appliedModel = choice
            if pendingModel == choice { pendingModel = nil }
            if pendingModel == nil, var current = settings, current.model != choice {
                current.model = choice
                settings = current
            }
        case .fastMode(let on):
            appliedFastMode = on
            if pendingFastMode == on { pendingFastMode = nil }
            if pendingFastMode == nil, var current = settings, current.fastMode != on {
                current.fastMode = on
                settings = current
            }
        case .effort(let effort):
            if var current = settings, current.effort != effort {
                current.effort = effort
                settings = current
            }
        case .permissionMode(let mode):
            if var current = settings, current.permissionMode != mode {
                current.permissionMode = mode
                settings = current
            }
        }
    }

    /// The CLI refused `change`: the settings go back to `previous`, and
    /// `reason` is the red line under the composer.
    mutating func didRefuse(_ change: SessionSettings.Change, previous: SessionSettings, reason: String) {
        settings = previous
        switch change {
        case .model(let choice) where pendingModel == choice: pendingModel = nil
        case .fastMode(let on) where pendingFastMode == on: pendingFastMode = nil
        default: break
        }
        refusal = reason
    }

    /// A withdrawal of the queued prompt `uuid` is on its way.
    mutating func didBeginWithdraw(prompt uuid: String) {
        withdrawing.insert(uuid)
    }

    /// The queued prompt `uuid` was withdrawn (`cancel_async_message` said
    /// cancelled): it leaves.
    mutating func didWithdraw(prompt uuid: String) {
        withdrawing.remove(uuid)
        prompts.removeAll { $0.id == uuid }
        waitingPrompts.remove(uuid)
        refreshPhase()
    }

    /// The withdrawal found the prompt already out of the queue: it stays.
    mutating func didFailToWithdraw(prompt uuid: String) {
        withdrawing.remove(uuid)
    }

    /// Stop while *Starting*: no CLI, the held prompts leave and their words
    /// come back, oldest first.
    mutating func didCancelLaunch() -> [String] {
        let held = prompts.filter { $0.delivery == .held }
        prompts.removeAll { $0.delivery == .held }
        endProcessState()
        phase = .atRest
        return held.map(\.text)
    }

    /// The transcript read for a session whose launch began before it was
    /// known (a resume from a tab that had not read it).
    mutating func didReadHistory(_ history: Transcript, settings read: SessionSettings?) {
        transcript = history
        if settings == nil { settings = read }
        appliedModel = settings?.model
        appliedFastMode = settings?.fastMode
    }

    /// The tab took a returned prompt's words back into its field.
    mutating func didDismiss(prompt uuid: String) {
        prompts.removeAll { $0.id == uuid }
    }

    /// How full the context is now.
    mutating func didReadContextUsage(_ fraction: Double) {
        contextUsage = min(max(fraction, 0), 1)
    }

    /// The process was ended to resume as another account: a divider, and
    /// starting again.
    mutating func didRestart(_ restart: Restart) {
        failPrompts(
            reason: String(localized: "the session restarted"), where: { $0 == .sent || $0 == .queued })
        restarts.append(restart)
        didBeginLaunch()
    }

    // MARK: - The CLI's events

    /// Folds one event of the live session: messages into `transcript`
    /// (`Transcript.append`) and `partial` (stream events), requests in and
    /// out, a turn's start (`commandLifecycle` started) and end (`result`),
    /// the process's exit.
    mutating func apply(_ event: SessionEvent) {
        switch event {
        case .message(let message):
            apply(message)
        case .permissionRequest(let request):
            requests.append(request)
        case .permissionRequestCancelled(let id):
            requests.removeAll { $0.id == id }
        case .flagSettingsChanged(let patch):
            applyFlagSettings(patch)
        case .exited(let termination):
            endProcessState()
            failPrompts(reason: String(localized: "the session ended"), where: { $0 != .returned })
            // A clean exit nobody asked for is the reader's `/exit`: the
            // session is at rest, not failed.
            phase = termination.exitCode != 0 ? .failed(SessionFailure(termination)) : .atRest
        }
    }

    /// A typed `/effort` or `/fast` changed a setting: the patch the CLI applied.
    private mutating func applyFlagSettings(_ patch: JSONValue) {
        guard var current = settings else { return }
        if let level = patch["effortLevel"] {
            current.effort = level.stringValue.flatMap(Effort.init(rawValue:))
        }
        if let fast = patch["fastMode"] {
            let on = fast.boolValue ?? false
            current.fastMode = on
            appliedFastMode = on
            pendingFastMode = nil
            if on, current.permissionMode == .auto { current.permissionMode = .default }
        }
        settings = current
    }

    /// The process is gone: nothing is running, nothing waits for the reader.
    private mutating func endProcessState() {
        isTurnRunning = false
        isCompacting = false
        waitingPrompts = []
        withdrawing = []
        requests = []
        partial = nil
        pendingModel = nil
        pendingFastMode = nil
    }

    /// Marks every prompt `matches` accepts, still waiting on the CLI, not sent.
    private mutating func failPrompts(reason: String, where matches: (LocalPrompt.Delivery) -> Bool) {
        for index in prompts.indices where matches(prompts[index].delivery) && !prompts[index].delivery.isFinal {
            prompts[index].delivery = .notSent(reason: reason)
        }
    }

    /// `idle` or `responding` (or `compacting`) from what is going on, while a
    /// process runs.
    private mutating func refreshPhase() {
        switch phase {
        case .idle, .responding, .compacting:
            if isCompacting {
                phase = .compacting
            } else {
                phase = isTurnRunning || !waitingPrompts.isEmpty ? .responding : .idle
            }
        case .atRest, .starting, .failed:
            break
        }
    }

    private mutating func apply(_ message: Message) {
        switch message {
        case .streamEvent(let event):
            apply(event)
        case .assistant(let assistant):
            if assistant.parentToolUseID == nil, var streaming = partial, streaming.messageID == assistant.messageID {
                streaming.content.removeFirst(min(assistant.content.count, streaming.content.count))
                partial = streaming.content.isEmpty && partialHasStopped ? nil : streaming
            }
            transcript.append(message)
        case .user(let user):
            transcript.append(message)
            // The replay of a prompt written here: the transcript has it now,
            // and its message takes the local bubble's place.
            if user.isReplay, user.parentToolUseID == nil, let uuid = user.uuid {
                prompts.removeAll { $0.id == uuid }
                waitingPrompts.remove(uuid)
                refreshPhase()
            }
        case .system(let system):
            apply(system)
            transcript.append(message)
        case .result(let result):
            isTurnRunning = false
            // The prompts the turn consumed, whether or not their lifecycle
            // was reported; one whose replay is in the transcript has done its
            // part.
            waitingPrompts.subtract(result.userMessageUUIDs)
            let consumed = Set(result.userMessageUUIDs)
            prompts.removeAll { consumed.contains($0.id) && transcript.containsUser($0.id) }
            partial = nil
            refreshPhase()
        case .commandLifecycle(let lifecycle):
            apply(lifecycle)
        default:
            break
        }
    }

    private mutating func apply(_ system: SystemMessage) {
        switch system {
        case .status(let status):
            isCompacting = status.status == "compacting"
            if let mode = status.permissionMode, var current = settings, current.permissionMode != mode {
                current.permissionMode = mode
                settings = current
            }
            refreshPhase()
        case .compactBoundary:
            isCompacting = false
            refreshPhase()
        case .commandsChanged(let list):
            commands = list
        case .sessionTitleChanged(let name):
            title = name
        default:
            break
        }
    }

    private mutating func apply(_ lifecycle: CommandLifecycle) {
        let uuid = lifecycle.commandUUID
        let index = prompts.firstIndex { $0.id == uuid }
        switch lifecycle.state {
        case .queued:
            // Reported even when nothing runs; only a turn in progress makes it a wait.
            if let index, isTurnRunning, prompts[index].delivery == .sent { prompts[index].delivery = .queued }
        case .started:
            isTurnRunning = true
            waitingPrompts.remove(uuid)
            if let index, !prompts[index].delivery.isFinal { prompts[index].delivery = .sent }
        case .cancelled:
            waitingPrompts.remove(uuid)
            if let index {
                if withdrawing.contains(uuid) {
                    // Our own withdrawal; the RPC's answer removes it.
                } else if !prompts[index].delivery.isFinal {
                    prompts[index].delivery = .returned
                }
            }
        case .discarded:
            waitingPrompts.remove(uuid)
            if let index, !prompts[index].delivery.isFinal {
                prompts[index].delivery = .notSent(reason: String(localized: "the session ended"))
            }
        case .refused:
            waitingPrompts.remove(uuid)
            if let index, !prompts[index].delivery.isFinal {
                prompts[index].delivery = .notSent(reason: String(localized: "Claude Code refused it"))
            }
        default:
            // `completed`: a prompt whose replay never came stays as it is.
            waitingPrompts.remove(uuid)
        }
        refreshPhase()
    }

    private mutating func apply(_ event: StreamEvent) {
        guard event.parentToolUseID == nil else { return }
        switch event.event {
        case .messageStart:
            partial = AssistantMessage(streamStart: event)
            partialHasStopped = false
        case .messageStop:
            partialHasStopped = true
            if partial?.content.isEmpty == true { partial = nil }
        default:
            partial?.apply(event)
        }
    }
}

extension LocalPrompt.Delivery {
    /// Past help from the CLI: not sent, or handed back.
    fileprivate nonisolated var isFinal: Bool {
        switch self {
        case .notSent, .returned: true
        case .held, .queued, .sent: false
        }
    }
}

extension Transcript {
    /// Whether the conversation has the user message `uuid`.
    fileprivate nonisolated func containsUser(_ uuid: String) -> Bool {
        messages.contains { message in
            if case .user(let user) = message { return user.uuid == uuid }
            return false
        }
    }
}

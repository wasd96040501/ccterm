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

    // TODO(fill B): replace the four below with a stored `phase`.
    /// Whether a CLI runs this session.
    var isLive = false
    /// Whether a turn is running, or a prompt sent waits to start one: from
    /// `didSend` until the result of the turn that consumed it, or until the
    /// prompt ends without starting (refused, cancelled while queued).
    var isResponding: Bool { isTurnRunning || !waitingPrompts.isEmpty }
    /// From a prompt's `started` to its turn's result.
    private var isTurnRunning = false
    /// Prompts sent that have neither started nor ended, by uuid.
    private var waitingPrompts: Set<String> = []
    /// How the CLI ended, when it ended without being asked to.
    var failure: Termination?
    /// Whether the response in `partial` has stopped streaming (its
    /// `messageStop` came), so that dropping its last finished block ends it.
    private var partialHasStopped = false

    /// A session at rest: `transcript` as read, on `settings` — the ones it
    /// last ran on (`SessionSettings(lastOf:catalog:)`), `nil` when unknown.
    init(transcript: Transcript, settings: SessionSettings? = nil) {
        self.transcript = transcript
        self.settings = settings
    }

    var phase: Phase {
        // TODO(fill B): stored, set by the mutators.
        if let failure { return .failed(SessionFailure(failure)) }
        guard isLive else { return .atRest }
        return isResponding ? .responding : .idle
    }

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
        // TODO(fill B)
        .atLaunch
    }

    // MARK: - What LiveSession did, or was answered

    /// The CLI is being launched (a start, a resume, a restart).
    mutating func didBeginLaunch() {
        // TODO(fill B): phase = .starting
    }

    /// `initialize` answered: idle, on the settings it reports; held prompts
    /// and held changes are LiveSession's to send next.
    mutating func didLaunch(_ result: InitializationResult) {
        // TODO(fill B): phase = .idle; commands; settings from current_model / current_permission_mode
        isLive = true
    }

    /// The launch failed before `initialize` (bad folder, git refused, the CLI
    /// would not start).
    mutating func didFailToLaunch(_ failure: SessionFailure) {
        // TODO(fill B): phase = .failed(failure); held prompts become notSent
    }

    /// A prompt was sent (or held, while starting): it shows at once as
    /// `prompt.delivery` says, and the session responds from now.
    mutating func didSend(_ prompt: LocalPrompt) {
        // TODO(fill B): prompts.append(prompt) once the page builder draws local prompts (fill F)
        waitingPrompts.insert(prompt.id)
        refusal = nil
    }

    /// The reader chose `change`, landing as `timing` says: the settings show
    /// it at once; `.afterTurn` keeps it pending.
    mutating func didChoose(_ change: SessionSettings.Change, timing: ChangeTiming, catalog: ModelCatalog) {
        // TODO(fill B)
    }

    /// The CLI applied `change` (a pending one at turn end included).
    mutating func didApply(_ change: SessionSettings.Change) {
        // TODO(fill B)
    }

    /// The CLI refused `change`: the settings go back to `previous`, and
    /// `reason` is the red line under the composer.
    mutating func didRefuse(_ change: SessionSettings.Change, previous: SessionSettings, reason: String) {
        // TODO(fill B)
    }

    /// The queued prompt `uuid` was withdrawn (`cancel_async_message` said
    /// cancelled): it leaves.
    mutating func didWithdraw(prompt uuid: String) {
        // TODO(fill B)
    }

    /// The tab took a returned prompt's words back into its field.
    mutating func didDismiss(prompt uuid: String) {
        // TODO(fill B)
    }

    /// How full the context is now.
    mutating func didReadContextUsage(_ fraction: Double) {
        // TODO(fill B)
    }

    /// The process was ended to resume as another account: a divider, and
    /// starting again.
    mutating func didRestart(_ restart: Restart) {
        // TODO(fill B)
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
        case .flagSettingsChanged:
            // TODO(fill B): a typed /effort or /fast changed a setting
            break
        case .exited(let termination):
            isLive = false
            isTurnRunning = false
            waitingPrompts = []
            requests = []
            partial = nil
            // A clean exit nobody asked for is the reader's `/exit`: the
            // session is at rest, not failed.
            if termination.exitCode != 0 { failure = termination }
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
        case .user, .system:
            transcript.append(message)
        case .result(let result):
            isTurnRunning = false
            // The prompts the turn consumed, whether or not their lifecycle
            // was reported.
            waitingPrompts.subtract(result.userMessageUUIDs)
            partial = nil
        case .commandLifecycle(let lifecycle):
            if lifecycle.state == .started {
                isTurnRunning = true
                waitingPrompts.remove(lifecycle.commandUUID)
            } else if lifecycle.state.isTerminal {
                waitingPrompts.remove(lifecycle.commandUUID)
            }
        default:
            break
        }
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

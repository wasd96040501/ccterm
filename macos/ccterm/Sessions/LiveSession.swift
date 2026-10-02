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
/// (`restart(_:)`), for the same reason.
@MainActor
final class LiveSession {
    /// Where the CLI writes this session — its identity everywhere in the app.
    let transcriptURL: URL

    /// The session as it stands; set on the main actor only, so a subscriber
    /// gets the current value at once.
    @Published private(set) var state: SessionState

    private var session: Session
    private var events: Task<Void, Never>?

    /// A session over `configuration` (its `sessionId` or `resume` names it),
    /// going on from `history` — empty for a new one. Nothing runs until
    /// `start()`.
    // TODO(fill B): becomes `init(transcriptURL:history:settings:)` in `.starting`,
    // with `launch(_:)` resolving the configuration (account env, git step)
    // asynchronously and failing into `.failed` rather than throwing.
    init(transcriptURL: URL, configuration: SessionConfiguration, history: Transcript) {
        self.transcriptURL = transcriptURL
        session = Session(configuration: configuration)
        var state = SessionState(transcript: history)
        state.isLive = true
        self.state = state
    }

    /// Launches the CLI and follows its events until it exits.
    func start() async throws {
        events = Task { [weak self, stream = session.events] in
            for await event in stream {
                guard let self else { return }
                state.apply(event)
            }
        }
        do {
            _ = try await session.start()
        } catch {
            events?.cancel()
            events = nil
            throw error
        }
    }

    /// Launches the CLI on whatever `configuration` resolves to — the store's
    /// account environment, the git step, the launch flags from `settings` —
    /// while `state` is `.starting`. A failure anywhere becomes `.failed`;
    /// prompts held meanwhile are sent once `initialize` answers, then any
    /// change chosen while starting.
    func launch(_ configuration: @escaping @MainActor () async throws -> SessionConfiguration) {
        // TODO(fill B)
    }

    /// Sends a prompt — held while starting, queued while a turn runs — and
    /// shows it at once as a `LocalPrompt`.
    func send(_ text: String) throws {
        let input = UserInput(text)
        try session.send(input)
        state.didSend(LocalPrompt(id: input.uuid, text: text, delivery: .sent))
    }

    /// Applies `change` as its timing in the current phase says: kept for the
    /// next launch, sent now (`set_model` / `set_permission_mode` /
    /// `apply_flag_settings`, reverting on a refusal), or held until the
    /// turn's `result`. `.restart` is the store's (`restart(_:)`).
    func update(_ change: SessionSettings.Change, catalog: ModelCatalog) {
        // TODO(fill B)
    }

    /// Withdraws the queued prompt `uuid` (`cancel_async_message`); a prompt
    /// that already left the queue stays.
    func withdraw(prompt uuid: String) {
        // TODO(fill B)
    }

    /// Forgets a returned prompt once the tab has taken its words.
    func dismiss(prompt uuid: String) {
        // TODO(fill B)
    }

    /// Stops a launch in progress; the texts of the prompts it held, oldest
    /// first. Nothing (and `[]`) unless starting.
    func cancelLaunch() -> [String] {
        // TODO(fill B)
        []
    }

    /// Ends the process and launches again on `configuration` — resuming this
    /// session, as another account — recording `restart` as a divider. The
    /// state stays live throughout (`.starting`), never at rest.
    func restart(
        _ restart: SessionState.Restart,
        configuration: @escaping @MainActor () async throws -> SessionConfiguration
    ) {
        // TODO(fill B)
    }

    /// Interrupts the running turn.
    func interrupt() {
        Task { [session] in
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

    /// Ends the session: the CLI finishes its turn and exits.
    func close() async {
        // Stopped first: the CLI's own goodbye is not news, and its exit must
        // not show as a failure while the store is about to drop the session.
        events?.cancel()
        events = nil
        await session.close()
    }
}

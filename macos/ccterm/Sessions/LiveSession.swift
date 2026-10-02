import AgentSDK
import Combine
import Foundation

/// One session a CLI runs for ccterm: owns the AgentSDK `Session` and folds
/// its events into `state`. Only `SessionStore` makes and holds these;
/// everything else reaches a session through the store, by transcript URL.
@MainActor
final class LiveSession {
    /// Where the CLI writes this session — its identity everywhere in the app.
    let transcriptURL: URL

    /// The session as it stands; set on the main actor only, so a subscriber
    /// gets the current value at once.
    @Published private(set) var state: SessionState

    private let session: Session
    private var events: Task<Void, Never>?

    /// A session over `configuration` (its `sessionId` or `resume` names it),
    /// going on from `history` — empty for a new one. Nothing runs until
    /// `start()`.
    init(transcriptURL: URL, configuration: SessionConfiguration, history: Transcript) {
        self.transcriptURL = transcriptURL
        session = Session(configuration: configuration)
        var state = SessionState(transcript: history)
        state.isLive = true
        self.state = state
    }

    /// Launches the CLI and follows its events until it exits.
    func start() async throws {
        // TODO(live): follow `session.events` into `state.apply(_:)` (the task
        // in `events`), then `session.start()`.
        fatalError("TODO(live): LiveSession.start")
    }

    /// Sends a prompt; a turn starts (`state.isResponding`) at once.
    func send(_ text: String) throws {
        // TODO(live): `session.send(UserInput(text))`.
        fatalError("TODO(live): LiveSession.send")
    }

    /// Interrupts the running turn.
    func interrupt() {
        // TODO(live): `session.interrupt()`, logging a failure.
    }

    /// Answers the request waiting on call `callID` with what `answer` makes
    /// of it, and takes it out of `state`; nothing if none waits.
    func respond(toCall callID: String, with answer: (PermissionRequest) -> PermissionDecision) {
        // TODO(live): find the request, `respond`, remove it from `state`.
    }

    /// Ends the session: the CLI finishes its turn and exits.
    func close() async {
        // TODO(live): `session.close()`, then stop following events.
    }
}

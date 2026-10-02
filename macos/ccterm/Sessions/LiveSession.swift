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
        events = Task { [weak self, stream = session.events] in
            for await event in stream {
                guard let self else { return }
                state.apply(event)
            }
        }
        do {
            try await session.start()
        } catch {
            events?.cancel()
            events = nil
            throw error
        }
    }

    /// Sends a prompt; a turn starts (`state.isResponding`) at once.
    func send(_ text: String) throws {
        try session.send(UserInput(text))
        state.isResponding = true
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

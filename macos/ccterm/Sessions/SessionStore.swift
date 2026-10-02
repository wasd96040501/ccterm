import AgentSDK
import Combine
import Foundation

/// Every session a tab can show, by transcript URL, and the one door for
/// talking to them: a session at rest is read from disk; a live one — started
/// or resumed here — is followed as its CLI runs. Readers never ask which:
/// `states(at:)` gives whichever is current and switches when a session goes
/// live or ends.
///
/// Live sessions outlive their tabs: closing a tab ends nothing. A session
/// stays until `end(at:)` or `endAll()`; one whose CLI exited on its own stays
/// too, as `failed`, so the sidebar can say so, until it is ended.
@MainActor
final class SessionStore {
    /// What ccterm sets in `CLAUDE_CODE_ENTRYPOINT`: the CLI records it in
    /// the transcript, which is how the library knows ccterm's sessions.
    nonisolated static let entrypoint = "ccterm"

    /// Every live session's activity, by transcript URL; a session at rest is
    /// absent. Set on the main actor only.
    @Published private(set) var activities: [URL: SessionState.Activity] = [:]

    @Published private var live: [URL: LiveSession] = [:]

    private let read: @Sendable (URL) async throws -> Transcript
    private var configuration: CLIConfiguration?
    private var directory: SessionDirectory?
    private var subscriptions: Set<AnyCancellable> = []

    /// `configurations`: how the CLI is launched (General's); `directories`:
    /// where that launch writes sessions — both must deliver on the main
    /// actor, and a new session takes the latest of each. `read` reads a
    /// transcript at rest, off the main actor.
    init(
        configurations: AnyPublisher<CLIConfiguration, Never>,
        directories: AnyPublisher<SessionDirectory, Never>,
        read: @escaping @Sendable (URL) async throws -> Transcript
    ) {
        self.read = read
        configurations.sink { [weak self] value in MainActor.assumeIsolated { self?.configuration = value } }
            .store(in: &subscriptions)
        directories.sink { [weak self] value in MainActor.assumeIsolated { self?.directory = value } }
            .store(in: &subscriptions)
    }

    // MARK: - Reading

    /// The session at `url` as it stands, then each change — newest only, so
    /// a slow reader skips to the latest. At rest that is one value, read from
    /// disk; live, every change of its state; it switches when the session
    /// goes live or ends. Throws when a transcript at rest can't be read.
    func states(at url: URL) -> AsyncThrowingStream<SessionState, Error> {
        let read = read
        let current = $live.map { $0[url] }.removeDuplicates { $0 === $1 }
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let subscription =
                current
                .map { live -> AnyPublisher<SessionState, Error> in
                    if let live { return live.$state.setFailureType(to: Error.self).eraseToAnyPublisher() }
                    return Deferred {
                        Future { promise in
                            nonisolated(unsafe) let promise = promise
                            Task.detached {
                                do { promise(.success(SessionState(transcript: try await read(url)))) } catch {
                                    promise(.failure(error))
                                }
                            }
                        }
                    }
                    .receive(on: DispatchQueue.main)
                    .eraseToAnyPublisher()
                }
                .switchToLatest()
                .sink(
                    receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            continuation.finish(throwing: error)
                        } else {
                            continuation.finish()
                        }
                    }, receiveValue: { continuation.yield($0) })
            nonisolated(unsafe) let held = subscription
            continuation.onTermination = { _ in held.cancel() }
        }
    }

    // MARK: - Talking

    /// Starts a new session in `workingDirectory` and returns its transcript
    /// URL — the tab's identity before the CLI has written anything.
    func start(in workingDirectory: URL) async throws -> URL {
        // TODO(live): a session id; `SessionConfiguration(workingDirectory:
        // launch:)` with it, `CLAUDE_CODE_ENTRYPOINT`, partial messages on;
        // the URL from `directory.transcriptURL(forSession:workingDirectory:)`;
        // a `LiveSession` started, kept in `live`, its activity followed.
        fatalError("TODO(live): SessionStore.start")
    }

    /// Sends a prompt to the session at `url`, resuming it first when it is
    /// at rest (its history read, `resume` = its id, in its recorded cwd).
    func send(_ text: String, to url: URL) async throws {
        // TODO(live): resume when not live, then `LiveSession.send`.
        fatalError("TODO(live): SessionStore.send")
    }

    /// Interrupts the turn running at `url`; nothing if none.
    func interrupt(at url: URL) {
        live[url]?.interrupt()
    }

    /// Answers the request waiting on `callID` in the session at `url` with
    /// what `answer` makes of it; nothing if none waits.
    func respond(
        toCall callID: String, at url: URL, with answer: (PermissionRequest) -> PermissionDecision
    ) {
        live[url]?.respond(toCall: callID, with: answer)
    }

    /// Ends the live session at `url`; it is at rest after.
    func end(at url: URL) async {
        // TODO(live): close it, drop it from `live` and `activities`.
    }

    /// Ends every live session — the app is quitting.
    func endAll() async {
        // TODO(live): `end(at:)` for each, together.
    }
}

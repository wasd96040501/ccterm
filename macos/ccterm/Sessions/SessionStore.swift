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
    /// Each live session's state, followed into `activities`.
    private var followers: [URL: AnyCancellable] = [:]
    /// Sessions being resumed, so that a second prompt while the CLI starts
    /// waits for it instead of launching another on the same session id.
    private var resuming: [URL: Task<LiveSession, Error>] = [:]

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
        guard let configuration, let directory else {
            throw AgentSDKError.launchFailed("the launch settings are not known yet")
        }
        let id = UUID().uuidString.lowercased()
        var session = makeConfiguration(in: workingDirectory, launch: configuration)
        session.sessionId = id
        let url = directory.transcriptURL(forSession: id, workingDirectory: workingDirectory)
        let running = LiveSession(
            transcriptURL: url, configuration: session, history: Transcript(messages: []))
        try await running.start()
        keep(running)
        appLog(.info, "SessionStore", "started \(url.lastPathComponent) in \(workingDirectory.path)")
        return url
    }

    /// Sends a prompt to the session at `url`, resuming it first when it is
    /// at rest (its history read, `resume` = its id, in its recorded cwd).
    func send(_ text: String, to url: URL) async throws {
        if let live = live[url] {
            try live.send(text)
        } else {
            try await resume(at: url).send(text)
        }
    }

    /// The live session for `url`, started from its transcript on disk — at
    /// most once at a time per URL.
    private func resume(at url: URL) async throws -> LiveSession {
        if let pending = resuming[url] { return try await pending.value }
        // A resume that finished while this waited is already live.
        if let live = live[url] { return live }
        let pending = Task { @MainActor [self, read, configuration] () -> LiveSession in
            defer { resuming[url] = nil }
            guard let configuration else {
                throw AgentSDKError.launchFailed("the launch settings are not known yet")
            }
            let history = try await read(url)
            guard let cwd = history.metadata.cwd else {
                throw AgentSDKError.launchFailed(String(localized: "This session doesn't record the folder it ran in."))
            }
            var session = makeConfiguration(in: URL(fileURLWithPath: cwd, isDirectory: true), launch: configuration)
            session.resume = url.deletingPathExtension().lastPathComponent
            let running = LiveSession(transcriptURL: url, configuration: session, history: history)
            try await running.start()
            keep(running)
            appLog(.info, "SessionStore", "resumed \(url.lastPathComponent) in \(cwd)")
            return running
        }
        resuming[url] = pending
        return try await pending.value
    }

    private func makeConfiguration(in workingDirectory: URL, launch: CLIConfiguration) -> SessionConfiguration {
        var session = SessionConfiguration(workingDirectory: workingDirectory, launch: launch)
        session.includePartialMessages = true
        session.env["CLAUDE_CODE_ENTRYPOINT"] = Self.entrypoint
        return session
    }

    /// Keeps `session` in `live` and follows its state into `activities`.
    /// A session that exits cleanly without being asked to (the reader typed
    /// `/exit`) is at rest, and goes; one that failed stays to say so.
    private func keep(_ session: LiveSession) {
        let url = session.transcriptURL
        live[url] = session
        followers[url] = session.$state.sink { [weak self, weak session] state in
            MainActor.assumeIsolated {
                guard let self, let session else { return }
                guard let activity = state.activity else { return self.drop(session) }
                if self.activities[url] != activity { self.activities[url] = activity }
            }
        }
    }

    /// Forgets `session` — only if it is still the one at its URL.
    private func drop(_ session: LiveSession) {
        let url = session.transcriptURL
        guard live[url] === session else { return }
        live[url] = nil
        followers[url] = nil
        activities[url] = nil
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
        if let pending = resuming[url] { _ = try? await pending.value }
        guard let session = live[url] else { return }
        await session.close()
        drop(session)
        appLog(.info, "SessionStore", "ended \(url.lastPathComponent)")
    }

    /// Ends every live session — the app is quitting.
    func endAll() async {
        let urls = Set(live.keys).union(resuming.keys)
        await withTaskGroup(of: Void.self) { group in
            for url in urls { group.addTask { @MainActor in await self.end(at: url) } }
        }
    }
}

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
///
/// Every verb returns at once and never throws: what it starts shows in the
/// session's state — `.starting` with the prompt held, then `.idle` or
/// `.failed` with the reason — so a tab only ever follows `states(at:)`.
/// `start` and `send` to a session no CLI runs make its `LiveSession`
/// synchronously, in `.starting`, before anything is awaited.
///
/// A session at rest keeps the choices made in its tab here (`rest`), as a
/// session no process holds has nowhere else to put them; the next send
/// resumes on them.
@MainActor
final class SessionStore {
    /// What ccterm sets in `CLAUDE_CODE_ENTRYPOINT`: the CLI records it in
    /// the transcript, which is how the library knows ccterm's sessions.
    nonisolated static let entrypoint = "ccterm"

    /// Every live session's activity, by transcript URL; a session at rest is
    /// absent. Set on the main actor only.
    @Published private(set) var activities: [URL: SessionState.Activity] = [:]

    @Published private var live: [URL: LiveSession] = [:]
    /// Settings chosen in the tab of a session no CLI runs.
    @Published private var rest: [URL: SessionSettings] = [:]
    @Published private var catalog = ModelCatalog()
    @Published private var preferences = LaunchPreferences()

    private let launchFor: @MainActor (UUID) async throws -> CLIConfiguration
    private let branches: BranchService
    private let read: @Sendable (URL) async throws -> Transcript
    private var directory: SessionDirectory?
    private var subscriptions: Set<AnyCancellable> = []
    /// Each live session's state, followed into `activities`.
    private var followers: [URL: AnyCancellable] = [:]
    /// The transcripts tabs read, so that a resume starts from what the tab
    /// shows — kept while a tab reads it, forgotten with its last reader.
    private var known: [URL: Transcript] = [:]
    /// How many `states(at:)` streams read each session.
    private var readers: [URL: Int] = [:]
    /// Where each session's CLI works: what a restart or a resume launches in.
    private var workingDirectories: [URL: URL] = [:]

    /// `launch`: how the CLI is launched for an account (its id), secrets
    /// read. `directories`: where launches write sessions. `catalog`: what
    /// each account offers — to map a transcript's last model onto an account
    /// and to apply a change's cascades. `preferences`: General's (Allow
    /// Bypass Permissions). The publishers deliver on the main actor; a new
    /// launch takes the latest of each. `branches`: the git step of a launch.
    /// `read` reads a transcript at rest, off the main actor.
    init(
        launch: @escaping @MainActor (UUID) async throws -> CLIConfiguration,
        directories: AnyPublisher<SessionDirectory, Never>,
        catalog: AnyPublisher<ModelCatalog, Never>,
        preferences: AnyPublisher<LaunchPreferences, Never>,
        branches: BranchService,
        read: @escaping @Sendable (URL) async throws -> Transcript
    ) {
        launchFor = launch
        self.branches = branches
        self.read = read
        directories.sink { [weak self] value in MainActor.assumeIsolated { self?.directory = value } }
            .store(in: &subscriptions)
        catalog.sink { [weak self] value in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.catalog = value
                for session in self.live.values { session.catalog = value }
            }
        }
        .store(in: &subscriptions)
        preferences.sink { [weak self] value in MainActor.assumeIsolated { self?.preferences = value } }
            .store(in: &subscriptions)
    }

    // MARK: - Reading

    /// The session at `url` as it stands, then each change — newest only, so
    /// a slow reader skips to the latest. At rest that is the transcript read
    /// from disk on the settings it last ran on (or the tab's choices since),
    /// again when the catalog or General changes; live, every change of its
    /// state; it switches when the session goes live or ends. Throws when a
    /// transcript at rest can't be read. The transcript read is known to a
    /// resume until the last stream on `url` ends.
    func states(at url: URL) -> AsyncThrowingStream<SessionState, Error> {
        readers[url, default: 0] += 1
        let read = read
        let current = $live.map { $0[url] }.removeDuplicates { $0 === $1 }
        let inputs = Publishers.CombineLatest3($catalog, $preferences, $rest.map { $0[url] }.removeDuplicates())
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let subscription =
                current
                .map { [weak self] live -> AnyPublisher<SessionState, Error> in
                    if let live { return live.$state.setFailureType(to: Error.self).eraseToAnyPublisher() }
                    let reading = Deferred {
                        Future<Transcript, Error> { promise in
                            nonisolated(unsafe) let promise = promise
                            Task.detached {
                                do { promise(.success(try await read(url))) } catch { promise(.failure(error)) }
                            }
                        }
                    }
                    return
                        reading
                        .receive(on: DispatchQueue.main)
                        .flatMap { (transcript: Transcript) -> AnyPublisher<SessionState, Error> in
                            MainActor.assumeIsolated { self?.known[url] = transcript }
                            return inputs.map { catalog, preferences, chosen in
                                SessionState(
                                    transcript: transcript,
                                    settings: chosen
                                        ?? SessionSettings(
                                            lastOf: transcript, catalog: catalog,
                                            allowsBypassPermissions: preferences.allowsBypassPermissions))
                            }
                            .setFailureType(to: Error.self).eraseToAnyPublisher()
                        }
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
            continuation.onTermination = { [weak self] _ in
                held.cancel()
                Task { @MainActor [weak self] in self?.stopReading(url) }
            }
        }
    }

    private func stopReading(_ url: URL) {
        readers[url, default: 1] -= 1
        guard readers[url] == 0 else { return }
        readers[url] = nil
        known[url] = nil
    }

    // MARK: - Talking

    /// Starts a new session as `launch` says, with `prompt` as its first
    /// message, and returns its transcript URL at once — the tab's identity
    /// before the CLI has written anything. The session is `.starting` with
    /// the prompt held from this moment; the git step, the account's launch
    /// and `initialize` follow, and a failure in any is `.failed`. The URL is
    /// known up front because ccterm mints the session id and names any
    /// worktree (`BranchService.plannedDirectory`).
    func start(_ launch: SessionLaunch, prompt: String) -> URL {
        let id = UUID().uuidString.lowercased()
        let name = BranchService.makeWorktreeName()
        let directory = directory ?? SessionDirectory(url: FileManager.default.temporaryDirectory)
        let planned = BranchService.plannedDirectory(for: launch.checkout, in: launch.folder, name: name)
        let url = directory.transcriptURL(forSession: id, workingDirectory: planned ?? launch.folder)
        let session = LiveSession(
            transcriptURL: url, history: Transcript(messages: []), settings: launch.settings)
        session.catalog = catalog
        keep(session)
        session.send(prompt)
        workingDirectories[url] = planned ?? launch.folder
        appLog(.info, "SessionStore", "starting \(url.lastPathComponent) in \(launch.folder.path)")
        session.launch { [weak self, weak session, branches] in
            guard let self, let session else { throw CancellationError() }
            let prepared = try await branches.prepare(launch.checkout, in: launch.folder, name: name)
            workingDirectories[url] = prepared.sessionDirectory
            var configuration = try await makeConfiguration(
                for: session, workingDirectory: prepared.workingDirectory)
            configuration.sessionId = id
            if let worktree = prepared.worktreeName { configuration.worktree = worktree }
            if prepared.worktreeBaseRef != nil {
                configuration.settings[.worktree] = ["baseRef": .string("head")]
            }
            return configuration
        }
        return url
    }

    /// Sends `prompt` to the session at `url`, as its phase says (design 08
    /// *Settings × state*, Send row): idle, sent; working, queued; starting,
    /// held; at rest or failed, the session is resumed — on the settings its
    /// transcript last ran on — and the prompt held until it is up.
    func send(_ prompt: String, to url: URL) {
        if let session = live[url], session.state.hasProcess {
            session.send(prompt)
        } else {
            resume(at: url, prompt: prompt)
        }
    }

    /// Applies a control's change to the session at `url` when its timing
    /// says (`SessionState.timing(of:)`); another account while a process
    /// runs restarts it, resuming as that account — the tab has confirmed.
    func update(_ change: SessionSettings.Change, at url: URL) {
        if let session = live[url] {
            if session.state.timing(of: change) == .restart, case .model(let choice) = change {
                restart(session, as: choice, applying: change)
            } else {
                session.update(change, catalog: catalog)
            }
            return
        }
        let base = rest[url] ?? known[url].flatMap { lastSettings(of: $0) }
        guard let base else { return }
        rest[url] = base.applying(change, catalog: catalog)
    }

    /// Stops a launch in progress at `url` (Stop while *Starting*): the
    /// session goes back to what it was — at rest, or gone for one that had
    /// never run — and the texts of the prompts it held come back, oldest
    /// first, for the tab to put in its field.
    func cancelLaunch(at url: URL) -> [String] {
        live[url]?.cancelLaunch() ?? []
    }

    /// Withdraws the queued prompt `uuid` at `url` (*Withdraw*).
    func withdraw(prompt uuid: String, at url: URL) {
        live[url]?.withdraw(prompt: uuid)
    }

    /// Forgets the returned prompt `uuid` at `url` once the tab has put its
    /// words back in the field.
    func dismiss(prompt uuid: String, at url: URL) {
        live[url]?.dismiss(prompt: uuid)
    }

    /// Restarts a failed session at `url` with no prompt (the failure's
    /// *Restart*): Send's resume without a prompt.
    func restart(at url: URL) {
        resume(at: url, prompt: nil)
    }

    // MARK: - Launching

    /// Resumes the session at `url` — no CLI runs it: at rest, or failed — on
    /// the settings its tab chose, else the ones it last ran on, with `prompt`
    /// held until `initialize` answers.
    private func resume(at url: URL, prompt: String?) {
        let failed = live[url]
        if let failed { drop(failed) }
        let history = failed?.state.transcript ?? known[url]
        let settings =
            rest[url] ?? failed?.state.settings
            // Unread history: the launch reads it and takes what it last ran on.
            ?? history.flatMap { lastSettings(of: $0) ?? fallbackSettings() }
        rest[url] = nil
        let id = url.deletingPathExtension().lastPathComponent
        let session = LiveSession(transcriptURL: url, history: history ?? Transcript(messages: []), settings: settings)
        session.catalog = catalog
        keep(session)
        if let prompt { session.send(prompt) }
        appLog(.info, "SessionStore", "resuming \(url.lastPathComponent)")
        session.launch { [weak self, weak session] in
            guard let self, let session else { throw CancellationError() }
            var transcript = history
            if transcript == nil {
                let read = try await read(url)
                session.adopt(history: read, settings: lastSettings(of: read) ?? fallbackSettings())
                transcript = read
            }
            guard let cwd = transcript?.metadata.cwd ?? workingDirectories[url]?.path else {
                throw AgentSDKError.launchFailed(String(localized: "This session doesn't record the folder it ran in."))
            }
            let directory = URL(fileURLWithPath: cwd, isDirectory: true)
            workingDirectories[url] = directory
            var configuration = try await makeConfiguration(for: session, workingDirectory: directory)
            configuration.resume = id
            return configuration
        }
    }

    /// Another account's model while a process runs: ends the process and
    /// resumes this session as that account, recording the divider.
    private func restart(_ session: LiveSession, as choice: ModelChoice, applying change: SessionSettings.Change) {
        session.update(change, catalog: catalog)
        let url = session.transcriptURL
        let id = url.deletingPathExtension().lastPathComponent
        let restart = SessionState.Restart(
            afterMessage: session.lastMessageUUID, accountName: catalog.account(choice.account)?.name ?? "",
            modelName: catalog.shortName(of: choice) ?? choice.value)
        let isEmpty = session.state.transcript.messages.isEmpty
        appLog(.info, "SessionStore", "restarting \(url.lastPathComponent) as another account")
        session.restart(restart) { [weak self, weak session] in
            guard let self, let session else { throw CancellationError() }
            guard let directory = workingDirectories[url] else {
                throw AgentSDKError.launchFailed(String(localized: "This session doesn't record the folder it ran in."))
            }
            var configuration = try await makeConfiguration(for: session, workingDirectory: directory)
            // Nothing written yet: there is no conversation to resume.
            if isEmpty { configuration.sessionId = id } else { configuration.resume = id }
            return configuration
        }
    }

    /// The configuration a launch of `session` runs on now: its account's
    /// environment and the flags of its settings.
    private func makeConfiguration(
        for session: LiveSession, workingDirectory: URL
    ) async throws
        -> SessionConfiguration
    {
        let settings = session.state.settings
        guard let account = settings?.model.account ?? catalog.subscription?.id else {
            throw AgentSDKError.launchFailed(String(localized: "No account is set up to run this session."))
        }
        let launch = try await launchFor(account)
        var configuration = SessionConfiguration(workingDirectory: workingDirectory, launch: launch)
        configuration.includePartialMessages = true
        configuration.env["CLAUDE_CODE_ENTRYPOINT"] = Self.entrypoint
        configuration.allowDangerouslySkipPermissions = preferences.allowsBypassPermissions
        if let settings = session.state.settings {
            if settings.model.value != "default" { configuration.model = settings.model.value }
            configuration.effort = settings.effort
            configuration.permissionMode = settings.permissionMode
            // An SDK host opts into Fast Mode with the flag setting.
            if settings.fastMode { configuration.settings[.fastMode] = true }
        }
        return configuration
    }

    private func lastSettings(of transcript: Transcript) -> SessionSettings? {
        SessionSettings(
            lastOf: transcript, catalog: catalog, allowsBypassPermissions: preferences.allowsBypassPermissions)
    }

    /// The CLI's own settings on the subscription — for a session whose last
    /// ones can't be read.
    private func fallbackSettings() -> SessionSettings? {
        guard let account = catalog.subscription ?? catalog.accounts.first else { return nil }
        return SessionSettings(
            model: .default(on: account.id), effort: nil, permissionMode: account.defaultPermissionMode ?? .default,
            fastMode: false)
    }

    // MARK: - Following

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
        guard let session = live[url] else { return }
        await session.close()
        drop(session)
        appLog(.info, "SessionStore", "ended \(url.lastPathComponent)")
    }

    /// Ends every live session — the app is quitting.
    func endAll() async {
        let urls = Set(live.keys)
        await withTaskGroup(of: Void.self) { group in
            for url in urls { group.addTask { @MainActor in await self.end(at: url) } }
        }
    }
}

import AgentSDK
import Combine
import XCTest

@testable import ccterm

/// `SessionStore`: a session at rest and the same one live, and the whole
/// life of a live one — start, talk, resume, steer, restart, end — over
/// AgentSDK's scripted stand-in CLI (`fake_cli.py`; the prompt text picks the
/// scenario, see its header).
@MainActor
final class SessionStoreTests: XCTestCase {
    private typealias Fixture = SessionCatalogFixture
    private var scratch: URL!
    private var starts: URL!
    private var cancellables = Set<AnyCancellable>()

    override func setUpWithError() throws {
        continueAfterFailure = false
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        starts = scratch.appendingPathComponent("starts.log")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - A CLI to launch

    /// A launcher that notes each start and its arguments, then becomes the
    /// fake CLI — so a test can count the CLIs that were launched and see how.
    private func fakeCLI() throws -> String {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AgentSDK/Tests/AgentSDKTests/Fixtures/fake_cli.py")
        let launcher = scratch.appendingPathComponent("claude")
        let script = """
            #!/bin/sh
            echo "$@" >> '\(starts.path)'
            exec /usr/bin/env python3 '\(fixture.path)' "$@"
            """
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        return launcher.path
    }

    private func launches() -> [String] {
        ((try? String(contentsOf: starts, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// A store whose sessions launch the fake CLI (whatever the account) and
    /// are written under `scratch`; at rest, a session reads as `history`.
    private func store(
        history: Transcript = Transcript(messages: []), allowsBypass: Bool = false
    ) throws -> SessionStore {
        // `inheritsParentEnvironment` skips the login-shell probe each start
        // would otherwise pay.
        let launch = CLIConfiguration(binaryPath: try fakeCLI(), inheritsParentEnvironment: true)
        return SessionStore(
            launch: { _ in launch },
            directories: Just(SessionDirectory(url: scratch.appendingPathComponent("projects"))).eraseToAnyPublisher(),
            catalog: Just(Fixture.catalog).eraseToAnyPublisher(),
            preferences: Just(LaunchPreferences(allowsBypassPermissions: allowsBypass)).eraseToAnyPublisher(),
            branches: BranchService(), read: { _ in history })
    }

    private func newLaunch(
        _ settings: SessionSettings = Fixture.settings("opus"), checkout: Checkout = .inPlace(switchTo: nil)
    ) -> SessionLaunch {
        SessionLaunch(folder: folder, checkout: checkout, settings: settings)
    }

    /// The first state of the session at `url` that `isDone`; fails after
    /// 20 seconds.
    @discardableResult
    private func state(
        of store: SessionStore, at url: URL, file: StaticString = #filePath, line: UInt = #line,
        where isDone: @escaping @Sendable (SessionState) -> Bool
    ) async throws -> SessionState {
        let states = store.states(at: url)
        let found = try await withThrowingTaskGroup(of: SessionState?.self) { group in
            group.addTask {
                for try await state in states where isDone(state) { return state }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        return try XCTUnwrap(found, "the session never got there", file: file, line: line)
    }

    private var folder: URL { scratch.appendingPathComponent("work", isDirectory: true) }

    /// A session started with `prompt` and idle again.
    private func startedAndSettled(_ store: SessionStore, _ prompt: String = "echo") async throws -> URL {
        let url = store.start(newLaunch(), prompt: prompt)
        try await state(of: store, at: url) {
            $0.phase == .idle && $0.prompts.isEmpty && !$0.transcript.messages.isEmpty
        }
        return url
    }

    // MARK: - At rest

    func testASessionAtRestReadsOnceFromDiskOnTheSettingsItLastRanOn() async throws {
        var assistant = AssistantMessage(
            uuid: "a", sessionID: "s", messageID: "m", model: "claude-sonnet-5-5", content: [.text("hi")])
        assistant.effort = .low
        let message = Message.user(UserMessage(content: [.text("hi")]))
        let store = try store(history: Transcript(messages: [message, .assistant(assistant)]))
        var received: [SessionState] = []
        for try await state in store.states(at: scratch.appendingPathComponent("p/a.jsonl")) {
            received.append(state)
            break
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].transcript.messages.first, message)
        XCTAssertEqual(received[0].phase, .atRest)
        XCTAssertNil(received[0].activity)
        XCTAssertEqual(received[0].settings, Fixture.settings("sonnet", effort: .low))
        XCTAssertTrue(store.activities.isEmpty)
    }

    func testAnUnreadableTranscriptThrows() async throws {
        struct Unreadable: Error {}
        let store = SessionStore.reading { _ in throw Unreadable() }
        do {
            for try await _ in store.states(at: scratch.appendingPathComponent("a.jsonl")) {}
            XCTFail("expected a throw")
        } catch is Unreadable {}
    }

    func testChoicesAtRestAreKeptAndTheNextSendResumesOnThem() async throws {
        var history = Transcript(messages: [.user(UserMessage(content: [.text("earlier")]))])
        history.metadata.cwd = folder.path
        var assistant = AssistantMessage(
            uuid: "a", sessionID: "s", messageID: "m", model: "claude-opus-5-5", content: [.text("hi")])
        assistant.effort = .high
        history.messages.append(.assistant(assistant))
        let store = try store(history: history)
        let url = scratch.appendingPathComponent("projects/p/0a1b.jsonl")
        try await state(of: store, at: url) { $0.settings != nil }

        store.update(.model(Fixture.choice("haiku")), at: url)
        store.update(.permissionMode(.plan), at: url)
        let chosen = try await state(of: store, at: url) { $0.settings?.model.value == "haiku" }
        XCTAssertEqual(chosen.settings?.permissionMode, .plan)

        store.send("echo", to: url)
        try await state(of: store, at: url) {
            $0.phase == .idle && $0.prompts.isEmpty && $0.transcript.messages.count > 2
        }
        let line = try XCTUnwrap(launches().last)
        XCTAssertTrue(line.contains("--resume 0a1b"), line)
        XCTAssertTrue(line.contains("--model haiku"), line)
        XCTAssertTrue(line.contains("--permission-mode plan"), line)
        XCTAssertTrue(line.contains("--effort high"), line)
        await store.endAll()
    }

    // MARK: - Starting

    func testStartReturnsTheURLAtOnceWithTheSessionStartingAndThePromptHeld() async throws {
        let store = try store()
        let url = store.start(newLaunch(), prompt: "echo")
        XCTAssertEqual(url.pathExtension, "jsonl")
        XCTAssertEqual(store.activities, [url: .responding])
        var first: SessionState?
        for try await state in store.states(at: url) {
            first = state
            break
        }
        XCTAssertEqual(first?.phase, .starting)
        XCTAssertEqual(first?.prompts.map(\.delivery), [.held])
        XCTAssertEqual(first?.prompts.map(\.text), ["echo"])
        await store.endAll()
    }

    func testAPromptRunsATurnAndItsReplyArrivesInPlaceOfTheLocalBubble() async throws {
        let store = try store()
        let url = store.start(newLaunch(), prompt: "echo")
        let state = try await state(of: store, at: url) { $0.phase == .idle && $0.transcript.messages.count == 2 }
        XCTAssertTrue(state.prompts.isEmpty, "the replay confirmed it")
        XCTAssertEqual(state.activity, .idle)
        guard case .assistant(let reply) = state.transcript.messages.last else { return XCTFail("no reply") }
        XCTAssertEqual(reply.content.compactMap(\.text), ["hello"])
        await store.endAll()
    }

    func testTheLaunchCarriesTheSettingsAsFlags() async throws {
        let store = try store(allowsBypass: true)
        let settings = Fixture.settings("sonnet", effort: .xhigh, mode: .acceptEdits)
        let url = store.start(newLaunch(settings), prompt: "echo")
        try await state(of: store, at: url) { $0.phase == .idle }
        let line = try XCTUnwrap(launches().first)
        XCTAssertTrue(line.contains("--model sonnet"), line)
        XCTAssertTrue(line.contains("--effort xhigh"), line)
        XCTAssertTrue(line.contains("--permission-mode acceptEdits"), line)
        XCTAssertTrue(line.contains("--allow-dangerously-skip-permissions"), line)
        XCTAssertTrue(line.contains("--session-id \(url.deletingPathExtension().lastPathComponent)"), line)
        XCTAssertTrue(line.contains("--replay-user-messages"), line)
        XCTAssertFalse(line.contains("--worktree"), line)
        await store.endAll()
    }

    func testTheDefaultModelIsNotPinnedAndFastModeIsOptedInByFlagSetting() async throws {
        let store = try store()
        let url = store.start(newLaunch(Fixture.settings("default", fast: true)), prompt: "echo")
        try await state(of: store, at: url) { $0.phase == .idle }
        let line = try XCTUnwrap(launches().first)
        XCTAssertFalse(line.contains("--model"), line)
        XCTAssertTrue(line.contains(#""fastMode":true"#), line)
        await store.endAll()
    }

    func testAWorktreeSessionHasItsTranscriptUnderTheWorktreesProject() async throws {
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let store = try store()
        let url = store.start(newLaunch(checkout: .worktree(base: .head)), prompt: "echo")
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent.contains("-claude-worktrees-"), url.path)
        try await state(of: store, at: url) { $0.phase == .idle }
        let line = try XCTUnwrap(launches().first)
        XCTAssertTrue(line.contains("--worktree "), line)
        XCTAssertTrue(line.contains(#""baseRef":"head""#), line)
        await store.endAll()
    }

    func testAPullRequestIsNamedPrN() async throws {
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let store = try store()
        let url = store.start(newLaunch(checkout: .pullRequest(327)), prompt: "echo")
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent.hasSuffix("-claude-worktrees-pr-327"), url.path)
        try await state(of: store, at: url) { $0.phase == .idle }
        XCTAssertTrue(try XCTUnwrap(launches().first).contains("--worktree #327"))
        await store.endAll()
    }

    func testAGitStepThatFailsFailsTheSessionAndReturnsTheWordsAsNotSent() async throws {
        // Not a git repository: a worktree has nowhere to be made.
        let store = try store()
        let url = store.start(newLaunch(checkout: .worktree(base: .branch("main"))), prompt: "echo")
        let state = try await state(of: store, at: url) {
            if case .failed = $0.phase { return true }
            return false
        }
        XCTAssertEqual(state.activity, .failed(message: String(localized: "Not a git repository")))
        guard case .notSent? = state.prompts.first?.delivery else { return XCTFail("the prompt vanished") }
        XCTAssertTrue(launches().isEmpty, "no CLI was started")
        await store.endAll()
    }

    func testStoppingALaunchGivesTheWordsBackAndTheSessionGoes() async throws {
        let store = try store()
        let url = store.start(newLaunch(), prompt: "echo")
        XCTAssertEqual(store.cancelLaunch(at: url), ["echo"])
        XCTAssertTrue(store.activities.isEmpty)
        await store.endAll()
    }

    // MARK: - Live

    func testAPermissionRequestWaitsUntilAnswered() async throws {
        let store = try store()
        let url = store.start(newLaunch(), prompt: "permission")
        try await state(of: store, at: url) { $0.requests.count == 1 }
        XCTAssertEqual(store.activities[url], .needsInput)

        store.respond(toCall: "toolu_1", at: url) { request in
            XCTAssertEqual(request.toolName, "Bash")
            return .allow()
        }
        let state = try await state(of: store, at: url) { $0.requests.isEmpty && $0.phase == .idle }
        XCTAssertEqual(state.activity, .idle)
        await store.endAll()
    }

    func testARequestWithdrawnByTheCLILeaves() async throws {
        let store = try store()
        let url = store.start(newLaunch(), prompt: "withdraw")
        let state = try await state(of: store, at: url) { $0.requests.isEmpty && $0.phase == .idle }
        XCTAssertEqual(state.activity, .idle)
        await store.endAll()
    }

    func testACrashedCLIStaysAsFailedUntilEnded() async throws {
        let store = try store()
        let url = store.start(newLaunch(), prompt: "crash")
        let failed = try await state(of: store, at: url) {
            if case .failed = $0.phase { return true }
            return false
        }
        guard case .failed(let message)? = store.activities[url] else { return XCTFail("not failed") }
        XCTAssertTrue(message.contains("boom"), message)
        guard case .failed(let failure) = failed.phase else { return }
        XCTAssertTrue(failure.log.contains("boom"))

        await store.end(at: url)
        XCTAssertTrue(store.activities.isEmpty)
    }

    func testEndingASessionDropsItAndItReadsFromDiskAgain() async throws {
        let store = try store(history: Transcript(messages: [.user(UserMessage(content: [.text("saved")]))]))
        let url = try await startedAndSettled(store)
        await store.end(at: url)
        XCTAssertTrue(store.activities.isEmpty)
        let state = try await state(of: store, at: url) { _ in true }
        XCTAssertEqual(state.phase, .atRest)
        XCTAssertEqual(state.transcript.messages.count, 1)
    }

    func testEndAllEndsEverySession() async throws {
        let store = try store()
        let first = store.start(newLaunch(), prompt: "echo")
        let second = store.start(newLaunch(), prompt: "echo")
        XCTAssertEqual(Set(store.activities.keys), [first, second])
        await store.endAll()
        XCTAssertTrue(store.activities.isEmpty)
    }

    func testActivitiesPublishOnlyWhenTheyChange() async throws {
        let store = try store()
        var published: [[URL: SessionState.Activity]] = []
        store.$activities.sink { published.append($0) }.store(in: &cancellables)
        let url = store.start(newLaunch(), prompt: "echo")
        try await state(of: store, at: url) { $0.phase == .idle && $0.transcript.messages.count == 2 }
        // Starting and responding look the same to the sidebar.
        XCTAssertEqual(published, [[:], [url: .responding], [url: .idle]])
        await store.endAll()
    }

    func testALifecycleScenarioEndsWithTheReplayInTheTranscriptAndNoLocalPrompt() async throws {
        let store = try store()
        let url = store.start(newLaunch(), prompt: "lifecycle")
        let state = try await state(of: store, at: url) { $0.phase == .idle && $0.transcript.messages.count == 2 }
        XCTAssertTrue(state.prompts.isEmpty)
        await store.endAll()
    }

    func testStopAfterItStartedHandsTheWordsBack() async throws {
        let store = try store()
        let url = store.start(newLaunch(), prompt: "lifecycle-cancel")
        let state = try await state(of: store, at: url) {
            $0.prompts.first?.delivery == .returned || ($0.prompts.isEmpty && $0.transcript.messages.count > 1)
        }
        // The scenario replays the prompt before it cancels it; the words are in
        // the transcript either way and nothing is left half-drawn.
        XCTAssertNotEqual(state.prompts.first?.delivery, .held)
        await store.endAll()
    }

    func testTheCLIsTitleReachesTheState() async throws {
        let store = try store()
        let url = store.start(newLaunch(), prompt: "title")
        try await state(of: store, at: url) { $0.title == "Renamed" }
        await store.endAll()
    }

    func testAnEffortTypedInTheSessionMovesTheChip() async throws {
        let store = try store()
        let url = store.start(newLaunch(Fixture.settings("opus", effort: .low)), prompt: "flag")
        try await state(of: store, at: url) { $0.settings?.effort == .high }
        await store.endAll()
    }

    func testTheContextIsReadAfterEachTurn() async throws {
        let store = try store()
        let url = try await startedAndSettled(store)
        let state = try await state(of: store, at: url) { $0.contextUsage != nil }
        XCTAssertEqual(try XCTUnwrap(state.contextUsage), 0.06, accuracy: 0.01)
        await store.endAll()
    }

    // MARK: - Steering

    func testAModeChosenWhileIdleIsAppliedNow() async throws {
        let store = try store()
        let url = try await startedAndSettled(store)
        store.update(.permissionMode(.plan), at: url)
        let state = try await state(of: store, at: url) { $0.settings?.permissionMode == .plan }
        XCTAssertNil(state.refusal)
        await store.endAll()
    }

    func testABypassTheCLIRefusesRevertsWithTheReasonInWords() async throws {
        let store = try store()
        let url = try await startedAndSettled(store)
        store.update(.permissionMode(.bypassPermissions), at: url)
        let state = try await state(of: store, at: url) { $0.refusal != nil }
        XCTAssertEqual(state.settings?.permissionMode, .default)
        XCTAssertEqual(
            state.refusal,
            String(localized: "Bypass Permissions isn’t allowed. Allow it in Settings › General, then restart."))
        await store.endAll()
    }

    func testAModelChosenWhileIdleShowsAtOnceAndStaysWhenTheCLIAcks() async throws {
        let store = try store()
        let url = try await startedAndSettled(store)
        store.update(.model(Fixture.choice("slow")), at: url)
        var shown: SessionState?
        for try await state in store.states(at: url) {
            shown = state
            break
        }
        XCTAssertEqual(shown?.settings?.model.value, "slow", "at once, before the CLI's check")
        XCTAssertEqual(shown?.runningSettings?.model.value, "opus")
        let applied = try await state(of: store, at: url) { $0.runningSettings?.model.value == "slow" }
        XCTAssertNil(applied.refusal)
        await store.endAll()
    }

    func testAModelTheCLIRefusesRevertsWithTheReason() async throws {
        let store = try store()
        let url = try await startedAndSettled(store)
        store.update(.model(Fixture.choice("refuse:restricted_by_org")), at: url)
        let state = try await state(of: store, at: url) { $0.refusal != nil }
        XCTAssertEqual(state.settings?.model.value, "opus")
        XCTAssertEqual(
            state.refusal, String(localized: "\("refuse:restricted_by_org") isn’t available to your organization."))
        await store.endAll()
    }

    func testAnotherAccountsModelWhileRunningRestartsTheSessionWithADivider() async throws {
        let store = try store()
        let url = try await startedAndSettled(store)
        let relayHaiku = Fixture.choice("haiku", on: Fixture.relay)
        store.update(.model(relayHaiku), at: url)
        XCTAssertEqual(store.activities[url], .responding, "starting again, never at rest")
        let state = try await state(of: store, at: url) { $0.restarts.count == 1 && $0.phase == .idle }
        XCTAssertEqual(state.restarts[0].accountName, "Work Relay")
        XCTAssertEqual(state.restarts[0].modelName, "Haiku")
        XCTAssertEqual(state.settings?.model, relayHaiku)
        XCTAssertEqual(launches().count, 2)
        let line = try XCTUnwrap(launches().last)
        XCTAssertTrue(line.contains("--resume"), line)
        XCTAssertTrue(line.contains("--model haiku"), line)
        await store.endAll()
    }

    func testWithdrawingAQueuedPromptTakesItOut() async throws {
        let store = try store()
        let url = store.start(newLaunch(), prompt: "hold")
        try await state(of: store, at: url) { $0.phase == .responding && $0.prompts.first?.delivery == .sent }
        store.send("hold", to: url)
        let queued = try await state(of: store, at: url) { $0.prompts.count == 2 && $0.prompts[1].delivery == .queued }
        store.withdraw(prompt: queued.prompts[1].id, at: url)
        let state = try await state(of: store, at: url) { $0.prompts.count == 1 }
        XCTAssertEqual(state.prompts[0].id, queued.prompts[0].id)
        await store.endAll()
    }

    // MARK: - Resuming

    func testAPromptToASessionAtRestResumesItOnce() async throws {
        var history = Transcript(messages: [.user(UserMessage(content: [.text("earlier")]))])
        history.metadata.cwd = scratch.path
        let store = try store(history: history)
        let url = scratch.appendingPathComponent("projects/p/0a1b.jsonl")

        // A double Return: two prompts before the CLI is up.
        store.send("echo", to: url)
        store.send("echo", to: url)

        XCTAssertEqual(Set(store.activities.keys), [url])
        let state = try await state(of: store, at: url) {
            $0.phase == .idle && $0.transcript.messages.count > 1 && $0.prompts.isEmpty
        }
        XCTAssertEqual(launches().count, 1, "one CLI per session id")
        XCTAssertEqual(state.transcript.messages.first, history.messages.first, "the history comes first")
        await store.endAll()
    }

    func testAPromptToACrashedSessionResumesIt() async throws {
        let store = try store()
        let url = store.start(newLaunch(), prompt: "crash")
        try await state(of: store, at: url) {
            if case .failed = $0.phase { return true }
            return false
        }
        store.send("echo", to: url)
        XCTAssertEqual(store.activities[url], .responding)
        try await state(of: store, at: url) { $0.phase == .idle && $0.prompts.isEmpty }
        XCTAssertEqual(launches().count, 2, "a new CLI, not the dead one")
        XCTAssertTrue(try XCTUnwrap(launches().last).contains("--resume"))
        await store.endAll()
    }

    func testRestartResumesAFailedSessionWithoutAPrompt() async throws {
        let store = try store()
        let url = store.start(newLaunch(), prompt: "crash")
        try await state(of: store, at: url) {
            if case .failed = $0.phase { return true }
            return false
        }
        store.restart(at: url)
        try await state(of: store, at: url) { $0.phase == .idle }
        XCTAssertEqual(launches().count, 2)
        await store.endAll()
    }

    func testResumingASessionWithoutAFolderFailsInTheState() async throws {
        let store = try store()
        let url = scratch.appendingPathComponent("projects/p/a.jsonl")
        store.send("echo", to: url)
        let state = try await state(of: store, at: url) {
            if case .failed = $0.phase { return true }
            return false
        }
        XCTAssertEqual(
            state.activity, .failed(message: String(localized: "This session doesn't record the folder it ran in.")))
        XCTAssertTrue(launches().isEmpty)
        await store.endAll()
    }
}

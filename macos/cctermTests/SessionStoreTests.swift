import AgentSDK
import Combine
import XCTest

@testable import ccterm

/// `SessionStore`: a session at rest and the same one live, and the whole
/// life of a live one — start, talk, resume, end — over AgentSDK's scripted
/// stand-in CLI (`fake_cli.py`; the prompt text picks the scenario).
@MainActor
final class SessionStoreTests: XCTestCase {
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

    /// A launcher that notes each start, then becomes the fake CLI — so a
    /// test can count the CLIs that were launched. (The fixture itself isn't
    /// executable.)
    private func fakeCLI() throws -> String {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AgentSDK/Tests/AgentSDKTests/Fixtures/fake_cli.py")
        let launcher = scratch.appendingPathComponent("claude")
        let script = """
            #!/bin/sh
            echo started >> '\(starts.path)'
            exec /usr/bin/env python3 '\(fixture.path)' "$@"
            """
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        return launcher.path
    }

    private func launchCount() -> Int {
        ((try? String(contentsOf: starts, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    /// A store whose sessions launch the fake CLI and are written under
    /// `scratch`; at rest, a session reads as `history`.
    private func store(history: Transcript = Transcript(messages: [])) throws -> SessionStore {
        // `inheritsParentEnvironment` skips the login-shell probe each start
        // would otherwise pay.
        let launch = CLIConfiguration(binaryPath: try fakeCLI(), inheritsParentEnvironment: true)
        return SessionStore(
            configurations: Just(launch).eraseToAnyPublisher(),
            directories: Just(SessionDirectory(url: scratch.appendingPathComponent("projects"))).eraseToAnyPublisher(),
            read: { _ in history })
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

    // MARK: - At rest

    func testASessionAtRestReadsOnceFromDisk() async throws {
        let message = Message.user(UserMessage(content: [.text("hi")]))
        let store = try store(history: Transcript(messages: [message]))
        var received: [SessionState] = []
        for try await state in store.states(at: scratch.appendingPathComponent("p/a.jsonl")) {
            received.append(state)
            break
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].transcript.messages, [message])
        XCTAssertFalse(received[0].isLive)
        XCTAssertNil(received[0].activity)
        XCTAssertTrue(store.activities.isEmpty)
    }

    func testAnUnreadableTranscriptThrows() async throws {
        struct Unreadable: Error {}
        let store = SessionStore(
            configurations: Empty().eraseToAnyPublisher(), directories: Empty().eraseToAnyPublisher(),
            read: { _ in throw Unreadable() })
        do {
            for try await _ in store.states(at: scratch.appendingPathComponent("a.jsonl")) {}
            XCTFail("expected a throw")
        } catch is Unreadable {}
    }

    func testStartingWithoutALaunchFails() async throws {
        let store = SessionStore.reading()
        do {
            _ = try await store.start(in: folder)
            XCTFail("expected a throw")
        } catch {}
        XCTAssertTrue(store.activities.isEmpty)
    }

    // MARK: - Live

    func testANewSessionIsLiveAndIdleUnderItsTranscriptURL() async throws {
        let store = try store()
        let url = try await store.start(in: folder)
        XCTAssertEqual(url.pathExtension, "jsonl")
        XCTAssertEqual(store.activities, [url: .idle])
        let state = try await state(of: store, at: url) { _ in true }
        XCTAssertTrue(state.isLive)
        await store.endAll()
    }

    func testAPromptRunsATurnAndItsReplyArrives() async throws {
        let store = try store()
        let url = try await store.start(in: folder)
        try await store.send("echo", to: url)
        let state = try await state(of: store, at: url) { !$0.isResponding && $0.transcript.messages.count == 2 }
        XCTAssertEqual(state.activity, .idle)
        guard case .assistant(let reply) = state.transcript.messages.last else { return XCTFail("no reply") }
        XCTAssertEqual(reply.content.compactMap(\.text), ["hello"])
        await store.endAll()
    }

    func testAPermissionRequestWaitsUntilAnswered() async throws {
        let store = try store()
        let url = try await store.start(in: folder)
        try await store.send("permission", to: url)
        try await state(of: store, at: url) { $0.requests.count == 1 }
        XCTAssertEqual(store.activities[url], .needsInput)

        store.respond(toCall: "toolu_1", at: url) { request in
            XCTAssertEqual(request.toolName, "Bash")
            return .allow()
        }
        let state = try await state(of: store, at: url) { $0.requests.isEmpty && !$0.isResponding }
        XCTAssertEqual(state.activity, .idle)
        await store.endAll()
    }

    func testARequestWithdrawnByTheCLILeaves() async throws {
        let store = try store()
        let url = try await store.start(in: folder)
        try await store.send("withdraw", to: url)
        let state = try await state(of: store, at: url) { $0.requests.isEmpty && !$0.isResponding }
        XCTAssertEqual(state.activity, .idle)
        await store.endAll()
    }

    func testACrashedCLIStaysAsFailedUntilEnded() async throws {
        let store = try store()
        let url = try await store.start(in: folder)
        try await store.send("crash", to: url)
        try await state(of: store, at: url) { $0.failure != nil }
        guard case .failed(let message)? = store.activities[url] else { return XCTFail("not failed") }
        XCTAssertTrue(message.contains("boom"), message)

        await store.end(at: url)
        XCTAssertTrue(store.activities.isEmpty)
    }

    func testEndingASessionDropsItAndItReadsFromDiskAgain() async throws {
        let store = try store(history: Transcript(messages: [.user(UserMessage(content: [.text("saved")]))]))
        let url = try await store.start(in: folder)
        await store.end(at: url)
        XCTAssertTrue(store.activities.isEmpty)
        let state = try await state(of: store, at: url) { _ in true }
        XCTAssertFalse(state.isLive)
        XCTAssertEqual(state.transcript.messages.count, 1)
    }

    func testStatesSwitchFromTheLiveSessionToDiskWhenItEnds() async throws {
        let store = try store()
        let url = try await store.start(in: folder)
        var seen: [Bool] = []
        let finished = expectation(description: "the stream saw the session end")
        let task = Task { @MainActor in
            for try await state in store.states(at: url) {
                seen.append(state.isLive)
                if seen.last == false { finished.fulfill() }
            }
        }
        await store.end(at: url)
        await fulfillment(of: [finished], timeout: 20)
        task.cancel()
        XCTAssertEqual(seen.first, true)
        XCTAssertEqual(seen.last, false)
    }

    func testEndAllEndsEverySession() async throws {
        let store = try store()
        let first = try await store.start(in: folder)
        let second = try await store.start(in: folder)
        XCTAssertEqual(Set(store.activities.keys), [first, second])
        await store.endAll()
        XCTAssertTrue(store.activities.isEmpty)
    }

    func testActivitiesPublishOnlyWhenTheyChange() async throws {
        let store = try store()
        var published: [[URL: SessionState.Activity]] = []
        store.$activities.sink { published.append($0) }.store(in: &cancellables)
        let url = try await store.start(in: folder)
        try await store.send("echo", to: url)
        try await state(of: store, at: url) { !$0.isResponding && $0.transcript.messages.count == 2 }
        // Every message of the turn changed the state; only `idle` → `responding`
        // → `idle` changed what the sidebar draws.
        XCTAssertEqual(published, [[:], [url: .idle], [url: .responding], [url: .idle]])
        await store.endAll()
    }

    // MARK: - Resuming

    func testAPromptToASessionAtRestResumesItOnce() async throws {
        var history = Transcript(messages: [.user(UserMessage(content: [.text("earlier")]))])
        history.metadata.cwd = scratch.path
        let store = try store(history: history)
        let url = scratch.appendingPathComponent("projects/p/0a1b.jsonl")

        // A double Return: two prompts before the CLI is up.
        async let first: Void = store.send("echo", to: url)
        async let second: Void = store.send("echo", to: url)
        _ = try await (first, second)

        XCTAssertEqual(launchCount(), 1, "one CLI per session id")
        XCTAssertEqual(Set(store.activities.keys), [url])
        let state = try await state(of: store, at: url) { $0.isLive && $0.transcript.messages.count > 1 }
        XCTAssertEqual(state.transcript.messages.first, history.messages.first, "the history comes first")
        await store.endAll()
    }

    func testResumingASessionWithoutAFolderFails() async throws {
        let store = try store()
        do {
            try await store.send("echo", to: scratch.appendingPathComponent("projects/p/a.jsonl"))
            XCTFail("expected a throw")
        } catch {}
        XCTAssertTrue(store.activities.isEmpty)
        XCTAssertEqual(launchCount(), 0)
    }
}

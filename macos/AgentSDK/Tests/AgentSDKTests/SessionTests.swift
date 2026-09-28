import XCTest

@testable import AgentSDK

/// ``Session`` against `Fixtures/fake_cli.py`, a scripted CLI speaking the
/// stream-json stdio protocol. The prompt text picks the scenario; what the
/// fake saw on its stdin comes back as `system` messages with `test_*`
/// subtypes.
final class SessionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsdk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = try XCTUnwrap(
            Bundle.module.url(forResource: "fake_cli", withExtension: "py", subdirectory: "Fixtures"))
        let script = directory.appendingPathComponent("claude")
        try FileManager.default.copyItem(at: source, to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSession(promptSuggestions: Bool = false, settings: Settings = Settings()) -> Session {
        Session(
            configuration: SessionConfiguration(
                workingDirectory: directory, binaryPath: directory.appendingPathComponent("claude").path,
                settings: settings, promptSuggestions: promptSuggestions, inheritsParentEnvironment: true))
    }

    /// The raw payload of the next `test_*` probe, skipping everything else.
    private func probe(_ subtype: String, in events: inout AsyncStream<SessionEvent>.Iterator) async -> JSONValue? {
        while let event = await events.next() {
            if case .message(.system(.other(subtype, let raw))) = event { return raw }
        }
        return nil
    }

    private func drain(_ events: inout AsyncStream<SessionEvent>.Iterator) async -> [SessionEvent] {
        var rest: [SessionEvent] = []
        while let event = await events.next() { rest.append(event) }
        return rest
    }

    // MARK: - Lifecycle

    func testStartPerformsHandshake() async throws {
        let session = makeSession(promptSuggestions: true)
        var events = session.events.makeAsyncIterator()
        let result = try await session.start()
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(result.commands.map(\.name), ["review"])
        XCTAssertEqual(result.commands.first?.argumentHint, "<pr>")
        XCTAssertEqual(result.agents.map(\.name), ["Explore"])
        XCTAssertEqual(result.models.first?.displayName, "Default")
        XCTAssertEqual(result.models.first?.supportsEffort, true)
        XCTAssertEqual(result.account?.email, "dev@example.com")

        let request = await probe("test_initialize", in: &events)
        XCTAssertEqual(request?["request"]?["subtype"], "initialize")
        XCTAssertEqual(request?["request"]?["promptSuggestions"], true)

        do {
            try await session.start()
            XCTFail("second start")
        } catch let error as AgentSDKError {
            XCTAssertEqual(error, .alreadyStarted)
        }
        await session.close()
        XCTAssertFalse(session.isRunning)
    }

    func testMissingBinaryFailsStart() async {
        let session = Session(
            configuration: SessionConfiguration(
                workingDirectory: directory, binaryPath: directory.appendingPathComponent("nope").path,
                inheritsParentEnvironment: true))
        var events = session.events.makeAsyncIterator()
        do {
            try await session.start()
            XCTFail("started a missing binary")
        } catch {}
        guard case .exited = await events.next() else { return XCTFail("expected exit") }
        let tail = await events.next()
        XCTAssertNil(tail)
    }

    func testCommandsBeforeStartThrowNotRunning() async {
        let session = makeSession()
        XCTAssertThrowsError(try session.send(UserInput("hi"))) {
            XCTAssertEqual($0 as? AgentSDKError, .notRunning)
        }
        do {
            try await session.interrupt()
            XCTFail("interrupt before start")
        } catch {
            XCTAssertEqual(error as? AgentSDKError, .notRunning)
        }
    }

    // MARK: - Messages

    func testSendDeliversMessagesInOrder() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        let input = UserInput("echo")
        try session.send(input)

        let line = await probe("test_user_line", in: &events)
        XCTAssertEqual(line?["line"]?["type"], "user")
        XCTAssertEqual(line?["line"]?["uuid"]?.stringValue, input.uuid)
        XCTAssertEqual(line?["line"]?["message"]?["content"], "echo", "a text-only prompt goes as a string")

        var kinds: [String] = []
        loop: while let event = await events.next() {
            guard case .message(let message) = event else { continue }
            switch message {
            case .assistant(let a):
                kinds.append("assistant")
                XCTAssertEqual(a.content, [.text("hello")])
            case .result(let r):
                kinds.append("result")
                XCTAssertEqual(r.userMessageUUIDs, [input.uuid])
                break loop
            default: break
            }
        }
        XCTAssertEqual(kinds, ["assistant", "result"])
        XCTAssertEqual(session.sessionID, "fake-session")
        await session.close()
    }

    func testMalformedOutputDoesNotDisturbTheSession() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        try session.send(UserInput("garbage"))

        var unknownTypes: [String?] = []
        var replies: JSONValue?
        while let event = await events.next() {
            if case .message(.unknown(let raw)) = event { unknownTypes.append(raw["type"]?.stringValue) }
            if case .message(.system(.other("test_auto_replies", let raw))) = event {
                replies = raw["replies"]
                break
            }
        }
        // The broken assistant line and the new kind survive as `.unknown`;
        // text, arrays and keep-alives vanish.
        XCTAssertEqual(unknownTypes, ["assistant", "brand_new_kind"])
        XCTAssertEqual(replies?[0]?["response"]?["request_id"], "hook-1")
        XCTAssertEqual(replies?[0]?["response"]?["subtype"], "success")
        XCTAssertEqual(replies?[1]?["response"]?["request_id"], "odd-1")
        XCTAssertEqual(replies?[1]?["response"]?["subtype"], "error")

        let echoed = try await session.sendControlRequest("ping", ["x": 1])
        XCTAssertEqual(echoed["echo"]?["subtype"], "ping")
        XCTAssertEqual(echoed["echo"]?["x"], 1)
        await session.close()
    }

    // MARK: - Permissions

    func testPermissionRequestRoundTrip() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        try session.send(UserInput("permission"))

        var request: PermissionRequest?
        while let event = await events.next() {
            if case .permissionRequest(let r) = event {
                request = r
                break
            }
        }
        let permission = try XCTUnwrap(request)
        XCTAssertEqual(permission.toolName, "Bash")
        XCTAssertEqual(permission.toolUseID, "toolu_1")
        XCTAssertEqual(permission.input["command"], "ls")
        XCTAssertEqual(permission.decisionReason, "needs approval")
        XCTAssertEqual(permission.suggestions.count, 2)
        XCTAssertEqual(
            permission.suggestions.first,
            .addRules([PermissionRule(toolName: "Bash", ruleContent: "ls:*")], behavior: .allow, destination: .session))
        guard case .unknown(let raw) = permission.suggestions.last else { return XCTFail("future kind dropped") }
        XCTAssertEqual(raw["type"], "someFutureKind")

        XCTAssertTrue(permission.isPending)
        permission.respond(.allow(updatedPermissions: [permission.suggestions[0]]))
        permission.respond(.deny(message: "too late"))
        XCTAssertFalse(permission.isPending)

        let reply = await probe("test_permission_reply", in: &events)
        let response = reply?["reply"]?["response"]
        XCTAssertEqual(response?["request_id"], "perm-1")
        XCTAssertEqual(response?["response"]?["behavior"], "allow")
        XCTAssertEqual(response?["response"]?["toolUseID"], "toolu_1")
        XCTAssertEqual(response?["response"]?["updatedPermissions"]?[0]?["type"], "addRules")
        XCTAssertEqual(response?["response"]?["updatedPermissions"]?[0]?["destination"], "session")

        // The echo of our own answer is not surfaced, and the turn completes.
        while let event = await events.next() {
            if case .message(.result) = event { break }
        }
        await session.close()
    }

    func testWithdrawnPermissionRequestIsCancelled() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        try session.send(UserInput("withdraw"))

        var request: PermissionRequest?
        var cancelledID: String?
        while let event = await events.next() {
            switch event {
            case .permissionRequest(let r): request = r
            case .permissionRequestCancelled(let id): cancelledID = id
            case .message(.result): break
            default: continue
            }
            if cancelledID != nil { break }
        }
        XCTAssertEqual(cancelledID, "perm-2")
        XCTAssertEqual(request?.id, "perm-2")
        XCTAssertEqual(request?.isPending, false)
        await session.close()
    }

    // MARK: - Control requests

    func testControlRequestErrorsAndAnswers() async throws {
        let session = makeSession()
        try await session.start()
        do {
            _ = try await session.sendControlRequest("fail")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AgentSDKError, .controlRequestFailed(subtype: "fail", message: "nope"))
        }
        let answer = try await session.askSideQuestion("why?")
        XCTAssertEqual(answer, SideQuestionAnswer(response: "Answer: why?", synthetic: false))
        await session.close()
    }

    func testCancellingARequestWithdrawsIt() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        let task = Task { try await session.sendControlRequest("hang") }
        let hanging = await probe("test_hanging", in: &events)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let cancelled = await probe("test_cancelled", in: &events)
        XCTAssertNotNil(hanging?["request_id"])
        XCTAssertEqual(cancelled?["request_id"], hanging?["request_id"])
        await session.close()
    }

    // MARK: - Settings

    func testSettingsSeedAndChangeTheSessionLayer() async throws {
        var launch = Settings()
        launch[.fastMode] = true
        launch[.language] = "french"
        launch.unset(.outputStyle)  // Dropped at launch: a null would void the layer.
        let session = makeSession(settings: launch)
        try await session.start()

        var seeded = try await session.settings()
        XCTAssertEqual(seeded.layer(.flag), Settings(json: ["fastMode": true, "language": "french"]))
        XCTAssertEqual(seeded.layer(.user)?["theme"], "dark")
        XCTAssertEqual(seeded.layers.map(\.source), [.user, .flag])

        var change = Settings()
        change[.effortLevel] = .high
        change[.permissions] = PermissionSettings(additionalDirectories: ["/tmp/extra"])
        change[.language] = "german"
        try await session.applySettings(change)

        seeded = try await session.settings()
        var layer = try XCTUnwrap(seeded.layer(.flag))
        XCTAssertEqual(layer[.fastMode], true)
        XCTAssertEqual(layer[.effortLevel], .high)
        XCTAssertEqual(layer[.permissions]?.additionalDirectories, ["/tmp/extra"])
        XCTAssertEqual(layer[.language], "german")
        XCTAssertEqual(seeded.effective[.effortLevel], .high)
        XCTAssertEqual(seeded.applied, SettingsSnapshot.Applied(model: "claude-test", effort: "high"))
        XCTAssertEqual(seeded.errors, [])

        var withdraw = Settings()
        withdraw.unset(.language)
        withdraw.unset(.effortLevel)
        try await session.applySettings(withdraw)
        seeded = try await session.settings()
        layer = try XCTUnwrap(seeded.layer(.flag))
        XCTAssertEqual(layer[.language], "french")
        XCTAssertNil(layer[.effortLevel])
        await session.close()
    }

    // MARK: - Exit

    func testProcessExitFailsPendingWorkAndEndsTheStream() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        let pending = Task { try await session.sendControlRequest("hang") }
        _ = await probe("test_hanging", in: &events)
        try session.send(UserInput("crash"))

        let rest = await drain(&events)
        guard case .exited(let termination) = rest.last else { return XCTFail("stream did not end with exit") }
        XCTAssertEqual(termination.exitCode, 3)
        XCTAssertTrue(termination.stderr.contains("fatal: boom"))
        XCTAssertFalse(session.isRunning)

        do {
            _ = try await pending.value
            XCTFail("pending request survived exit")
        } catch {
            XCTAssertEqual(error as? AgentSDKError, .processExited(termination))
        }
        XCTAssertThrowsError(try session.send(UserInput("again"))) {
            XCTAssertEqual($0 as? AgentSDKError, .notRunning)
        }
        do {
            _ = try await session.sendControlRequest("ping")
            XCTFail("request after exit")
        } catch {
            XCTAssertEqual(error as? AgentSDKError, .processExited(termination))
        }
    }

    func testCloseEndsTheStream() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        await session.close()
        let rest = await drain(&events)
        guard case .exited(let termination) = rest.last else { return XCTFail("no exit event") }
        XCTAssertEqual(termination.exitCode, 0)
        // Closing twice is harmless.
        await session.close()
    }
}

import XCTest

@testable import AgentSDK

/// The control requests and messages a live session tab uses — model and mode
/// changes and their refusals, withdrawing a queued prompt, the prompt
/// lifecycle, title and flag-setting echoes — over `Fixtures/fake_cli.py`
/// (its header lists the scenarios).
final class LiveControlTests: XCTestCase {
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

    private func makeSession(allowsBypass: Bool = false) -> Session {
        Session(
            configuration: SessionConfiguration(
                workingDirectory: directory, binaryPath: directory.appendingPathComponent("claude").path,
                inheritsParentEnvironment: true, allowDangerouslySkipPermissions: allowsBypass))
    }

    /// Events up to and including the first one `match` maps to a value.
    private func next<T>(
        _ events: inout AsyncStream<SessionEvent>.Iterator, _ match: (SessionEvent) -> T?
    ) async -> T? {
        while let event = await events.next() {
            if let value = match(event) { return value }
        }
        return nil
    }

    private func lifecycles(
        _ events: inout AsyncStream<SessionEvent>.Iterator, until terminal: Bool = true
    ) async -> [String] {
        var states: [String] = []
        while let event = await events.next() {
            guard case .message(.commandLifecycle(let c)) = event else { continue }
            states.append(c.state.rawValue)
            if c.state.isTerminal { break }
        }
        return states
    }

    // MARK: - set_model

    func testSetModelAcksAfterItsCheckThenEchoesTheCommand() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        let started = Date()
        try await session.setModel("slow")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.35, "the ack waits for the CLI's check")
        try await session.setModel("echo")
        let echo: UserMessage? = await next(&events) {
            if case .message(.user(let m)) = $0 { return m } else { return nil }
        }
        XCTAssertEqual(echo?.kind, .commandOutput(standardOutput: "Set model to echo", standardError: ""))
        await session.close()
    }

    func testSetModelRefusalCarriesItsCode() async throws {
        let session = makeSession()
        try await session.start()
        do {
            try await session.setModel("refuse:restricted_by_org")
            XCTFail("expected a refusal")
        } catch let error as AgentSDKError {
            XCTAssertEqual(error.refusalCode, "restricted_by_org")
            guard case .controlRequestFailed(let subtype, let message, let code) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(subtype, "set_model")
            XCTAssertEqual(message, "Cannot set model refuse:restricted_by_org")
            XCTAssertEqual(code, "restricted_by_org")
        }
        await session.close()
    }

    func testAnErrorWithoutACodeHasNoRefusalCode() async throws {
        let session = makeSession()
        try await session.start()
        do {
            _ = try await session.sendControlRequest("fail")
            XCTFail("expected failure")
        } catch let error as AgentSDKError {
            XCTAssertNil(error.refusalCode)
            XCTAssertEqual(error, .controlRequestFailed(subtype: "fail", message: "nope"))
        }
        XCTAssertNil(AgentSDKError.notRunning.refusalCode)
        await session.close()
    }

    // MARK: - set_permission_mode

    func testSetPermissionModeAnswersAndSendsStatus() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        try await session.setPermissionMode(.plan)
        let status: SystemMessage.Status? = await next(&events) {
            if case .message(.system(.status(let s))) = $0 { return s } else { return nil }
        }
        XCTAssertEqual(status?.permissionMode, .plan)
        XCTAssertNil(status?.status)
        await session.close()
    }

    func testBypassRefusedUnlessLaunchedForIt() async throws {
        let refused = makeSession()
        try await refused.start()
        do {
            try await refused.setPermissionMode(.bypassPermissions)
            XCTFail("expected a refusal")
        } catch let error as AgentSDKError {
            XCTAssertEqual(error.refusalCode, "bypass_not_launched")
        }
        await refused.close()

        let allowed = makeSession(allowsBypass: true)
        try await allowed.start()
        try await allowed.setPermissionMode(.bypassPermissions)
        await allowed.close()
    }

    func testAutoModeRefusalCode() async throws {
        let session = makeSession()
        try await session.start()
        do {
            try await session.setPermissionMode(.auto)
            XCTFail("expected a refusal")
        } catch let error as AgentSDKError {
            XCTAssertEqual(error.refusalCode, "auto_mode_unavailable")
        }
        await session.close()
    }

    // MARK: - cancel_async_message, list_models, context usage

    func testCancelAsyncMessageReportsWhetherItWasQueued() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        let held = UserInput("hold")
        try session.send(held)
        let queued: String? = await next(&events) {
            if case .message(.commandLifecycle(let c)) = $0 { return c.state.rawValue } else { return nil }
        }
        XCTAssertEqual(queued, "queued")

        let cancelled = try await session.cancelAsyncMessage(uuid: held.uuid)
        XCTAssertTrue(cancelled)
        let state: CommandLifecycle? = await next(&events) {
            if case .message(.commandLifecycle(let c)) = $0 { return c } else { return nil }
        }
        XCTAssertEqual(state, CommandLifecycle(commandUUID: held.uuid, state: .cancelled))

        let again = try await session.cancelAsyncMessage(uuid: held.uuid)
        XCTAssertFalse(again, "it already left the queue")
        let unknown = try await session.cancelAsyncMessage(uuid: "nobody")
        XCTAssertFalse(unknown)
        await session.close()
    }

    func testListModelsIncludesDisabledRows() async throws {
        let session = makeSession()
        try await session.start()
        let models = try await session.listModels()
        XCTAssertEqual(models.map(\.value), ["default", "locked"])
        XCTAssertEqual(models[0].resolvedModel, "claude-fake-1")
        XCTAssertEqual(models[0].supportedEffortLevels, ["low", "high"])
        XCTAssertFalse(models[0].isDisabled)
        XCTAssertTrue(models[1].isDisabled)
        await session.close()
    }

    func testContextUsageAfterATurn() async throws {
        let session = makeSession()
        try await session.start()
        let usage = try await session.contextUsage()
        XCTAssertEqual(usage.totalTokens, 12_000)
        XCTAssertEqual(usage.rawMaxTokens, 200_000)
        await session.close()
    }

    // MARK: - Messages

    func testPromptLifecycleRunsQueuedStartedCompleted() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        try session.send(UserInput("lifecycle"))
        let states = await lifecycles(&events)
        XCTAssertEqual(states, ["queued", "started", "completed"])
        await session.close()
    }

    func testAnInterruptedPromptEndsCancelled() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        try session.send(UserInput("lifecycle-cancel"))
        let states = await lifecycles(&events)
        XCTAssertEqual(states, ["queued", "started", "cancelled"])
        await session.close()
    }

    func testSessionTitleChangedDecodes() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        try session.send(UserInput("title"))
        let title: String? = await next(&events) {
            if case .message(.system(.sessionTitleChanged(let title))) = $0 { return title } else { return nil }
        }
        XCTAssertEqual(title, "Renamed")
        await session.close()
    }

    func testStatusCarriesCompactingAndTheMode() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        try session.send(UserInput("mode-status"))
        var statuses: [SystemMessage.Status] = []
        while statuses.count < 2, let event = await events.next() {
            if case .message(.system(.status(let s))) = event { statuses.append(s) }
        }
        XCTAssertEqual(statuses.map(\.status), ["compacting", nil])
        XCTAssertEqual(statuses.map(\.permissionMode), [nil, .plan])
        await session.close()
    }

    // MARK: - Flag settings

    func testATypedSlashCommandsFlagSettingsReachTheHost() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        try session.send(UserInput("flag"))
        let patch: JSONValue? = await next(&events) {
            if case .flagSettingsChanged(let patch) = $0 { return patch } else { return nil }
        }
        XCTAssertEqual(patch, ["effortLevel": "high"])
        await session.close()
    }

    func testAnInboundApplyFlagSettingsRequestIsAnsweredAndYielded() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        try session.send(UserInput("flag-request"))
        let patch: JSONValue? = await next(&events) {
            if case .flagSettingsChanged(let patch) = $0 { return patch } else { return nil }
        }
        XCTAssertEqual(patch, ["fastMode": true])
        var reply: JSONValue?
        while reply == nil, let event = await events.next() {
            if case .message(.system(.other("test_flag_reply", let raw))) = event { reply = raw["reply"] }
        }
        XCTAssertEqual(reply?["response"]?["subtype"], "success")
        XCTAssertEqual(reply?["response"]?["request_id"], "flag-1")
        await session.close()
    }

    func testAHostsOwnSettingsChangeIsNotEchoed() async throws {
        let session = makeSession()
        var events = session.events.makeAsyncIterator()
        try await session.start()
        var settings = Settings()
        settings[.effortLevel] = .high
        try await session.applySettings(settings)
        try session.send(UserInput("echo"))
        var sawFlag = false
        loop: while let event = await events.next() {
            switch event {
            case .flagSettingsChanged: sawFlag = true
            case .message(.result): break loop
            default: continue
            }
        }
        XCTAssertFalse(sawFlag)
        await session.close()
    }
}

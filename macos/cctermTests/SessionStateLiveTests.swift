import AgentSDK
import XCTest

@testable import ccterm

/// `SessionState`'s life: its phases, the local prompts and what the CLI's
/// lifecycle does to them, the settings and when a change lands.
final class SessionStateLiveTests: XCTestCase {
    private typealias Fixture = SessionCatalogFixture
    private let catalog = Fixture.catalog
    private var state = SessionState(transcript: Transcript(messages: []), settings: Fixture.settings())

    private func line(_ json: String) -> SessionEvent {
        .message(Message(jsonLine: Data(json.utf8))!)
    }

    private func lifecycle(_ uuid: String, _ name: String) -> SessionEvent {
        line(#"{"type":"command_lifecycle","command_uuid":"\#(uuid)","state":"\#(name)"}"#)
    }

    private func replay(_ uuid: String, _ text: String = "hi") -> SessionEvent {
        line(
            #"{"type":"user","uuid":"\#(uuid)","session_id":"s","parent_tool_use_id":null,"isReplay":true,"message":{"role":"user","content":"\#(text)"}}"#
        )
    }

    private func result(_ uuids: [String] = []) -> SessionEvent {
        let list = uuids.map { "\"\($0)\"" }.joined(separator: ",")
        return line(
            #"{"type":"result","subtype":"success","is_error":false,"uuid":"r","session_id":"s","result":"x","num_turns":1,"user_message_uuids":[\#(list)]}"#
        )
    }

    private func status(_ body: String) -> SessionEvent {
        line(#"{"type":"system","subtype":"status","uuid":"x","session_id":"s",\#(body)}"#)
    }

    private func launched() {
        state.didBeginLaunch()
        state.didLaunch(SessionStateTests.initialization())
    }

    private func prompt(_ id: String, _ delivery: LocalPrompt.Delivery) -> LocalPrompt {
        LocalPrompt(id: id, text: "text \(id)", delivery: delivery)
    }

    // MARK: - Phases

    func testASessionReadFromDiskIsAtRestWithNoActivity() {
        XCTAssertEqual(state.phase, .atRest)
        XCTAssertNil(state.activity)
        XCTAssertFalse(state.hasProcess)
    }

    func testALaunchStartsThenGoesIdle() {
        state.didBeginLaunch()
        XCTAssertEqual(state.phase, .starting)
        XCTAssertEqual(state.activity, .responding)
        state.didLaunch(SessionStateTests.initialization(#"{"commands":[{"name":"review"}]}"#))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.commands.map(\.name), ["review"])
        XCTAssertEqual(state.settings, Fixture.settings(), "the choices it launched on stay")
    }

    func testALaunchThatFailsIsFailedAndItsHeldPromptsAreNotSent() {
        state.didBeginLaunch()
        state.didSend(prompt("u1", .held))
        state.didFailToLaunch(SessionFailure(message: "no folder"))
        XCTAssertEqual(state.phase, .failed(SessionFailure(message: "no folder")))
        XCTAssertEqual(state.activity, .failed(message: "no folder"))
        guard case .notSent? = state.prompts.first?.delivery else { return XCTFail("still held") }
    }

    func testCompactingFollowsTheStatusAndEndsWithIt() {
        launched()
        state.apply(status(#""status":"compacting""#))
        XCTAssertEqual(state.phase, .compacting)
        XCTAssertEqual(state.activity, .responding)
        state.apply(status(#""status":null"#))
        XCTAssertEqual(state.phase, .idle)
    }

    func testCompactingDuringATurnReturnsToRespondingNotIdle() {
        launched()
        state.didSend(prompt("u1", .sent))
        state.apply(lifecycle("u1", "started"))
        state.apply(status(#""status":"compacting""#))
        state.apply(status(#""status":"requesting""#))
        XCTAssertEqual(state.phase, .responding)
    }

    func testTheStatusCarriesThePermissionMode() {
        launched()
        state.apply(status(#""status":null,"permissionMode":"plan""#))
        XCTAssertEqual(state.settings?.permissionMode, .plan)
    }

    func testATitleAndTheCommandsComeFromTheCLI() {
        launched()
        state.apply(
            line(
                #"{"type":"system","subtype":"session_title_changed","title":"Fix gutter","uuid":"x","session_id":"s"}"#
            ))
        XCTAssertEqual(state.title, "Fix gutter")
        state.apply(
            line(
                #"{"type":"system","subtype":"commands_changed","commands":[{"name":"a"},{"name":"b"}],"uuid":"x","session_id":"s"}"#
            ))
        XCTAssertEqual(state.commands.map(\.name), ["a", "b"])
    }

    func testAnEffortOrFastTypedInTheSessionMovesTheChips() {
        launched()
        state.apply(.flagSettingsChanged(.object(["effortLevel": .string("max")])))
        XCTAssertEqual(state.settings?.effort, .max)
        state.apply(.flagSettingsChanged(.object(["effortLevel": .null, "fastMode": .bool(true)])))
        XCTAssertNil(state.settings?.effort)
        XCTAssertEqual(state.settings?.fastMode, true)
    }

    func testContextUsageIsAFractionOfTheWindow() {
        state.didReadContextUsage(0.72)
        XCTAssertEqual(state.contextUsage, 0.72)
        state.didReadContextUsage(3)
        XCTAssertEqual(state.contextUsage, 1)
    }

    // MARK: - Prompts

    func testAPromptSentWhileStartingIsHeldAndTheSessionStaysStarting() {
        state.didBeginLaunch()
        state.didSend(prompt("u1", .held))
        XCTAssertEqual(state.prompts.map(\.delivery), [.held])
        XCTAssertEqual(state.phase, .starting)
        state.didLaunch(SessionStateTests.initialization())
        XCTAssertEqual(state.phase, .responding, "from `initialize` on: the held prompt is written next")
        state.didRelease(prompt: "u1")
        XCTAssertEqual(state.prompts.map(\.delivery), [.sent])
        XCTAssertEqual(state.phase, .responding)
    }

    func testAReleasedPromptBehindARunningTurnIsQueued() {
        launched()
        state.didSend(prompt("u1", .sent))
        state.apply(lifecycle("u1", "started"))
        state.didSend(prompt("u2", .held))
        state.didRelease(prompt: "u2")
        XCTAssertEqual(state.prompts.last?.delivery, .queued)
    }

    func testQueuedWhileIdleIsNotAWait() {
        launched()
        state.didSend(prompt("u1", .sent))
        state.apply(lifecycle("u1", "queued"))
        XCTAssertEqual(state.prompts.first?.delivery, .sent)
    }

    func testQueuedBehindARunningTurnIsDimmedUntilItStarts() {
        launched()
        state.didSend(prompt("u1", .sent))
        state.apply(lifecycle("u1", "started"))
        state.didSend(prompt("u2", .sent))
        state.apply(lifecycle("u2", "queued"))
        XCTAssertEqual(state.prompts.last?.delivery, .queued)
        state.apply(lifecycle("u2", "started"))
        XCTAssertEqual(state.prompts.last?.delivery, .sent)
    }

    func testTheReplayConfirmsThePromptInPlace() {
        launched()
        state.didSend(prompt("u1", .sent))
        state.apply(replay("u1"))
        XCTAssertTrue(state.prompts.isEmpty, "the transcript's message takes its place")
        XCTAssertEqual(state.transcript.messages.count, 1)
    }

    func testAReplayWithAFreshUUIDIsTheCLIsOwnPromptAndLeavesLocalOnesAlone() {
        launched()
        state.didSend(prompt("u1", .queued))
        state.apply(replay("task-1"))
        XCTAssertEqual(state.prompts.map(\.id), ["u1"])
    }

    func testStopAfterItStartedBeforeTheReplayHandsTheWordsBack() {
        launched()
        state.didSend(prompt("u1", .sent))
        state.apply(lifecycle("u1", "started"))
        state.apply(lifecycle("u1", "cancelled"))
        XCTAssertEqual(state.prompts.first?.delivery, .returned)
        state.didDismiss(prompt: "u1")
        XCTAssertTrue(state.prompts.isEmpty)
    }

    func testAWithdrawnPromptLeavesAndItsCancelledIsNotAReturn() {
        launched()
        state.didSend(prompt("u1", .sent))
        state.apply(lifecycle("u1", "started"))
        state.didSend(prompt("u2", .queued))
        state.didBeginWithdraw(prompt: "u2")
        state.apply(lifecycle("u2", "cancelled"))
        XCTAssertEqual(state.prompts.last?.delivery, .queued, "not handed back")
        state.didWithdraw(prompt: "u2")
        XCTAssertEqual(state.prompts.map(\.id), ["u1"])
    }

    func testAFailedWithdrawalLeavesThePromptWhereItWas() {
        launched()
        state.didSend(prompt("u1", .queued))
        state.didBeginWithdraw(prompt: "u1")
        state.didFailToWithdraw(prompt: "u1")
        state.apply(lifecycle("u1", "cancelled"))
        XCTAssertEqual(state.prompts.first?.delivery, .returned)
    }

    func testARefusedOrDiscardedPromptIsNotSent() {
        launched()
        state.didSend(prompt("u1", .sent))
        state.apply(lifecycle("u1", "refused"))
        state.didSend(prompt("u2", .sent))
        state.apply(lifecycle("u2", "discarded"))
        for prompt in state.prompts {
            guard case .notSent = prompt.delivery else { return XCTFail("\(prompt.id) was \(prompt.delivery)") }
        }
        XCTAssertEqual(state.phase, .idle)
    }

    func testTheResultSettlesPromptsItConsumedWhoseReplayCame() {
        launched()
        state.didSend(prompt("u1", .sent))
        state.apply(lifecycle("u1", "started"))
        state.apply(replay("u1"))
        state.apply(result(["u1"]))
        XCTAssertTrue(state.prompts.isEmpty)
        XCTAssertEqual(state.phase, .idle)
    }

    func testExitWithoutATerminalStateLeavesSentAndQueuedPromptsNotSent() {
        launched()
        state.didSend(prompt("u1", .sent))
        state.didSend(prompt("u2", .queued))
        state.apply(.exited(Termination(exitCode: 0, stderr: "")))
        XCTAssertEqual(state.phase, .atRest)
        XCTAssertEqual(
            state.prompts.map(\.delivery),
            [
                .notSent(reason: String(localized: "the session ended")),
                .notSent(reason: String(localized: "the session ended")),
            ])
    }

    func testAFailureExitWordsItAsExitCodeAndTheLastStderrLine() {
        launched()
        state.apply(.exited(Termination(exitCode: 1, stderr: "warming up\nError: boom\n\n")))
        XCTAssertEqual(
            state.phase,
            .failed(
                SessionFailure(
                    message: "\(String(localized: "Exit code \(1)")) · Error: boom", log: "warming up\nError: boom\n\n")
            ))
    }

    func testAnExitCodeWithNoStderrIsJustTheCode() {
        XCTAssertEqual(
            SessionFailure(Termination(exitCode: 2, stderr: "")).message, String(localized: "Exit code \(2)"))
    }

    func testCancellingALaunchGivesTheHeldWordsBackOldestFirst() {
        state.didBeginLaunch()
        state.didSend(prompt("u1", .held))
        state.didSend(prompt("u2", .held))
        XCTAssertEqual(state.didCancelLaunch(), ["text u1", "text u2"])
        XCTAssertEqual(state.phase, .atRest)
        XCTAssertTrue(state.prompts.isEmpty)
    }

    func testARestartIsADividerAndStartingAgain() {
        launched()
        state.didSend(prompt("u1", .sent))
        let restart = SessionState.Restart(afterMessage: "m1", accountName: "Work Relay", modelName: "Sonnet")
        state.didRestart(restart)
        XCTAssertEqual(state.phase, .starting)
        XCTAssertEqual(state.restarts, [restart])
        guard case .notSent? = state.prompts.first?.delivery else { return XCTFail("a sent prompt was lost") }
    }

    // MARK: - Settings × state

    func testTheTimingOfEachChangeInEachPhase() {
        let model = SessionSettings.Change.model(Fixture.choice("sonnet"))
        let other = SessionSettings.Change.model(Fixture.choice("haiku", on: Fixture.relay))
        for change in [model, other, .effort(.max), .permissionMode(.plan), .fastMode(true)] {
            XCTAssertEqual(state.timing(of: change), .atLaunch, "at rest")
        }
        state.didBeginLaunch()
        XCTAssertEqual(state.timing(of: other), .atLaunch, "starting: the launch starts over")
        state.didLaunch(SessionStateTests.initialization())
        XCTAssertEqual(state.timing(of: model), .now)
        XCTAssertEqual(state.timing(of: other), .restart)
        XCTAssertEqual(state.timing(of: .effort(.max)), .nextRequest)
        XCTAssertEqual(state.timing(of: .permissionMode(.plan)), .now)
        XCTAssertEqual(state.timing(of: .fastMode(true)), .now)
        state.didSend(prompt("u1", .sent))
        XCTAssertEqual(state.timing(of: model), .afterTurn)
        XCTAssertEqual(state.timing(of: .fastMode(true)), .afterTurn)
        XCTAssertEqual(state.timing(of: .effort(.max)), .nextRequest)
        XCTAssertEqual(state.timing(of: .permissionMode(.plan)), .now)
        XCTAssertEqual(state.timing(of: other), .restart)
    }

    func testAFailedSessionTakesChoicesForTheNextLaunch() {
        state.didFailToLaunch(SessionFailure(message: "x"))
        XCTAssertEqual(state.timing(of: .model(Fixture.choice("haiku", on: Fixture.relay))), .atLaunch)
    }

    func testAModelChosenWhileWorkingShowsAtOnceAndWaitsForTheTurn() {
        launched()
        state.didSend(prompt("u1", .sent))
        let sonnet = Fixture.choice("sonnet")
        state.didChoose(.model(sonnet), timing: .afterTurn, catalog: catalog)
        XCTAssertEqual(state.settings?.model, sonnet)
        XCTAssertEqual(state.pendingModel, sonnet)
        state.didApply(.model(sonnet))
        XCTAssertNil(state.pendingModel)
        XCTAssertEqual(state.settings?.model, sonnet)
    }

    func testChoosingBackWhatTheCLIRunsCancelsThePending() {
        launched()
        state.didSend(prompt("u1", .sent))
        state.didChoose(.model(Fixture.choice("sonnet")), timing: .afterTurn, catalog: catalog)
        state.didChoose(.model(Fixture.choice("opus")), timing: .afterTurn, catalog: catalog)
        XCTAssertNil(state.pendingModel)
    }

    func testAModelWithoutFastChosenWhileWorkingTakesFastOffAfterTheTurnToo() {
        state = SessionState(transcript: Transcript(messages: []), settings: Fixture.settings("opus", fast: true))
        launched()
        state.didSend(prompt("u1", .sent))
        state.didChoose(.model(Fixture.choice("sonnet")), timing: .afterTurn, catalog: catalog)
        XCTAssertEqual(state.settings?.fastMode, false)
        XCTAssertEqual(state.pendingFastMode, false)
    }

    func testAChoiceTheCLIRefusesRevertsWithTheReason() {
        launched()
        let before = state.settings!
        state.didChoose(.model(Fixture.choice("sonnet")), timing: .now, catalog: catalog)
        state.didRefuse(.model(Fixture.choice("sonnet")), previous: before, reason: "Not allowed.")
        XCTAssertEqual(state.settings, before)
        XCTAssertEqual(state.refusal, "Not allowed.")
        state.didChoose(.effort(.low), timing: .nextRequest, catalog: catalog)
        XCTAssertNil(state.refusal, "the next choice clears it")
    }

    func testRunningSettingsLeaveOutWhatWaitsForTheTurn() {
        launched()
        state.didSend(prompt("u1", .sent))
        state.didChoose(.model(Fixture.choice("sonnet")), timing: .afterTurn, catalog: catalog)
        XCTAssertEqual(state.runningSettings?.model, Fixture.choice("opus"))
    }

    func testChoicesMadeAtLaunchStandThroughInitialize() {
        state.didBeginLaunch()
        state.didChoose(.permissionMode(.plan), timing: .atLaunch, catalog: catalog)
        state.didLaunch(SessionStateTests.initialization(#"{"current_permission_mode":"default"}"#))
        XCTAssertEqual(state.settings?.permissionMode, .plan)
    }
}

import AgentSDK
import XCTest

@testable import ccterm

/// `SessionState.Phase`'s rule of when a change lands (design 08 *Settings ×
/// state*), asked of the phase and the settings alone.
final class SessionPhaseTests: XCTestCase {
    private typealias Fixture = SessionCatalogFixture
    private let settings = Fixture.settings("opus")
    private let failure = SessionFailure(message: "x")

    private var sameAccount: [SessionSettings.Change] {
        [.model(Fixture.choice("sonnet")), .fastMode(true), .effort(.max), .permissionMode(.plan)]
    }
    private let otherAccount = SessionSettings.Change.model(Fixture.choice("haiku", on: SessionCatalogFixture.relay))

    func testNoProcessOrOneStartingKeepsEveryChangeForTheLaunch() {
        for phase in [SessionState.Phase.atRest, .starting, .failed(failure)] {
            for change in sameAccount + [otherAccount] {
                XCTAssertEqual(phase.timing(of: change, from: settings), .atLaunch, "\(phase) \(change)")
            }
        }
    }

    func testIdleAppliesModelAndFastNowAndEffortWithTheNextRequestAndModeNow() {
        let phase = SessionState.Phase.idle
        XCTAssertEqual(phase.timing(of: .model(Fixture.choice("sonnet")), from: settings), .now)
        XCTAssertEqual(phase.timing(of: .fastMode(true), from: settings), .now)
        XCTAssertEqual(phase.timing(of: .effort(.max), from: settings), .nextRequest)
        XCTAssertEqual(phase.timing(of: .effort(nil), from: settings), .nextRequest)
        XCTAssertEqual(phase.timing(of: .permissionMode(.plan), from: settings), .now)
    }

    func testWorkingHoldsModelAndFastForTheTurnsEnd() {
        for phase in [SessionState.Phase.responding, .compacting] {
            XCTAssertEqual(phase.timing(of: .model(Fixture.choice("sonnet")), from: settings), .afterTurn)
            XCTAssertEqual(phase.timing(of: .fastMode(true), from: settings), .afterTurn)
            XCTAssertEqual(phase.timing(of: .effort(.max), from: settings), .nextRequest)
            XCTAssertEqual(phase.timing(of: .permissionMode(.plan), from: settings), .now)
        }
    }

    func testAnotherAccountIsARestartWhileAProcessRuns() {
        for phase in [SessionState.Phase.idle, .responding, .compacting] {
            XCTAssertEqual(phase.timing(of: otherAccount, from: settings), .restart)
        }
        XCTAssertEqual(
            SessionState.Phase.idle.timing(
                of: .model(Fixture.choice("sonnet")), from: Fixture.settings("haiku", on: Fixture.relay)),
            .restart, "the account compared is the settings'")
    }

    func testRunningAndWorking() {
        let running: [SessionState.Phase] = [.starting, .idle, .responding, .compacting]
        for phase in running { XCTAssertTrue(phase.isRunning) }
        XCTAssertFalse(SessionState.Phase.atRest.isRunning)
        XCTAssertFalse(SessionState.Phase.failed(failure).isRunning)
        XCTAssertEqual(running.filter(\.isWorking), [.responding, .compacting])
        XCTAssertFalse(SessionState.Phase.atRest.isWorking)
    }

    func testTheStatesTimingDelegatesAndKnowsNothingWithoutSettings() {
        var state = SessionState(transcript: .init(messages: []), settings: settings)
        state.didBeginLaunch()
        state.didLaunch(SessionStateTests.initialization())
        XCTAssertEqual(state.timing(of: .permissionMode(.plan)), .now)
        let unknown = SessionState(transcript: .init(messages: []))
        XCTAssertEqual(unknown.timing(of: .permissionMode(.plan)), .atLaunch)
    }
}

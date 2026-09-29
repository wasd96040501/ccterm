import AgentSDK
import XCTest

@testable import ccterm

/// ``LaunchCheckService``: every check probes, asks made while one runs share
/// it, the latest answer is kept, the probe is bounded by a timeout, and its
/// failures come in a few words.
@MainActor
final class LaunchCheckServiceTests: XCTestCase {
    private let probe = FakeProbe()

    private func service(timeout: TimeInterval = 10) -> LaunchCheckService {
        LaunchCheckService(timeout: timeout, probe: probe.probe)
    }

    func testTheLatestAnswerIsKeptPerConfiguration() async {
        let service = service()
        let orange = CLIConfiguration(customCommand: "orange")
        XCTAssertNil(service.cached(orange))
        let first = await service.check(orange)
        XCTAssertEqual(first, .valid(FakeProbe.version(of: "orange")))
        XCTAssertEqual(service.cached(orange), first)

        _ = await service.check(CLIConfiguration(customCommand: "orange", env: ["CLAUDE_CONFIG_DIR": "/tmp/x"]))
        XCTAssertEqual(probe.calls.count, 2, "another environment is another launch")
        XCTAssertEqual(service.cached(orange), first)
    }

    func testEachCheckRunsTheProbeAndReplacesTheKeptAnswer() async {
        let service = service()
        let orange = CLIConfiguration(customCommand: "orange")
        probe.fail("orange", with: AgentSDKError.binaryNotFound)
        let missing = await service.check(orange)
        XCTAssertEqual(missing, .invalid(String(localized: "Not found")))
        XCTAssertEqual(service.cached(orange), missing)

        probe.succeed("orange")
        let installed = await service.check(orange)
        XCTAssertEqual(installed, .valid(FakeProbe.version(of: "orange")))
        XCTAssertEqual(service.cached(orange), installed)
        XCTAssertEqual(probe.calls.count, 2)
    }

    func testChecksMadeWhileOneRunsShareIt() async {
        let gate = probe.hold("orange")
        let started = expectation(description: "the probe started")
        probe.onCall { _ in started.fulfill() }
        let service = service()
        let orange = CLIConfiguration(customCommand: "orange")

        async let first = service.check(orange)
        await fulfillment(of: [started], timeout: 10)
        async let second = service.check(orange)
        await gate.open()
        let results = await [first, second]

        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(probe.calls.count, 1)
    }

    func testTheProbeRunsWithTheServicesTimeoutButTheAnswerIsKeptForTheAskedConfiguration() async {
        let service = service(timeout: 3)
        let asked = CLIConfiguration(customCommand: "orange", timeout: 30)
        _ = await service.check(asked)
        XCTAssertEqual(probe.calls.first?.timeout, 3)
        XCTAssertNotNil(service.cached(asked))
    }

    func testFailuresAreShortMessages() async {
        let service = service()
        probe.fail("missing", with: AgentSDKError.binaryNotFound)
        probe.fail("silent", with: AgentSDKError.noVersion(output: "hello"))
        probe.fail(
            "crashing", with: AgentSDKError.versionFailed(exitCode: 1, message: "zsh: command not found: crashing"))
        probe.fail("mute", with: AgentSDKError.versionFailed(exitCode: 3, message: ""))
        probe.fail("unknown", with: AgentSDKError.versionFailed(exitCode: 127, message: "zsh:1: command not found: x"))
        probe.fail("locked", with: AgentSDKError.versionFailed(exitCode: 126, message: "zsh:1: permission denied: x"))
        probe.fail("slow", with: AgentSDKError.versionFailed(exitCode: 15, message: "Timed out after 10.0s"))
        probe.fail("stuck", with: AgentSDKError.launchFailed("no such file"))

        let missing = await service.check(CLIConfiguration(customCommand: "missing"))
        let silent = await service.check(CLIConfiguration(customCommand: "silent"))
        let crashing = await service.check(CLIConfiguration(customCommand: "crashing"))
        let mute = await service.check(CLIConfiguration(customCommand: "mute"))
        let slow = await service.check(CLIConfiguration(customCommand: "slow"))
        let stuck = await service.check(CLIConfiguration(customCommand: "stuck"))
        let unknown = await service.check(CLIConfiguration(customCommand: "unknown"))
        let locked = await service.check(CLIConfiguration(customCommand: "locked"))
        XCTAssertEqual(missing, .invalid(String(localized: "Not found")))
        XCTAssertEqual(silent, .invalid(String(localized: "Didn’t print a version")))
        XCTAssertEqual(crashing, .invalid("zsh: command not found: crashing"))
        XCTAssertEqual(mute, .invalid(String(localized: "Exited with code \(3)")))
        XCTAssertEqual(slow, .invalid(String(localized: "Timed out")))
        XCTAssertEqual(stuck, .invalid(String(localized: "Couldn’t start")))
        XCTAssertEqual(unknown, .invalid(String(localized: "Not found")))
        XCTAssertEqual(locked, .invalid(String(localized: "Not executable")))
    }
}

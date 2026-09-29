import AgentSDK
import XCTest

@testable import ccterm

/// ``LaunchCheckService``: one probe per configuration, shared by asks made
/// while it runs, bounded by a timeout, and its failures in a few words.
@MainActor
final class LaunchCheckServiceTests: XCTestCase {
    private let probe = FakeProbe()

    private func service(timeout: TimeInterval = 10) -> LaunchCheckService {
        LaunchCheckService(timeout: timeout, probe: probe.probe)
    }

    func testAnAnswerIsKeptPerConfiguration() async {
        let service = service()
        let orange = CLIConfiguration(customCommand: "orange")
        XCTAssertNil(service.cached(orange))
        let first = await service.check(orange)
        let second = await service.check(orange)
        XCTAssertEqual(first, .valid(FakeProbe.version(of: "orange")))
        XCTAssertEqual(second, first)
        XCTAssertEqual(service.cached(orange), first)
        XCTAssertEqual(probe.calls.count, 1)

        _ = await service.check(CLIConfiguration(customCommand: "orange", env: ["CLAUDE_CONFIG_DIR": "/tmp/x"]))
        XCTAssertEqual(probe.calls.count, 2, "another environment is another launch")
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
        probe.fail("mute", with: AgentSDKError.versionFailed(exitCode: 127, message: ""))
        probe.fail("slow", with: AgentSDKError.versionFailed(exitCode: 15, message: "Timed out after 10.0s"))
        probe.fail("stuck", with: AgentSDKError.launchFailed("no such file"))

        let missing = await service.check(CLIConfiguration(customCommand: "missing"))
        let silent = await service.check(CLIConfiguration(customCommand: "silent"))
        let crashing = await service.check(CLIConfiguration(customCommand: "crashing"))
        let mute = await service.check(CLIConfiguration(customCommand: "mute"))
        let slow = await service.check(CLIConfiguration(customCommand: "slow"))
        let stuck = await service.check(CLIConfiguration(customCommand: "stuck"))
        XCTAssertEqual(missing, .invalid(String(localized: "Not found")))
        XCTAssertEqual(silent, .invalid(String(localized: "Didn't print a version")))
        XCTAssertEqual(crashing, .invalid("zsh: command not found: crashing"))
        XCTAssertEqual(mute, .invalid(String(localized: "Exited with code \(127)")))
        XCTAssertEqual(slow, .invalid(String(localized: "Timed out")))
        XCTAssertEqual(stuck, .invalid(String(localized: "Couldn't start")))
    }
}

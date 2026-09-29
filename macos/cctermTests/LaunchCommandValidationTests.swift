import AgentSDK
import Combine
import XCTest

@testable import ccterm

/// ``TextValidation`` as launch commands and folders use it: what it shows
/// while typing, and the commit contract — a value is applied when known
/// good, waited for while checking, and never when invalid or changed.
@MainActor
final class LaunchCommandValidationTests: XCTestCase {
    private let probe = FakeProbe()
    private var check: LaunchCheckService!

    override func setUp() {
        check = LaunchCheckService(probe: probe.probe)
    }

    private func validation(text: String = "", debounce: Duration = .zero) -> LaunchCommandValidation {
        LaunchCommandValidation(
            check: check, configuration: { CLIConfiguration(customCommand: $0.isEmpty ? nil : $0) }, text: text,
            debounce: debounce)
    }

    private func valid(_ command: String) -> LaunchCommandValidation.State {
        .valid(FakeProbe.version(of: command.isEmpty ? nil : command))
    }

    func testAKnownAnswerIsShownFromTheFirstFrame() async {
        _ = await check.check(CLIConfiguration(customCommand: "orange"))
        let validation = validation(text: "orange")
        XCTAssertEqual(validation.state, valid("orange"))
        XCTAssertTrue(validation.isValid)
    }

    func testAnUnknownAnswerIsCheckedAtOnce() async {
        let validation = validation(text: "orange")
        XCTAssertEqual(validation.state, .checking)
        XCTAssertFalse(validation.isValid)
        await waitFor(validation.$state) { $0 == self.valid("orange") }
        XCTAssertTrue(validation.isValid)
    }

    func testTypingKeepsTheLastStateUntilTheCheckStarts() async {
        let validation = validation(text: "orange")
        await waitFor(validation.$state) { $0 == self.valid("orange") }
        let gate = probe.hold("blue")
        let states = record(validation.$state)

        validation.textDidChange("blue")
        XCTAssertEqual(validation.state, valid("orange"), "the old answer stays while typing")
        XCTAssertFalse(validation.isValid, "but it is not an answer for the text now")
        await waitFor(validation.$state) { $0 == .checking }
        await gate.open()
        await waitFor(validation.$state) { $0 == self.valid("blue") }
        XCTAssertEqual(states.values, [valid("orange"), .checking, valid("blue")])
        XCTAssertTrue(validation.isValid)
    }

    func testACachedAnswerShowsAtOnceAndRunsNothing() async {
        _ = await check.check(CLIConfiguration(customCommand: "blue"))
        let validation = validation(text: "")
        await waitFor(validation.$state) { $0 == self.valid("") }
        let calls = probe.calls.count
        validation.textDidChange("blue")
        XCTAssertEqual(validation.state, valid("blue"))
        XCTAssertTrue(validation.isValid)
        XCTAssertEqual(probe.calls.count, calls)
    }

    func testCommittingAKnownGoodValueAppliesItNow() async {
        _ = await check.check(CLIConfiguration(customCommand: "blue"))
        let validation = validation(text: "blue")
        var applied: [String] = []
        validation.commit("blue") { applied.append($0) }
        XCTAssertEqual(applied, ["blue"])
    }

    func testCommittingWhileCheckingAppliesWhenItLandsValid() async {
        let gate = probe.hold("blue")
        let validation = validation(text: "")
        await waitFor(validation.$state) { $0 == self.valid("") }
        var applied: [String] = []
        let done = expectation(description: "applied")

        validation.textDidChange("blue")
        await waitFor(validation.$state) { $0 == .checking }
        validation.commit("blue") {
            applied.append($0)
            done.fulfill()
        }
        XCTAssertEqual(applied, [])
        await gate.open()
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(applied, ["blue"])
    }

    func testCommittingSkipsTheDebounce() async {
        let validation = validation(text: "", debounce: .seconds(3600))
        await waitFor(validation.$state) { $0 == self.valid("") }
        let done = expectation(description: "applied")
        var applied: [String] = []

        validation.textDidChange("blue")
        XCTAssertEqual(probe.calls.count, 1, "nothing runs while the debounce waits")
        validation.commit("blue") {
            applied.append($0)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(applied, ["blue"])
    }

    func testAnInvalidValueIsNeverApplied() async {
        probe.fail("broken", with: AgentSDKError.binaryNotFound)
        let validation = validation(text: "")
        await waitFor(validation.$state) { $0 == self.valid("") }
        var applied: [String] = []

        validation.commit("broken") { applied.append($0) }
        await waitFor(validation.$state) { $0 == .invalid(String(localized: "Not found")) }
        XCTAssertFalse(validation.isValid)
        XCTAssertEqual(applied, [])

        validation.commit("broken") { applied.append($0) }
        XCTAssertEqual(applied, [], "already known invalid: dropped at once")
    }

    func testChangingTheTextDropsAPendingCommit() async {
        let gate = probe.hold("blue")
        let validation = validation(text: "")
        await waitFor(validation.$state) { $0 == self.valid("") }
        var applied: [String] = []

        validation.textDidChange("blue")
        await waitFor(validation.$state) { $0 == .checking }
        validation.commit("blue") { applied.append($0) }
        validation.textDidChange("green")
        await gate.open()
        await waitFor(validation.$state) { $0 == self.valid("green") }
        XCTAssertEqual(applied, [])
    }

    func testFoldersAreCheckedOnTheDiskAfterTypingPauses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let validation = FolderValidation(text: "", debounce: .zero)
        await waitFor(validation.$state) { if case .valid = $0 { true } else { false } }
        var applied: [String] = []

        validation.commit(root.appendingPathComponent("missing").path) { applied.append($0) }
        await waitFor(validation.$state) {
            if case .invalid(let problem) = $0 { problem == String(localized: "Folder doesn’t exist") } else { false }
        }
        XCTAssertEqual(applied, [])

        let done = expectation(description: "applied")
        validation.commit(root.path) {
            applied.append($0)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(applied, [root.path])
    }
}

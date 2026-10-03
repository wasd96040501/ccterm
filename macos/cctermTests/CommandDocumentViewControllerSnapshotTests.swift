import AppKit
import DisplayModels
import XCTest

@testable import ccterm

/// The command document in every state, in light and dark
/// (design/transcript/02-command.md). Review only —
/// `make test-unit FILTER=CommandDocumentViewControllerSnapshotTests`, then
/// open `/tmp/ccterm-screenshots/CommandDocumentViewController-<state>.png`.
@MainActor
final class CommandDocumentViewControllerSnapshotTests: XCTestCase {
    private let size = CGSize(width: 640, height: 420)

    private static let log = """
        Test Suite 'TranscriptViewTests' started
        Test Case 'testRows' \u{1B}[1;32mpassed\u{1B}[0m (0.02 seconds)
        Test Case 'testSpacing' \u{1B}[31mfailed\u{1B}[0m (0.01 seconds)
        TranscriptViewTests.swift:41:5: error: 'rowSpacing' is inaccessible due to 'private' protection level
        ** TEST FAILED **
        """

    private func snapshot(_ name: String, _ command: CommandDocumentViewController.Command) {
        let sheet = ViewSnapshot.renderLightAndDark(
            { CommandDocumentViewController(command) }, size: size, name: name)
        let url = ViewSnapshot.writePNG(sheet, name: "CommandDocumentViewController-\(name)")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFailedWithOutput() {
        snapshot(
            "failed",
            .call(
                ToolCallFixture.failedBash(
                    "cd ~/dev/ccterm && make test-unit FILTER=TranscriptViewTests", description: "Run the unit tests",
                    output: Self.log)))
    }

    func testDoneWithStderrNoteAndSandboxOff() {
        snapshot(
            "done",
            .call(
                ToolCallFixture.bash(
                    "grep -rn 'Self.rowSpacing' macos | sort", description: "Find the old constant",
                    stdout: "macos/A.swift:3: Self.rowSpacing\nmacos/B.swift:9: Self.rowSpacing",
                    stderr: "grep: macos/build: Permission denied",
                    interpretation: "Some directories could not be read.", sandboxOff: true, duration: 0.4)))
    }

    func testLongCommandFolds() {
        let command =
            "cd ~/dev/ccterm && " + (1...20).map { "echo \"line \($0)\" \\\n  && true" }.joined(separator: " ")
        snapshot("long", .call(ToolCallFixture.bash(command, description: "Print twenty lines", stdout: "line 1")))
    }

    func testLiveStates() {
        let running = ToolCallFixture.call(
            "Bash", #"{"command":"sleep 30 && make","description":"Wait for the build"}"#, state: .running,
            hasResult: false)
        snapshot("running", .call(running))
        let waiting = ToolCallFixture.call(
            "Bash", #"{"command":"rm -rf macos/build","description":"Remove the build products"}"#,
            state: .waiting(reason: nil), hasResult: false)
        snapshot("waiting", .call(waiting))
        let denied = ToolCallFixture.call(
            "Bash", #"{"command":"rm -rf /"}"#, state: .denied, hasResult: false)
        snapshot("denied", .call(denied))
    }

    func testNoOutputPersistedAndLocal() {
        snapshot("empty", .call(ToolCallFixture.bash("true", description: "Do nothing")))
        snapshot(
            "persisted",
            .call(
                ToolCallFixture.bash(
                    "make build", description: "Build", stdout: "Compiling…\nLinking…",
                    persisted: "/Users/me/.claude/tool-results/abc.txt")))
        snapshot(
            "local",
            .local(
                LocalCommand(
                    id: "l1", command: .shell("git status -sb"), output: "## main...origin/main\n M A.swift",
                    errorOutput: "")))
    }
}

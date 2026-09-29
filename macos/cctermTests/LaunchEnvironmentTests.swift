import AgentSDK
import XCTest

@testable import ccterm

/// How settings become a launch: which command wins, what the environment
/// holds, and what is wrong with a configuration folder.
final class LaunchEnvironmentTests: XCTestCase {
    func testAnAccountsCommandWinsOverGeneralsWhichWinsOverNone() {
        let general = LaunchPreferences(command: "  orange  ", configDirectory: "")
        XCTAssertEqual(
            LaunchEnvironment.resolve(command: "relay-wrapper", general: general).customCommand, "relay-wrapper")
        XCTAssertEqual(LaunchEnvironment.resolve(command: "", general: general).customCommand, "orange")
        XCTAssertEqual(LaunchEnvironment.resolve(command: "   ", general: general).customCommand, "orange")
        XCTAssertNil(LaunchEnvironment.resolve(command: "", general: LaunchPreferences()).customCommand)
    }

    func testTheCommandIsPassedAsWritten() {
        let command = "CLAUDE_CONFIG_DIR=~/other my-claude --fast"
        XCTAssertEqual(LaunchEnvironment.resolve(command: command, general: LaunchPreferences()).customCommand, command)
    }

    func testGeneralsFolderBecomesClaudeConfigDirWithTheTildeExpanded() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let general = LaunchPreferences(command: "", configDirectory: "~/work/claude")
        XCTAssertEqual(
            LaunchEnvironment.resolve(command: "wrapper", general: general).env,
            ["CLAUDE_CONFIG_DIR": home + "/work/claude"])
        XCTAssertEqual(
            LaunchEnvironment.resolve(command: "", general: LaunchPreferences(configDirectory: "/tmp/claude")).env,
            ["CLAUDE_CONFIG_DIR": "/tmp/claude"])
        XCTAssertEqual(LaunchEnvironment.resolve(command: "", general: LaunchPreferences()).env, [:])
    }

    func testFolderProblemIsNilForEmptyAndForAnExistingFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(LaunchPreferences.folderProblem(""))
        XCTAssertNil(LaunchPreferences.folderProblem("   "))
        XCTAssertNil(LaunchPreferences.folderProblem(root.path))
        XCTAssertNil(LaunchPreferences.folderProblem("~"))
    }

    func testFolderProblemSaysMissingOrNotAFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertEqual(
            LaunchPreferences.folderProblem(root.appendingPathComponent("missing").path),
            String(localized: "Folder doesn’t exist"))
        XCTAssertEqual(LaunchPreferences.folderProblem(file.path), String(localized: "Not a folder"))
    }
}

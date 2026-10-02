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

    // MARK: - An account's launch

    private func provider(
        command: String = "", arguments: String = "", authentication: Account.Authentication = .authToken,
        models: Account.Models = Account.Models()
    ) -> Account {
        Account(
            id: UUID(),
            kind: .provider(
                Account.Provider(
                    name: "Relay", baseURL: " https://relay.example.com ", authentication: authentication,
                    models: models)),
            command: command, arguments: arguments)
    }

    func testAProvidersEnvironmentIsItsURLCredentialAndModels() {
        let account = provider(
            models: Account.Models(main: "relay-main", opus: "relay-opus", sonnet: "", haiku: "relay-haiku"))
        let configuration = LaunchEnvironment.resolve(
            account: account, secrets: AccountSecrets(credential: "sk-1"), general: LaunchPreferences())
        XCTAssertEqual(
            configuration.env,
            [
                "ANTHROPIC_BASE_URL": "https://relay.example.com", "ANTHROPIC_AUTH_TOKEN": "sk-1",
                "ANTHROPIC_MODEL": "relay-main", "ANTHROPIC_DEFAULT_OPUS_MODEL": "relay-opus",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL": "relay-haiku",
            ])
    }

    func testAnAPIKeyProviderUsesTheAPIKeyVariableAndAnEmptyCredentialSetsNone() {
        let configuration = LaunchEnvironment.resolve(
            account: provider(authentication: .apiKey), secrets: AccountSecrets(credential: "k"),
            general: LaunchPreferences())
        XCTAssertEqual(configuration.env["ANTHROPIC_API_KEY"], "k")
        XCTAssertNil(configuration.env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(
            LaunchEnvironment.resolve(account: provider(), secrets: AccountSecrets(), general: LaunchPreferences())
                .env["ANTHROPIC_AUTH_TOKEN"])
    }

    func testTheSubscriptionAddsNothingButItsOwnVariablesAndGeneralsFolder() {
        let secrets = AccountSecrets(
            credential: "ignored",
            environment: [
                EnvironmentVariable(name: "http proxy", value: "http://p"),
                EnvironmentVariable(isEnabled: false, name: "OFF", value: "no"),
            ])
        let configuration = LaunchEnvironment.resolve(
            account: .subscription(), secrets: secrets, general: LaunchPreferences(configDirectory: "/tmp/claude"))
        XCTAssertEqual(configuration.env, ["CLAUDE_CONFIG_DIR": "/tmp/claude", "HTTP_PROXY": "http://p"])
    }

    func testAnAccountsOwnVariablesWinOverTheProvidersAndGenerals() {
        let secrets = AccountSecrets(
            credential: "sk",
            environment: [
                EnvironmentVariable(name: "ANTHROPIC_BASE_URL", value: "https://mine"),
                EnvironmentVariable(name: "CLAUDE_CONFIG_DIR", value: "/mine"),
            ])
        let configuration = LaunchEnvironment.resolve(
            account: provider(), secrets: secrets, general: LaunchPreferences(configDirectory: "/general"))
        XCTAssertEqual(configuration.env["ANTHROPIC_BASE_URL"], "https://mine")
        XCTAssertEqual(configuration.env["CLAUDE_CONFIG_DIR"], "/mine")
    }

    func testAnAccountsArgumentsFollowItsCommandAsTypedAtAPrompt() {
        let general = LaunchPreferences(command: "general-claude")
        let both = LaunchEnvironment.resolve(
            account: provider(command: "relay-wrapper", arguments: "--append-system-prompt 'be terse'"),
            secrets: AccountSecrets(), general: general)
        XCTAssertEqual(both.customCommand, "relay-wrapper --append-system-prompt 'be terse'")
        let general_ = LaunchEnvironment.resolve(
            account: provider(arguments: "--verbose"), secrets: AccountSecrets(), general: general)
        XCTAssertEqual(general_.customCommand, "general-claude --verbose")
        let bare = LaunchEnvironment.resolve(
            account: provider(arguments: "--verbose"), secrets: AccountSecrets(), general: LaunchPreferences())
        XCTAssertEqual(bare.customCommand, "claude --verbose")
        XCTAssertNil(
            LaunchEnvironment.resolve(account: provider(), secrets: AccountSecrets(), general: LaunchPreferences())
                .customCommand)
    }
}

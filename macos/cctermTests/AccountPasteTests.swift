import XCTest

@testable import ccterm

/// ``AccountPaste``: reading provider settings the way people keep them —
/// `KEY=value` lines, `export` lines, launch lines, shell aliases, a whole
/// profile — into entries, and applying an entry to an account.
final class AccountPasteTests: XCTestCase {
    private func entry(_ text: String) throws -> AccountPaste.Entry {
        let entries = AccountPaste.entries(text)
        XCTAssertEqual(entries.count, 1, text)
        return try XCTUnwrap(entries.first)
    }

    func testAliasFillsFieldsVariablesCommandAndName() throws {
        let text = #"""
            alias relay="API_TIMEOUT_MS=3000000 ANTHROPIC_BASE_URL=https://relay.example.com ANTHROPIC_AUTH_TOKEN=sk-relay-0000a1b2 ANTHROPIC_MODEL=claude-opus-5-5[1m] ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5 claude --permission-mode auto"
            """#
        var account = Account.newProvider()
        var secrets = AccountSecrets()
        let result = try entry(text).apply(to: &account, secrets: &secrets)

        let provider = try XCTUnwrap(account.provider)
        XCTAssertEqual(provider.name, "relay")
        XCTAssertEqual(provider.baseURL, "https://relay.example.com")
        XCTAssertEqual(provider.authentication, .authToken)
        XCTAssertEqual(provider.models.main, "claude-opus-5-5[1m]")
        XCTAssertEqual(provider.models.haiku, "claude-haiku-4-5")
        XCTAssertEqual(secrets.credential, "sk-relay-0000a1b2")
        XCTAssertEqual(secrets.environment, [EnvironmentVariable(name: "API_TIMEOUT_MS", value: "3000000")])
        XCTAssertEqual(account.command, "", "plain claude stays the default")
        XCTAssertEqual(account.arguments, "--permission-mode auto")
        XCTAssertEqual(result.variableCount, 1)
        XCTAssertEqual(result.fields, [.baseURL, .credential(.authToken), .model, .haiku, .arguments, .name])
    }

    func testExportLinesWithQuotesUpdateExistingVariables() throws {
        var account = Account.subscription()
        var secrets = AccountSecrets(environment: [EnvironmentVariable(name: "FOO", value: "old")])
        let result = try entry("export FOO=\"a b\"\nexport BAR='x'\n").apply(to: &account, secrets: &secrets)
        XCTAssertEqual(secrets.environment.map(\.name), ["FOO", "BAR"])
        XCTAssertEqual(secrets.environment.map(\.value), ["a b", "x"])
        XCTAssertEqual(result.variableCount, 2)
        XCTAssertEqual(result.fields, [])
    }

    func testTheSubscriptionKeepsProviderKeysAsVariables() throws {
        var account = Account.subscription()
        var secrets = AccountSecrets()
        _ = try entry("ANTHROPIC_BASE_URL=http://127.0.0.1:9999").apply(to: &account, secrets: &secrets)
        XCTAssertEqual(account.kind, .subscription)
        XCTAssertEqual(secrets.environment.map(\.name), ["ANTHROPIC_BASE_URL"])
    }

    func testAConfigDirectoryVariableStaysAPlainVariable() throws {
        var account = Account.newProvider()
        var secrets = AccountSecrets()
        _ = try entry("CLAUDE_CONFIG_DIR=~/.claude-work claude").apply(to: &account, secrets: &secrets)
        XCTAssertEqual(secrets.environment.map(\.name), ["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(
            secrets.environment.first?.value, FileManager.default.homeDirectoryForCurrentUser.path + "/.claude-work")
    }

    func testAWrapperCommandBecomesTheAccountsCommand() throws {
        var account = Account.newProvider()
        var secrets = AccountSecrets()
        _ = try entry("X=1 my-proxy --fast").apply(to: &account, secrets: &secrets)
        XCTAssertEqual(account.command, "my-proxy")
        XCTAssertEqual(account.arguments, "--fast")
    }

    func testTextWithoutAssignmentsHasNoEntries() {
        XCTAssertEqual(AccountPaste.entries("just some words"), [])
        XCTAssertEqual(AccountPaste.entries(""), [])
        XCTAssertEqual(AccountPaste.entries("claude --permission-mode auto"), [])
        XCTAssertEqual(AccountPaste.entries("# ANTHROPIC_BASE_URL=https://x.example.com"), [])
    }

    func testALocalBaseURLNamesTheProviderLocalProxy() throws {
        var account = Account.newProvider()
        var secrets = AccountSecrets()
        _ = try entry("ANTHROPIC_BASE_URL=http://127.0.0.1:8788").apply(to: &account, secrets: &secrets)
        XCTAssertEqual(account.provider?.name, String(localized: "Local Proxy"))
    }

    // MARK: - Splitting

    func testEachAliasIsAnEntryNamedByIt() {
        let text = """
            alias one="A=1 claude"
            alias two='B=2 my-proxy --fast'
            """
        XCTAssertEqual(
            AccountPaste.entries(text),
            [
                AccountPaste.Entry(
                    name: "one", variables: [.init(name: "A", value: "1")], command: "claude"),
                AccountPaste.Entry(
                    name: "two", variables: [.init(name: "B", value: "2")], command: "my-proxy", arguments: "--fast"),
            ])
    }

    func testAnAliasThatSetsNoVariableIsIgnored() {
        let text = """
            alias ll='ls -la'
            alias gs="git status"
            alias cc="claude --dangerously-skip-permissions"
            """
        XCTAssertEqual(AccountPaste.entries(text), [])
    }

    func testEachLaunchLineIsAnEntry() {
        let text = """
            A=1 claude
            export B=2 claude --verbose
            """
        XCTAssertEqual(
            AccountPaste.entries(text),
            [
                AccountPaste.Entry(variables: [.init(name: "A", value: "1")], command: "claude"),
                AccountPaste.Entry(
                    variables: [.init(name: "B", value: "2")], command: "claude", arguments: "--verbose"),
            ])
    }

    func testARunOfBareLinesIsOneEntryEndedByABlankLine() {
        let text = """
            export A=1
            B=2

            export C=3
            """
        XCTAssertEqual(
            AccountPaste.entries(text),
            [
                AccountPaste.Entry(variables: [.init(name: "A", value: "1"), .init(name: "B", value: "2")]),
                AccountPaste.Entry(variables: [.init(name: "C", value: "3")]),
            ])
    }

    func testACommandLineJoinsTheRunItEnds() {
        let text = """
            export A=1
            export B=2
            claude --permission-mode auto

            C=3 my-proxy
            """
        XCTAssertEqual(
            AccountPaste.entries(text),
            [
                AccountPaste.Entry(
                    variables: [.init(name: "A", value: "1"), .init(name: "B", value: "2")], command: "claude",
                    arguments: "--permission-mode auto"),
                AccountPaste.Entry(variables: [.init(name: "C", value: "3")], command: "my-proxy"),
            ])
        XCTAssertEqual(
            AccountPaste.entries("A=1\nC=3 my-proxy"),
            [
                AccountPaste.Entry(
                    variables: [.init(name: "A", value: "1"), .init(name: "C", value: "3")], command: "my-proxy")
            ],
            "a command line with variables joins the run")
    }

    func testACommandThatIsNotClaudeDoesNotJoinARunWithoutVariables() {
        XCTAssertEqual(
            AccountPaste.entries("export A=1\nsource ~/.nvm/nvm.sh\n"),
            [AccountPaste.Entry(variables: [.init(name: "A", value: "1")])])
    }

    func testAWholeProfileYieldsOnlyWhatSetsVariables() {
        let text = #"""
            # Path
            export PATH="$HOME/bin:$PATH"

            # relay
            alias relay="ANTHROPIC_BASE_URL=https://relay.example.com ANTHROPIC_AUTH_TOKEN=sk-relay claude"
            alias ll='ls -la'
            eval "$(starship init zsh)"
            # comment inside a run
            export NODE_OPTIONS=--max-old-space-size=4096
            # another comment
            export EDITOR=vim
            """#
        let entries = AccountPaste.entries(text)
        XCTAssertEqual(entries.map(\.name), [nil, "relay", nil])
        XCTAssertEqual(entries[1].variables.map(\.name), ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN"])
        XCTAssertEqual(entries[2].variables.map(\.name), ["NODE_OPTIONS", "EDITOR"])
    }

    // MARK: - Importing

    func testImportingSkipsAnEntryThatCannotBeNamed() {
        let entries = AccountPaste.entries("ANTHROPIC_BASE_URL=not-a-url ANTHROPIC_AUTH_TOKEN=sk-1 claude")
        let (providers, skipped) = AccountPaste.importable(entries, existingNames: [])
        XCTAssertTrue(providers.isEmpty)
        XCTAssertEqual(skipped, 1)
    }

    func testImportingSkipsEntriesWithoutAURLOrACredentialAndNamesTheRestApart() {
        let text = """
            alias relay="ANTHROPIC_BASE_URL=https://relay.example.com ANTHROPIC_AUTH_TOKEN=sk-1 claude"
            alias relay="ANTHROPIC_BASE_URL=https://other.example.com ANTHROPIC_API_KEY=sk-2 claude"
            export PATH=/usr/bin

            ANTHROPIC_BASE_URL=https://no-token.example.com
            """
        let (providers, skipped) = AccountPaste.importable(AccountPaste.entries(text), existingNames: ["relay"])
        XCTAssertEqual(providers.compactMap { $0.0.provider?.name }, ["relay 2", "relay 3"])
        XCTAssertEqual(providers.map { $0.1.credential }, ["sk-1", "sk-2"])
        XCTAssertEqual(providers.compactMap { $0.0.provider?.authentication }, [.authToken, .apiKey])
        XCTAssertEqual(skipped, 2)
    }
}

import XCTest

@testable import ccterm

/// ``AccountPaste``: reading provider settings the way people keep them —
/// `KEY=value` lines, `export` lines, a whole shell alias.
final class AccountPasteTests: XCTestCase {
    func testAliasFillsFieldsVariablesCommandAndName() throws {
        let text = #"""
            alias relay="API_TIMEOUT_MS=3000000 ANTHROPIC_BASE_URL=https://relay.example.com ANTHROPIC_AUTH_TOKEN=sk-relay-0000a1b2 ANTHROPIC_MODEL=claude-opus-5-5[1m] ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5 claude --permission-mode auto"
            """#
        let paste = try XCTUnwrap(AccountPaste(text))
        var account = Account.newProvider()
        var secrets = AccountSecrets()
        let result = paste.apply(to: &account, secrets: &secrets)

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
        let paste = try XCTUnwrap(AccountPaste("export FOO=\"a b\"\nexport BAR='x'\n"))
        var account = Account.subscription()
        var secrets = AccountSecrets(environment: [EnvironmentVariable(name: "FOO", value: "old")])
        let result = paste.apply(to: &account, secrets: &secrets)
        XCTAssertEqual(secrets.environment.map(\.name), ["FOO", "BAR"])
        XCTAssertEqual(secrets.environment.map(\.value), ["a b", "x"])
        XCTAssertEqual(result.variableCount, 2)
        XCTAssertEqual(result.fields, [])
    }

    func testTheSubscriptionKeepsProviderKeysAsVariables() throws {
        let paste = try XCTUnwrap(AccountPaste("ANTHROPIC_BASE_URL=http://127.0.0.1:9999"))
        var account = Account.subscription()
        var secrets = AccountSecrets()
        _ = paste.apply(to: &account, secrets: &secrets)
        XCTAssertEqual(account.kind, .subscription)
        XCTAssertEqual(secrets.environment.map(\.name), ["ANTHROPIC_BASE_URL"])
    }

    func testAWrapperCommandBecomesTheAccountsCommand() throws {
        let paste = try XCTUnwrap(AccountPaste("X=1 my-proxy --fast"))
        var account = Account.newProvider()
        var secrets = AccountSecrets()
        _ = paste.apply(to: &account, secrets: &secrets)
        XCTAssertEqual(account.command, "my-proxy")
        XCTAssertEqual(account.arguments, "--fast")
    }

    func testTextWithoutAssignmentsIsNotAPaste() {
        XCTAssertNil(AccountPaste("just some words"))
        XCTAssertNil(AccountPaste(""))
    }

    func testALocalBaseURLNamesTheProviderLocalProxy() throws {
        let paste = try XCTUnwrap(AccountPaste("ANTHROPIC_BASE_URL=http://127.0.0.1:8788"))
        var account = Account.newProvider()
        var secrets = AccountSecrets()
        _ = paste.apply(to: &account, secrets: &secrets)
        XCTAssertEqual(account.provider?.name, String(localized: "Local Proxy"))
    }
}

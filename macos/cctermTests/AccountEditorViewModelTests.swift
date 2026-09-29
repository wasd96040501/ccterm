import XCTest

@testable import ccterm

/// What the account sheet shows, derived from its draft: when it can be
/// saved, the Base URL's error, the credential row, masking, variable
/// warnings, and what a paste fills.
@MainActor
final class AccountEditorViewModelTests: XCTestCase {
    private func newProvider() -> AccountEditorViewModel {
        AccountEditorViewModel(mode: .newProvider, account: .newProvider(), secrets: AccountSecrets())
    }

    func testANewProviderNeedsANameAValidURLAndACredential() {
        let model = newProvider()
        XCTAssertFalse(model.presentation.canSave)
        model.setName("Relay")
        model.setBaseURL("https://relay.example.com")
        XCTAssertFalse(model.presentation.canSave)
        model.setCredential("sk-example")
        XCTAssertTrue(model.presentation.canSave)
        model.setName("  ")
        XCTAssertFalse(model.presentation.canSave)
    }

    func testABaseURLThatIsNotHTTPSaysSoOnlyOnceTyped() {
        let model = newProvider()
        XCTAssertNil(model.presentation.baseURLError)
        model.setBaseURL("relay.example.com")
        XCTAssertNotNil(model.presentation.baseURLError)
        model.setBaseURL("ftp://relay.example.com")
        XCTAssertNotNil(model.presentation.baseURLError)
        model.setBaseURL("http://127.0.0.1:8788")
        XCTAssertNil(model.presentation.baseURLError)
    }

    func testTheCredentialRowFollowsTheAuthentication() {
        let model = newProvider()
        model.setCredential("sk-proxy-example-4b0e9d2c7c1e")
        XCTAssertEqual(model.presentation.credentialTitle, String(localized: "Token"))
        XCTAssertEqual(model.presentation.maskedCredential, "sk-••••••••7c1e")
        model.setAuthentication(.apiKey)
        XCTAssertEqual(model.presentation.credentialTitle, String(localized: "API key"))
        XCTAssertEqual(model.presentation.fields.authentication, .apiKey)
    }

    func testAPastedFableModelFillsItsField() {
        let model = newProvider()
        _ = model.paste("ANTHROPIC_DEFAULT_FABLE_MODEL=claude-fable-5-1\nANTHROPIC_MODEL=claude-opus-5-5")
        XCTAssertEqual(model.presentation.fields.fable, "claude-fable-5-1")
        XCTAssertEqual(model.presentation.fields.model, "claude-opus-5-5")
        XCTAssertTrue(model.presentation.environmentRows.isEmpty)
    }

    func testShortSecretsAreMaskedWhole() {
        XCTAssertEqual(AccountEditorViewModel.masked(""), "")
        XCTAssertEqual(AccountEditorViewModel.masked("abcd"), "••••")
    }

    func testSecretLookingValuesAreMaskedAndManagedOrRepeatedNamesWarn() {
        let model = AccountEditorViewModel(
            mode: .newProvider, account: .newProvider(),
            secrets: AccountSecrets(environment: [
                EnvironmentVariable(name: "MY_TOKEN", value: "tok-0123456789"),
                EnvironmentVariable(name: "ANTHROPIC_BASE_URL", value: "https://other.example.com"),
                EnvironmentVariable(name: "API_TIMEOUT_MS", value: "1"),
                EnvironmentVariable(name: "API_TIMEOUT_MS", value: "2"),
            ]))
        let rows = model.presentation.environmentRows
        XCTAssertEqual(rows[0].displayValue, "tok••••••••6789")
        XCTAssertNil(rows[0].warning)
        XCTAssertNotNil(rows[1].warning)
        XCTAssertNotNil(rows[2].warning)
        XCTAssertNotNil(rows[3].warning)
        XCTAssertEqual(model.variableValue(at: 0), "tok-0123456789")
    }

    func testAPasteFillsTheFieldsAndBumpsTheirRevision() {
        let model = newProvider()
        let before = model.presentation.fieldsRevision
        _ = model.paste(
            #"alias relay="ANTHROPIC_BASE_URL=https://relay.example.com ANTHROPIC_AUTH_TOKEN=sk-relay-example-0000a1b2 API_TIMEOUT_MS=3000000 claude --permission-mode auto""#
        )
        let presentation = model.presentation
        XCTAssertGreaterThan(presentation.fieldsRevision, before)
        XCTAssertEqual(presentation.fields.name, "relay")
        XCTAssertEqual(presentation.fields.baseURL, "https://relay.example.com")
        XCTAssertEqual(presentation.fields.arguments, "--permission-mode auto")
        XCTAssertEqual(presentation.environmentRows.map(\.name), ["API_TIMEOUT_MS"])
        XCTAssertTrue(presentation.canSave)
    }

    func testRowsWithoutANameAreNotSaved() {
        let model = newProvider()
        _ = model.addVariable()
        let index = model.addVariable()
        model.setVariableName("feature flag", at: index)
        XCTAssertEqual(model.presentation.environmentRows.map(\.name), ["", "FEATURE_FLAG"])
        XCTAssertEqual(model.result.secrets.environment.map(\.name), ["FEATURE_FLAG"])
    }
}

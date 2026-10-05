import AgentSDK
import Components
import DisplayModels
import XCTest

@testable import ccterm

/// What the account sheet shows, derived from its draft: when it can be
/// saved, the Base URL's error, the credential row, masking, variable
/// warnings, what a paste fills, and that saving waits for the launch command
/// to run.
@MainActor
final class AccountEditorViewModelTests: XCTestCase {
    private let probe = FakeProbe()
    private var check: LaunchCheckService!

    /// General's launch, known to work, as when the app has just started.
    override func setUp() async throws {
        check = LaunchCheckService(probe: probe.probe)
        _ = await check.check(CLIConfiguration())
    }

    private func newProvider(takenNames: [String] = []) -> AccountEditorViewModel {
        model(account: .newProvider(), takenNames: takenNames)
    }

    private func model(
        account: Account, secrets: AccountSecrets = AccountSecrets(), takenNames: [String] = []
    ) -> AccountEditorViewModel {
        let validation = LaunchCommandValidation(
            check: check, configuration: { LaunchEnvironment.resolve(command: $0, general: LaunchPreferences()) },
            text: account.command, debounce: .zero)
        return AccountEditorViewModel(
            mode: .newProvider, account: account, secrets: secrets, takenNames: takenNames,
            commandValidation: validation)
    }

    /// A draft that is complete but for its launch command.
    private func fill(_ model: AccountEditorViewModel) {
        model.setName("Relay")
        model.setBaseURL("https://relay.example.com")
        model.setCredential("sk-example")
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
        XCTAssertEqual(model.presentation.fields.authentication, .authToken)
        XCTAssertEqual(model.presentation.maskedCredential, "sk-••••••••7c1e")
        model.setAuthentication(.apiKey)
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
        let model = model(
            account: .newProvider(),
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

    func testSavingWaitsForTheCommandToRun() async {
        let model = newProvider()
        fill(model)
        XCTAssertTrue(model.presentation.canSave, "no command runs General's, which is known")
        let gate = probe.hold("relay-wrapper")

        model.setCommand("relay-wrapper")
        XCTAssertFalse(model.presentation.canSave, "the old answer isn't one for this command")
        await waitFor(model.$presentation) { !$0.canSave && $0.commandDetail == .checking }
        await gate.open()
        await waitFor(model.$presentation) { $0.canSave }
        XCTAssertEqual(
            model.presentation.commandDetail.text,
            String(localized: "Claude Code \(FakeProbe.version(of: nil).version)"))

        model.setCommand("")
        XCTAssertTrue(model.presentation.canSave, "General's launch is known")
    }

    func testACommandThatDoesNotRunBlocksSavingAndSaysWhy() async {
        probe.fail("missing", with: AgentSDKError.binaryNotFound)
        let model = newProvider()
        fill(model)
        model.setCommand("missing")
        await waitFor(model.$presentation) { $0.commandDetail.isError }
        XCTAssertFalse(model.presentation.canSave)
        XCTAssertEqual(model.presentation.commandDetail, .problem(String(localized: "Not found"), fallback: nil))
        model.setCommand("")
        XCTAssertEqual(
            model.presentation.commandDetail, .none, "General's launch is known, so its answer shows at once")
        XCTAssertTrue(model.presentation.canSave)
    }

    func testAPastedCommandIsCheckedToo() async {
        let model = newProvider()
        let gate = probe.hold("my-proxy")
        _ = model.paste("ANTHROPIC_BASE_URL=https://relay.example.com ANTHROPIC_AUTH_TOKEN=sk-1 my-proxy")
        XCTAssertFalse(model.presentation.canSave)
        await gate.open()
        await waitFor(model.$presentation) { $0.canSave }
        XCTAssertEqual(model.presentation.fields.command, "my-proxy")
    }

    func testAnAccountOpenedWithACommandStartsChecked() async {
        var account = Account.newProvider()
        account.command = "orange"
        let model = model(account: account)
        fill(model)
        XCTAssertFalse(model.presentation.canSave)
        await waitFor(model.$presentation) { $0.canSave }
    }

    func testAPastedNameStaysClearOfTheOthers() {
        let model = newProvider(takenNames: ["relay"])
        _ = model.paste(#"alias relay="ANTHROPIC_BASE_URL=https://relay.example.com ANTHROPIC_AUTH_TOKEN=sk-1 claude""#)
        XCTAssertEqual(model.presentation.fields.name, "relay 2")
    }

    func testSeveralProvidersFillTheSheetFromTheFirst() {
        let model = newProvider()
        let text = """
            alias a="A=1 claude"
            alias b="B=2 claude"
            """
        let single = newProvider().paste(#"alias a="A=1 claude""#)
        XCTAssertEqual(model.paste(text), String(localized: "\(single) from the first of \(2)"))
        XCTAssertEqual(model.presentation.fields.name, "a")
        XCTAssertEqual(model.presentation.environmentRows.map(\.name), ["A"])
        XCTAssertEqual(model.paste("nothing here"), String(localized: "Nothing to paste — expected KEY=value"))
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

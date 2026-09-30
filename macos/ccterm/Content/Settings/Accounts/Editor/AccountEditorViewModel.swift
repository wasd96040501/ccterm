import Combine
import Foundation

/// An account being edited in its sheet. Holds the draft — the account and
/// its secrets — and publishes what the sheet shows from it; the draft
/// leaves only as ``result``, when the sheet saves. Saving waits for the
/// account's launch command to run.
@MainActor
final class AccountEditorViewModel {
    let mode: AccountEditorMode
    @Published private(set) var presentation: AccountEditorPresentation
    /// What filling the draft from the `entry` it opened with did, to tell
    /// once the sheet is up.
    private(set) var openingNote: String?

    private var account: Account
    private var secrets: AccountSecrets
    private var fieldsRevision = 0
    private let takenNames: [String]
    private let commandValidation: LaunchCommandValidation
    private var command = CommandCheck(isValid: false, detail: .none)
    private var cancellables = Set<AnyCancellable>()

    /// What the command's check says, as the sheet needs it.
    private struct CommandCheck {
        var isValid: Bool
        var detail: ValidationDetail

        init(isValid: Bool, detail: ValidationDetail) {
            self.isValid = isValid
            self.detail = detail
        }

        /// `text`: the command the state is for; with none, General's launch
        /// runs and there is nothing to say.
        init(_ state: LaunchCommandValidation.State, text: String) {
            var isValid = false
            if case .valid = state { isValid = true }
            let blank = text.trimmingCharacters(in: .whitespaces).isEmpty
            self.init(isValid: isValid, detail: blank ? .none : state.detail(fallback: nil))
        }
    }

    /// `entry`: what to fill the draft from before the sheet appears.
    /// `takenNames`: the other providers' names, which a name filled from a
    /// paste stays clear of. `commandValidation`: checks the account's launch
    /// command as it is typed; it starts from the command `account` has.
    init(
        mode: AccountEditorMode, account: Account, secrets: AccountSecrets, entry: AccountPaste.Entry? = nil,
        takenNames: [String] = [],
        commandValidation: LaunchCommandValidation
    ) {
        self.mode = mode
        self.account = account
        self.secrets = secrets
        self.takenNames = takenNames
        self.commandValidation = commandValidation
        command = CommandCheck(commandValidation.state, text: account.command)
        presentation = Self.present(
            mode: mode, account: account, secrets: secrets, fieldsRevision: 0, command: command)
        // Answers arrive later, on the main actor; the state each carries is
        // for the text as it is when it does.
        commandValidation.$state
            .dropFirst()
            .sink { [weak self] state in
                guard let self else { return }
                command = CommandCheck(state, text: self.account.command)
                update { _, _ in }
            }
            .store(in: &cancellables)
        if let entry { openingNote = apply(entry) }
    }

    /// The draft as saved: rows without a name dropped.
    var result: (account: Account, secrets: AccountSecrets) {
        var saved = secrets
        saved.environment.removeAll { $0.name.isEmpty }
        return (account, saved)
    }

    /// The value a variable row edits — unmasked, unlike its display.
    func variableValue(at index: Int) -> String {
        secrets.environment.indices.contains(index) ? secrets.environment[index].value : ""
    }

    // MARK: - Edits

    func setName(_ name: String) { updateProvider { $0.name = name } }
    func setBaseURL(_ url: String) { updateProvider { $0.baseURL = url } }
    func setAuthentication(_ authentication: Account.Authentication) {
        updateProvider { $0.authentication = authentication }
    }
    func setCredential(_ credential: String) { update { $1.credential = credential } }
    func setModel(_ keyPath: WritableKeyPath<Account.Models, String>, to name: String) {
        updateProvider { $0.models[keyPath: keyPath] = name }
    }
    func setCommand(_ command: String) {
        update { account, _ in account.command = command }
        commandDidChange()
    }
    func setArguments(_ arguments: String) { update { account, _ in account.arguments = arguments } }

    func toggleVariable(at index: Int) {
        updateVariable(at: index) { $0.isEnabled.toggle() }
    }

    func setVariableName(_ name: String, at index: Int) {
        updateVariable(at: index) { $0.name = EnvironmentVariable.normalizedName(name) }
    }

    func setVariableValue(_ value: String, at index: Int) {
        updateVariable(at: index) { $0.value = value }
    }

    /// Appends an empty row and returns its index.
    func addVariable() -> Int {
        update { $1.environment.append(EnvironmentVariable(name: "", value: "")) }
        return secrets.environment.count - 1
    }

    func removeVariable(at index: Int) {
        guard secrets.environment.indices.contains(index) else { return }
        update { $1.environment.remove(at: index) }
    }

    /// Reads pasted text into the draft; returns what to tell the person.
    /// The sheet takes one provider: text with several is refused.
    func paste(_ text: String) -> String {
        let entries = AccountPaste.entries(text)
        guard let entry = entries.first else { return String(localized: "Nothing to paste — expected KEY=value") }
        let note = apply(entry)
        // A sheet holds one provider: several fill it from the first.
        return entries.count == 1 ? note : String(localized: "\(note) from the first of \(entries.count)")
    }

    /// Fills the draft from `entry`; returns what to tell the person. A name it
    /// sets is made unique among ``takenNames``.
    func apply(_ entry: AccountPaste.Entry) -> String {
        var result = AccountPaste.Result()
        let named = account.provider?.name
        fieldsRevision += 1
        update { account, secrets in
            result = entry.apply(to: &account, secrets: &secrets)
            if var provider = account.provider, provider.name != named {
                provider.name = Account.uniqueName(provider.name, among: takenNames)
                account.kind = .provider(provider)
            }
        }
        commandDidChange()
        return Self.summary(of: result)
    }

    // MARK: - Presentation

    private func update(_ change: (inout Account, inout AccountSecrets) -> Void) {
        change(&account, &secrets)
        presentation = Self.present(
            mode: mode, account: account, secrets: secrets, fieldsRevision: fieldsRevision, command: command)
    }

    /// The draft's command may have changed: hand it to the validation, and
    /// hold saving until the check for it says so. What the check said of the
    /// old one stays shown until the new one's answer.
    private func commandDidChange() {
        commandValidation.textDidChange(account.command)
        command.isValid = commandValidation.isValid
        update { _, _ in }
    }

    private func updateProvider(_ change: (inout Account.Provider) -> Void) {
        update { account, _ in
            guard var provider = account.provider else { return }
            change(&provider)
            account.kind = .provider(provider)
        }
    }

    private func updateVariable(at index: Int, _ change: (inout EnvironmentVariable) -> Void) {
        guard secrets.environment.indices.contains(index) else { return }
        update { change(&$1.environment[index]) }
    }

    private static func present(
        mode: AccountEditorMode, account: Account, secrets: AccountSecrets, fieldsRevision: Int,
        command: CommandCheck
    ) -> AccountEditorPresentation {
        let provider = account.provider
        var fields = AccountEditorPresentation.Fields(
            credential: secrets.credential, command: account.command, arguments: account.arguments)
        if let provider {
            fields.name = provider.name
            fields.baseURL = provider.baseURL
            fields.authentication = provider.authentication
            fields.model = provider.models.main
            fields.opus = provider.models.opus
            fields.sonnet = provider.models.sonnet
            fields.haiku = provider.models.haiku
            fields.fable = provider.models.fable
        }

        var baseURLError: String?
        if let provider, !provider.baseURL.isEmpty, !isValidURL(provider.baseURL) {
            baseURLError = String(localized: "Enter a URL that starts with http:// or https://.")
        }
        let canSave =
            provider.map {
                !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && isValidURL($0.baseURL)
                    && !secrets.credential.isEmpty
            } ?? true
        let canSaveCommand = command.isValid

        var details: AccountEditorPresentation.SubscriptionDetails?
        if case .subscription(let subscription) = mode {
            details = AccountEditorPresentation.SubscriptionDetails(
                email: subscription.email, organization: subscription.organization ?? "—",
                plan: subscription.planName.map { String(localized: "Claude \($0)") } ?? "—")
        }

        let authentication = provider?.authentication ?? .authToken
        return AccountEditorPresentation(
            canSave: canSave && canSaveCommand, baseURLError: baseURLError,
            credentialTitle: authentication == .apiKey ? String(localized: "API key") : String(localized: "Token"),
            maskedCredential: masked(secrets.credential), subscription: details, fields: fields,
            fieldsRevision: fieldsRevision, environmentRows: rows(secrets.environment), commandDetail: command.detail)
    }

    /// The Authentication menu: each way, and what it sends.
    static let authenticationOptions: [(authentication: Account.Authentication, title: String, detail: String)] = [
        (.authToken, String(localized: "Auth Token"), "Authorization: Bearer"),
        (.apiKey, String(localized: "API Key"), "x-api-key"),
    ]

    private static func rows(_ environment: [EnvironmentVariable]) -> [EnvironmentRow] {
        let names = environment.map(\.name)
        return environment.map { variable in
            let warning: String? =
                if let field = managedNames[variable.name] {
                    String(localized: "Overrides the \(field) field.")
                } else if variable.name == "CLAUDE_CONFIG_DIR" {
                    String(localized: "Overrides the Configuration Folder in General.")
                } else if !variable.name.isEmpty, names.filter({ $0 == variable.name }).count > 1 {
                    String(localized: "Defined more than once; the last one wins.")
                } else {
                    nil
                }
            return EnvironmentRow(
                isEnabled: variable.isEnabled, name: variable.name,
                displayValue: variable.isSecretLike ? masked(variable.value) : variable.value, warning: warning)
        }
    }

    /// A secret as `sk-••••••••7c1e`: its first three and last four.
    static func masked(_ secret: String) -> String {
        guard !secret.isEmpty else { return "" }
        guard secret.count > 8 else { return String(repeating: "•", count: secret.count) }
        return secret.prefix(3) + String(repeating: "•", count: 8) + secret.suffix(4)
    }

    // MARK: - Rules

    /// Variables the sheet sets from its own fields, by the field's name.
    static let managedNames: [String: String] = [
        "ANTHROPIC_BASE_URL": String(localized: "Base URL"),
        "ANTHROPIC_AUTH_TOKEN": String(localized: "Auth Token"),
        "ANTHROPIC_API_KEY": String(localized: "API Key"),
        "ANTHROPIC_MODEL": String(localized: "Default Model"),
        "ANTHROPIC_DEFAULT_OPUS_MODEL": String(localized: "Opus"),
        "ANTHROPIC_DEFAULT_SONNET_MODEL": String(localized: "Sonnet"),
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": String(localized: "Haiku"),
        "ANTHROPIC_DEFAULT_FABLE_MODEL": String(localized: "Fable"),
    ]

    static func isValidURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), url.host() != nil else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    /// “Filled Base URL, token, and 3 variables”.
    private static func summary(of result: AccountPaste.Result) -> String {
        var items = result.fields.map(name(of:))
        if result.variableCount > 0 { items.append(String(localized: "\(result.variableCount) variables")) }
        let list = items.formatted(.list(type: .and))
        return String(localized: "Filled \(list)")
    }

    private static func name(of field: AccountPaste.Field) -> String {
        switch field {
        case .name: String(localized: "name")
        case .baseURL: String(localized: "Base URL")
        case .credential(.authToken): String(localized: "token")
        case .credential(.apiKey): String(localized: "API key")
        case .model: String(localized: "default model")
        case .opus: String(localized: "Opus")
        case .sonnet: String(localized: "Sonnet")
        case .haiku: String(localized: "Haiku")
        case .fable: String(localized: "Fable")
        case .command: String(localized: "command")
        case .arguments: String(localized: "arguments")
        }
    }
}

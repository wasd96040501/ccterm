import Combine
import Foundation

/// An account being edited in its sheet. Holds the draft — the account and
/// its secrets — and publishes what the sheet shows from it; the draft
/// leaves only as ``result``, when the sheet saves.
@MainActor
final class AccountEditorViewModel {
    let mode: AccountEditorMode
    @Published private(set) var presentation: AccountEditorPresentation

    private var account: Account
    private var secrets: AccountSecrets
    private var fieldsRevision = 0

    init(mode: AccountEditorMode, account: Account, secrets: AccountSecrets) {
        self.mode = mode
        self.account = account
        self.secrets = secrets
        presentation = Self.present(mode: mode, account: account, secrets: secrets, fieldsRevision: 0)
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
    func setCommand(_ command: String) { update { account, _ in account.command = command } }
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
    func paste(_ text: String) -> String {
        guard let paste = AccountPaste(text) else { return String(localized: "Nothing to paste — expected KEY=value") }
        var result = AccountPaste.Result()
        fieldsRevision += 1
        update { account, secrets in result = paste.apply(to: &account, secrets: &secrets) }
        return Self.summary(of: result)
    }

    // MARK: - Presentation

    private func update(_ change: (inout Account, inout AccountSecrets) -> Void) {
        change(&account, &secrets)
        presentation = Self.present(mode: mode, account: account, secrets: secrets, fieldsRevision: fieldsRevision)
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
        mode: AccountEditorMode, account: Account, secrets: AccountSecrets, fieldsRevision: Int
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
        }

        let title: String
        let subtitle: String
        switch mode {
        case .subscription(let subscription):
            title = subscription.email
            subtitle = String(localized: "Claude \(subscription.planName ?? "") subscription")
        case .newProvider, .provider:
            let name = provider?.name.trimmingCharacters(in: .whitespaces) ?? ""
            title = name.isEmpty ? String(localized: "New Provider") : name
            subtitle =
                mode == .newProvider
                ? String(localized: "API provider") : provider?.baseURLHost ?? String(localized: "No base URL")
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

        var details: AccountEditorPresentation.SubscriptionDetails?
        if case .subscription(let subscription) = mode {
            details = AccountEditorPresentation.SubscriptionDetails(
                email: subscription.email, organization: subscription.organization ?? "—",
                plan: subscription.planName.map { String(localized: "Claude \($0)") } ?? "—",
                signInMethod: subscription.method.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "—")
        }

        let authentication = provider?.authentication ?? .authToken
        return AccountEditorPresentation(
            title: title, subtitle: subtitle, canSave: canSave, baseURLError: baseURLError,
            credentialTitle: authentication == .apiKey ? String(localized: "API key") : String(localized: "Token"),
            credentialVariable: authentication.variable, maskedCredential: masked(secrets.credential),
            subscription: details, fields: fields, fieldsRevision: fieldsRevision,
            environmentRows: rows(secrets.environment))
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
        "ANTHROPIC_MODEL": String(localized: "Model"),
        "ANTHROPIC_DEFAULT_OPUS_MODEL": String(localized: "Opus"),
        "ANTHROPIC_DEFAULT_SONNET_MODEL": String(localized: "Sonnet"),
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": String(localized: "Haiku"),
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
        case .model: String(localized: "model")
        case .opus: String(localized: "Opus")
        case .sonnet: String(localized: "Sonnet")
        case .haiku: String(localized: "Haiku")
        case .command: String(localized: "command")
        case .arguments: String(localized: "arguments")
        }
    }
}

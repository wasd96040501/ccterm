import Foundation

/// Text pasted into an account's variable list, read the way people keep
/// provider settings: `KEY=value` lines, `export KEY=value` lines, or a whole
/// `alias name="KEY=value … claude --flags"`.
nonisolated struct AccountPaste: Equatable {
    /// The alias's name, when the text was one.
    var aliasName: String?
    var variables: [(name: String, value: String)]
    /// The word after the variables — the command they prefix — if any.
    var command: String?
    /// What follows the command.
    var arguments: String?

    /// `nil` when the text sets no variable.
    init?(_ text: String) {
        let alias = text.firstMatch(of: #/^\s*alias\s+([\w-]+)=(["'])([\s\S]*)\2\s*$/#)
        let source = alias.map { String($0.output.3) } ?? text
        aliasName = alias.map { String($0.output.1) }

        let assignment = #/(?:^|\s)(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=("([^"]*)"|'([^']*)'|(\S*))/#
        variables = []
        var end = source.startIndex
        for match in source.matches(of: assignment) {
            let value = match.output.3 ?? match.output.4 ?? match.output.5 ?? ""
            variables.append((String(match.output.1), String(value)))
            end = match.range.upperBound
        }
        guard !variables.isEmpty else { return nil }

        let rest = source[end...].trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = rest.firstMatch(of: #/^(\S+)\s*([\s\S]*)$/#) {
            command = String(first.output.1)
            let arguments = String(first.output.2)
            self.arguments = arguments.isEmpty ? nil : arguments
        }
    }

    static func == (lhs: AccountPaste, rhs: AccountPaste) -> Bool {
        lhs.aliasName == rhs.aliasName && lhs.command == rhs.command && lhs.arguments == rhs.arguments
            && lhs.variables.map(\.name) == rhs.variables.map(\.name)
            && lhs.variables.map(\.value) == rhs.variables.map(\.value)
    }

    /// What applying a paste changed.
    struct Result: Equatable {
        /// The account's own fields that were filled, in the order they were.
        var fields: [Field] = []
        /// How many variables were added or updated in the list.
        var variableCount = 0
    }

    enum Field: Equatable {
        case name, baseURL
        case credential(Account.Authentication)
        case model, opus, sonnet, haiku, command, arguments
    }

    /// Fills `account` and `secrets` from the paste: variables the account has
    /// fields for (a provider's base URL, credential and models) go there, the
    /// rest into the list — replacing a variable of the same name. A command
    /// other than `claude` becomes the account's command.
    func apply(to account: inout Account, secrets: inout AccountSecrets) -> Result {
        var result = Result()
        var provider = account.provider
        func fill(_ field: Field) { if !result.fields.contains(field) { result.fields.append(field) } }

        for (name, value) in variables {
            switch (name, provider != nil) {
            case ("ANTHROPIC_BASE_URL", true):
                provider?.baseURL = value
                fill(.baseURL)
            case ("ANTHROPIC_AUTH_TOKEN", true), ("ANTHROPIC_API_KEY", true):
                let authentication: Account.Authentication = name == "ANTHROPIC_API_KEY" ? .apiKey : .authToken
                provider?.authentication = authentication
                secrets.credential = value
                fill(.credential(authentication))
            case ("ANTHROPIC_MODEL", true):
                provider?.models.main = value
                fill(.model)
            case ("ANTHROPIC_DEFAULT_OPUS_MODEL", true):
                provider?.models.opus = value
                fill(.opus)
            case ("ANTHROPIC_DEFAULT_SONNET_MODEL", true):
                provider?.models.sonnet = value
                fill(.sonnet)
            case ("ANTHROPIC_DEFAULT_HAIKU_MODEL", true):
                provider?.models.haiku = value
                fill(.haiku)
            default:
                if let index = secrets.environment.firstIndex(where: { $0.name == name }) {
                    secrets.environment[index].value = value
                } else {
                    secrets.environment.append(EnvironmentVariable(name: name, value: value))
                }
                result.variableCount += 1
            }
        }
        if let command, command != "claude" {
            account.command = command
            fill(.command)
        }
        if let arguments {
            account.arguments = arguments
            fill(.arguments)
        }
        if var named = provider, named.name.trimmingCharacters(in: .whitespaces).isEmpty {
            if let aliasName {
                named.name = aliasName
                fill(.name)
            } else if let host = URL(string: named.baseURL)?.host() {
                named.name = ["127.0.0.1", "localhost"].contains(host) ? String(localized: "Local Proxy") : host
            }
            provider = named
        }
        if let provider { account.kind = .provider(provider) }
        return result
    }
}

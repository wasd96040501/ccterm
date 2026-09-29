import AgentSDK
import Foundation

/// Text pasted to make providers, read the way people keep them in a shell
/// profile: `KEY=value` lines, `export KEY=value` lines, a launch line
/// (`KEY=value … claude --flags`) or `alias name="KEY=value … claude --flags"`.
/// A whole `~/.zshrc` can be pasted; what isn't a provider's settings is
/// skipped.
nonisolated enum AccountPaste {
    /// One provider's worth of a paste.
    struct Entry: Equatable {
        /// The alias's name, when the entry was one.
        var name: String?
        var variables: [Assignment]
        /// The word after the variables — the command they prefix — if any.
        var command: String?
        /// What follows the command.
        var arguments: String?

        init(name: String? = nil, variables: [Assignment], command: String? = nil, arguments: String? = nil) {
            self.name = name
            self.variables = variables
            self.command = command
            self.arguments = arguments
        }

        init(name: String? = nil, _ line: LaunchLine) {
            self.init(
                name: name, variables: line.variables.map { Assignment(name: $0.name, value: $0.value) },
                command: line.command, arguments: line.arguments)
        }
    }

    struct Assignment: Equatable {
        var name: String
        var value: String
    }

    /// The entries in `text`, in order:
    /// - each `alias name="…"` (or `'…'`) whose body sets a variable, named by
    ///   the alias;
    /// - each line that sets variables in front of a command;
    /// - each run of bare `KEY=value` / `export KEY=value` lines, ended by a
    ///   blank line or by a command line, which joins it (a command line
    ///   without variables joins only when it runs `claude`).
    ///
    /// Comments (`#…`) and lines that set no variable are skipped.
    static func entries(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var run: [Assignment] = []
        func endRun() {
            if !run.isEmpty { entries.append(Entry(variables: run)) }
            run = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                endRun()
                continue
            }
            if line.hasPrefix("#") { continue }
            if let alias = line.firstMatch(of: #/^alias\s+([\w-]+)=(["'])([\s\S]*)\2$/#) {
                endRun()
                if let launch = LaunchLine(String(alias.output.3)), !launch.variables.isEmpty {
                    entries.append(Entry(name: String(alias.output.1), launch))
                }
                continue
            }
            guard let launch = LaunchLine(line) else { continue }
            if launch.command == nil {
                run += Entry(launch).variables
            } else if !launch.variables.isEmpty || isClaude(launch.command) {
                var entry = Entry(launch)
                entry.variables.insert(contentsOf: run, at: 0)
                run = []
                if !entry.variables.isEmpty { entries.append(entry) }
            } else {
                endRun()
            }
        }
        endRun()
        return entries
    }

    private static func isClaude(_ command: String?) -> Bool {
        command.map { ($0 as NSString).lastPathComponent == "claude" } ?? false
    }

    /// The providers `entries` make, ready to add: each with its name made
    /// unique among `existingNames` and those before it. Entries without a
    /// base URL or a credential are left out and counted.
    static func importable(
        _ entries: [Entry], existingNames: [String]
    ) -> (
        providers: [(Account, AccountSecrets)], skipped: Int
    ) {
        var names = existingNames
        var providers: [(Account, AccountSecrets)] = []
        for entry in entries {
            var (account, secrets) = entry.newProvider()
            guard var provider = account.provider, !provider.baseURL.isEmpty, !secrets.credential.isEmpty else {
                continue
            }
            provider.name = Account.uniqueName(provider.name, among: names)
            names.append(provider.name)
            account.kind = .provider(provider)
            providers.append((account, secrets))
        }
        return (providers, entries.count - providers.count)
    }

    /// What applying an entry changed.
    struct Result: Equatable {
        /// The account's own fields that were filled, in the order they were.
        var fields: [Field] = []
        /// How many variables were added or updated in the list.
        var variableCount = 0
    }

    enum Field: Equatable {
        case name, baseURL
        case credential(Account.Authentication)
        case model, opus, sonnet, haiku, fable, command, arguments
    }
}

extension AccountPaste.Entry {
    /// A new provider filled from the entry.
    func newProvider() -> (Account, AccountSecrets) {
        var account = Account.newProvider()
        var secrets = AccountSecrets()
        _ = apply(to: &account, secrets: &secrets)
        return (account, secrets)
    }

    /// Fills `account` and `secrets` from the entry: variables the account has
    /// fields for (a provider's base URL, credential and models) go there, the
    /// rest into the list — replacing a variable of the same name. A command
    /// other than `claude` becomes the account's command.
    func apply(to account: inout Account, secrets: inout AccountSecrets) -> AccountPaste.Result {
        var result = AccountPaste.Result()
        var provider = account.provider
        func fill(_ field: AccountPaste.Field) { if !result.fields.contains(field) { result.fields.append(field) } }

        for (name, value) in variables.map({ ($0.name, $0.value) }) {
            switch (name, provider != nil) {
            case ("ANTHROPIC_BASE_URL", true):
                provider?.baseURL = value
                fill(.baseURL)
            case ("ANTHROPIC_AUTH_TOKEN", true), ("ANTHROPIC_API_KEY", true):
                let authentication: Account.Authentication =
                    name == Account.Authentication.apiKey.variable ? .apiKey : .authToken
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
            case ("ANTHROPIC_DEFAULT_FABLE_MODEL", true):
                provider?.models.fable = value
                fill(.fable)
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
            if let name {
                named.name = name
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

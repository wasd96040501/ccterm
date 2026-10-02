import AgentSDK
import Foundation

extension LaunchEnvironment {
    /// How the CLI is launched for `account` under General's `general`: its
    /// command, and the environment the account makes — for a provider the base
    /// URL, the credential (under the variable its authentication names), the
    /// main model (`ANTHROPIC_MODEL`) and each family's alias
    /// (`ANTHROPIC_DEFAULT_<FAMILY>_MODEL`), empty ones left out — then the
    /// account's own enabled variables, which win. The account's arguments
    /// follow the command as typed at a shell prompt (`claude` when it has no
    /// command). The account is read from the environment at launch; nothing
    /// in the control protocol changes it.
    static func resolve(account: Account, secrets: AccountSecrets, general: LaunchPreferences) -> CLIConfiguration {
        var configuration = resolve(command: account.command, general: general)
        if let provider = account.provider {
            let values: [(String, String)] = [
                ("ANTHROPIC_BASE_URL", provider.baseURL),
                (provider.authentication.variable, secrets.credential),
                ("ANTHROPIC_MODEL", provider.models.main),
                ("ANTHROPIC_DEFAULT_OPUS_MODEL", provider.models.opus),
                ("ANTHROPIC_DEFAULT_SONNET_MODEL", provider.models.sonnet),
                ("ANTHROPIC_DEFAULT_HAIKU_MODEL", provider.models.haiku),
                ("ANTHROPIC_DEFAULT_FABLE_MODEL", provider.models.fable),
            ]
            for (name, value) in values {
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { configuration.env[name] = trimmed }
            }
        }
        for variable in secrets.environment where variable.isEnabled {
            let name = EnvironmentVariable.normalizedName(variable.name)
            if !name.isEmpty { configuration.env[name] = variable.value }
        }
        let arguments = account.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if !arguments.isEmpty {
            configuration.customCommand = "\(configuration.customCommand ?? "claude") \(arguments)"
        }
        return configuration
    }
}

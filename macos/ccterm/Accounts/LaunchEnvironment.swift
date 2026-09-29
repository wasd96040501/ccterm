import AgentSDK
import Foundation

/// The rule that turns settings into a launch: which command starts the CLI
/// and which environment it gets.
nonisolated enum LaunchEnvironment {
    /// How the CLI is launched for an account whose own command is `command`
    /// (empty when it has none), under General's `general`.
    ///
    /// The command is the account's if it has one, else General's, else none —
    /// the `claude` found on this Mac. It is passed as written: the
    /// assignments in front of it are the SDK's to apply. General's
    /// configuration folder becomes `CLAUDE_CONFIG_DIR`, `~` expanded.
    static func resolve(command: String, general: LaunchPreferences) -> CLIConfiguration {
        let custom = [command, general.command]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        var env: [String: String] = [:]
        let folder = general.configDirectory.trimmingCharacters(in: .whitespaces)
        if !folder.isEmpty { env["CLAUDE_CONFIG_DIR"] = (folder as NSString).expandingTildeInPath }
        return CLIConfiguration(customCommand: custom, env: env)
    }
}

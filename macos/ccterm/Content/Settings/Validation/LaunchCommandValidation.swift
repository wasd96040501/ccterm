import AgentSDK
import Foundation

/// A launch command being typed — in General, or in an account's sheet —
/// checked by running it with `--version`. Its ``TextValidation/State`` holds
/// the version it printed or why it didn't.
typealias LaunchCommandValidation = TextValidation<CLIVersion>

extension TextValidation where Valid == CLIVersion {
    /// `configuration`: the launch a command text stands for — the account's
    /// or General's, under the current preferences. `text`: the command the
    /// field starts with.
    convenience init(
        check service: LaunchCheckService, configuration: @escaping (String) -> CLIConfiguration, text: String = "",
        debounce: Duration = .milliseconds(500)
    ) {
        self.init(
            text: text, debounce: debounce,
            cached: { service.cached(configuration($0)).map(Self.state(of:)) },
            check: { Self.state(of: await service.check(configuration($0))) })
    }

    private static func state(of check: LaunchCheck) -> State {
        switch check {
        case .valid(let version): .valid(version)
        case .invalid(let message): .invalid(message)
        }
    }
}

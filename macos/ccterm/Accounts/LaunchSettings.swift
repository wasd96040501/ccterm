import Foundation

/// How the CLI is started when an account doesn't say: the launch command set
/// in General, kept in the defaults, and the rule that picks between it and
/// an account's own. Callable from any thread — `UserDefaults` is
/// thread-safe, and ``SubscriptionAuth`` reads it off the main actor.
nonisolated final class LaunchSettings: @unchecked Sendable {
    /// The key the launch command has always been kept under.
    private static let commandKey = "customCLICommand"

    private let defaults: UserDefaults
    private let locate: @Sendable () -> String?

    /// `locate`: where `claude` is on this Mac. Blocking.
    init(defaults: UserDefaults, locate: @escaping @Sendable () -> String?) {
        self.defaults = defaults
        self.locate = locate
    }

    /// The launch command set in General; empty runs `claude`.
    var command: String {
        get { defaults.string(forKey: Self.commandKey) ?? "" }
        set {
            let command = newValue.trimmingCharacters(in: .whitespaces)
            if command.isEmpty {
                defaults.removeObject(forKey: Self.commandKey)
            } else {
                defaults.set(command, forKey: Self.commandKey)
            }
        }
    }

    /// The command that starts the CLI for `account`: the account's own, else
    /// the one set in General; `nil` runs the `claude` found on this Mac.
    func command(for account: Account?) -> String? {
        for command in [account?.command ?? "", command] {
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Where `claude` is when no command is set. Blocking — call it off the
    /// main actor.
    func locateCLI() -> String? {
        locate()
    }
}

import AgentSDK
import Combine
import Foundation

/// How the CLI is launched, in one place: General's settings, kept in the
/// defaults, and what they and the accounts make of them. Everything that
/// starts or reads the CLI subscribes here; only Settings writes.
///
/// Every published value is set on the main actor, so a subscriber's first
/// value — the current one — arrives synchronously.
@MainActor
final class LaunchStore {
    /// The keys the settings have always been kept under.
    private static let commandKey = "customCLICommand"
    private static let configDirectoryKey = "claudeConfigDirectory"

    /// What General says.
    @Published private(set) var preferences: LaunchPreferences
    /// The launch General describes: what the session list follows and what
    /// General checks.
    @Published private(set) var general: CLIConfiguration
    /// The launch of the subscription's sessions: its own command, else General's.
    @Published private(set) var subscription: CLIConfiguration
    /// The directory the CLI launched as ``general`` writes sessions to. The
    /// first value comes at once — General's folder, else this process's
    /// `CLAUDE_CONFIG_DIR`, else `~/.claude` — and is replaced by what a login
    /// shell says, now and each time ``general`` changes, when that differs.
    @Published private(set) var sessionDirectory: SessionDirectory

    private let defaults: UserDefaults
    private let resolveDirectory: @Sendable (CLIConfiguration) -> SessionDirectory
    private var subscriptionCommand = ""
    private var accountsSubscription: AnyCancellable?
    /// Counts resolutions asked for; only the last one's answer is kept.
    private var resolution = 0

    /// `accounts`: the account list, whose subscription entry may carry its own
    /// command; must deliver on the main actor. `resolveDirectory`: where a
    /// launch writes sessions — blocking, run off the main actor.
    init(
        defaults: UserDefaults, accounts: AnyPublisher<[Account], Never>,
        resolveDirectory: @escaping @Sendable (CLIConfiguration) -> SessionDirectory = {
            SessionDirectory(configuration: $0)
        }
    ) {
        self.defaults = defaults
        self.resolveDirectory = resolveDirectory
        let preferences = LaunchPreferences(
            command: defaults.string(forKey: Self.commandKey) ?? "",
            configDirectory: defaults.string(forKey: Self.configDirectoryKey) ?? "")
        self.preferences = preferences
        let general = LaunchEnvironment.resolve(command: "", general: preferences)
        self.general = general
        subscription = general
        sessionDirectory = Self.immediateDirectory(for: preferences)
        accountsSubscription = accounts.sink { [weak self] accounts in
            MainActor.assumeIsolated { self?.accountsDidChange(accounts) }
        }
        resolveSessionDirectory(for: general)
    }

    /// Sets General's launch command; empty runs `claude`. Nothing is checked
    /// here — see ``LaunchCheckService``.
    func setCommand(_ command: String) {
        var next = preferences
        next.command = command.trimmingCharacters(in: .whitespaces)
        update(next)
    }

    /// Sets General's configuration folder (`CLAUDE_CONFIG_DIR`); empty leaves
    /// the CLI's default. Nothing is checked here — see
    /// ``LaunchPreferences/folderProblem(_:)``.
    func setConfigDirectory(_ path: String) {
        var next = preferences
        next.configDirectory = path.trimmingCharacters(in: .whitespaces)
        update(next)
    }

    private func update(_ next: LaunchPreferences) {
        guard next != preferences else { return }
        preferences = next
        for (value, key) in [(next.command, Self.commandKey), (next.configDirectory, Self.configDirectoryKey)] {
            if value.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
        }
        publishConfigurations()
    }

    private func accountsDidChange(_ accounts: [Account]) {
        let command = accounts.first { $0.kind == .subscription }?.command ?? ""
        guard command != subscriptionCommand else { return }
        subscriptionCommand = command
        publishConfigurations()
    }

    /// Sets ``general`` and ``subscription`` to what the settings make of
    /// them now, each only when it differs.
    private func publishConfigurations() {
        let general = LaunchEnvironment.resolve(command: "", general: preferences)
        let subscription = LaunchEnvironment.resolve(command: subscriptionCommand, general: preferences)
        if subscription != self.subscription { self.subscription = subscription }
        guard general != self.general else { return }
        self.general = general
        resolveSessionDirectory(for: general)
    }

    private func resolveSessionDirectory(for configuration: CLIConfiguration) {
        resolution += 1
        let current = resolution
        let resolve = resolveDirectory
        Task { [weak self] in
            let directory = await Task.detached { resolve(configuration) }.value
            guard let self, current == resolution, directory != sessionDirectory else { return }
            appLog(.info, "LaunchStore", "sessions are in \(directory.url.path)")
            sessionDirectory = directory
        }
    }

    /// Where sessions are without asking a shell: General's folder, else this
    /// process's `CLAUDE_CONFIG_DIR`, else `~/.claude`.
    private static func immediateDirectory(for preferences: LaunchPreferences) -> SessionDirectory {
        var environment = ProcessInfo.processInfo.environment
        if let folder = LaunchEnvironment.resolve(command: "", general: preferences).env["CLAUDE_CONFIG_DIR"] {
            environment["CLAUDE_CONFIG_DIR"] = folder
        }
        return SessionDirectory(environment: environment)
    }
}

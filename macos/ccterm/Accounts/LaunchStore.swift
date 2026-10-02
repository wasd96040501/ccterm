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
    private static let allowsBypassKey = "allowsBypassPermissions"

    /// What General says.
    @Published private(set) var preferences: LaunchPreferences
    /// The launch General describes: what the session list follows and what
    /// General checks. Its consumers are General's check today and live
    /// sessions when they are wired.
    @Published private(set) var general: CLIConfiguration
    /// The launch of the subscription's sessions: its own command, else General's.
    @Published private(set) var subscription: CLIConfiguration
    /// The directory the CLI launched as ``general`` writes sessions to. The
    /// first value comes at once — General's folder, else this process's
    /// `CLAUDE_CONFIG_DIR`, else `~/.claude` — and is replaced by what a login
    /// shell says, now and each time ``general`` changes, when that differs.
    /// A change of General's folder moves it at once, before the shell answers.
    @Published private(set) var sessionDirectory: SessionDirectory

    private let defaults: UserDefaults
    private let resolveDirectory: @Sendable (CLIConfiguration) -> SessionDirectory
    /// Where sessions are without asking a shell, for the current folder; a
    /// change of it moves ``sessionDirectory`` at once.
    private var immediateDirectory: SessionDirectory
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
            configDirectory: defaults.string(forKey: Self.configDirectoryKey) ?? "",
            allowsBypassPermissions: defaults.bool(forKey: Self.allowsBypassKey))
        self.preferences = preferences
        let general = LaunchEnvironment.resolve(command: "", general: preferences)
        self.general = general
        subscription = general
        immediateDirectory = Self.immediateDirectory(for: preferences)
        sessionDirectory = immediateDirectory
        accountsSubscription = accounts.sink { [weak self] accounts in
            MainActor.assumeIsolated { self?.accountsDidChange(accounts) }
        }
        resolveSessionDirectory(for: general)
    }

    /// The launch General would describe if its command were `command`, under
    /// the current configuration folder: what a check of General's field text
    /// runs.
    func configuration(generalCommand command: String) -> CLIConfiguration {
        var preferences = preferences
        preferences.command = command
        return LaunchEnvironment.resolve(command: "", general: preferences)
    }

    /// The launch of an account whose own command is `command` (empty when it
    /// has none), under the current General settings: what a check of an
    /// account's field text runs.
    func configuration(accountCommand command: String) -> CLIConfiguration {
        LaunchEnvironment.resolve(command: command, general: preferences)
    }

    /// How a session on `account` is launched under the current General
    /// settings: its command, and — for a provider — the base URL, the
    /// credential and the model names as the environment the CLI reads
    /// (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY`,
    /// `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_<FAMILY>_MODEL`) plus its own
    /// variables. The account is read from the CLI's environment at launch;
    /// nothing in the control protocol changes it.
    func configuration(for account: Account, secrets: AccountSecrets) -> CLIConfiguration {
        LaunchEnvironment.resolve(account: account, secrets: secrets, general: preferences)
    }

    /// Sets General's *Allow Bypass Permissions*. Sessions already running keep
    /// how they were launched.
    func setAllowsBypassPermissions(_ allows: Bool) {
        var next = preferences
        next.allowsBypassPermissions = allows
        update(next)
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
        defaults.set(next.allowsBypassPermissions, forKey: Self.allowsBypassKey)
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
        let immediate = Self.immediateDirectory(for: preferences)
        if immediate != immediateDirectory {
            immediateDirectory = immediate
            if immediate != sessionDirectory { sessionDirectory = immediate }
        }
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

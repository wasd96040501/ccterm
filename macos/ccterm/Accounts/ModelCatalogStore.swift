import AgentSDK
import Combine
import Foundation

/// The catalog of what every account's CLI offers, for the composer's menus
/// before any session runs (design 08 *Where the menus get models*).
///
/// Read from a short-lived CLI per account — started at app start and again
/// whenever an account's launch changes (Settings' command or config folder,
/// a provider's URL or models) — which answers `initialize` and is ended; the
/// CLI writes no transcript until a first prompt, so this leaves nothing in
/// the sidebar. Each answer is cached on disk, so a launch shows the last one
/// at once and a New tab never waits; only the very first launch shows
/// *Loading…* for the second it takes.
///
/// A probe is made when the launch an account resolves to differs from the
/// one last probed — so the same account list delivered twice, or a change to
/// an account's name, costs no CLI. A probe that fails keeps what was known
/// (the cache, or nothing: *Loading…*) and is tried again on the next change.
///
/// `catalog` is set on the main actor only: a subscriber's first value — the
/// current one — arrives synchronously.
@MainActor
final class ModelCatalogStore {
    /// Every account's section, in Settings' order.
    @Published private(set) var catalog = ModelCatalog()

    private let configuration: @MainActor (Account) async throws -> CLIConfiguration
    private let probe: @Sendable (CLIConfiguration) async throws -> InitializationResult
    private let cacheURL: URL
    private var subscription: AnyCancellable?
    private var accounts: [Account] = []
    /// What each account's CLI last answered — from the cache until a probe lands.
    private var entries: [UUID: AccountCatalog]
    /// The launch each account was last probed with (or is being).
    private var probed: [UUID: CLIConfiguration] = [:]
    /// Counts the probes started per account: what an earlier one answers
    /// never lands.
    private var probeCount: [UUID: Int] = [:]
    /// The last cache write; the next one waits for it.
    private var lastWrite: Task<Void, Never>?

    /// `accounts`: the account list, delivered on the main actor.
    /// `configuration`: how a probe of an account is launched (its secrets read
    /// from the keychain). `probe`: launches that CLI, returns its
    /// `initialize`, ends it — injected so tests answer without a process.
    /// `cacheURL`: the JSON file the last answers are kept in.
    init(
        accounts: AnyPublisher<[Account], Never>,
        configuration: @escaping @MainActor (Account) async throws -> CLIConfiguration,
        probe: @escaping @Sendable (CLIConfiguration) async throws -> InitializationResult,
        cacheURL: URL
    ) {
        self.configuration = configuration
        self.probe = probe
        self.cacheURL = cacheURL
        entries = Self.readCache(cacheURL)
        subscription = accounts.sink { [weak self] accounts in
            MainActor.assumeIsolated { self?.accountsDidChange(accounts) }
        }
    }

    private func accountsDidChange(_ accounts: [Account]) {
        self.accounts = accounts
        let ids = Set(accounts.map(\.id))
        for id in entries.keys where !ids.contains(id) { entries[id] = nil }
        for id in probed.keys where !ids.contains(id) {
            probed[id] = nil
            probeCount[id] = nil
        }
        publish()
        for account in accounts { refresh(account) }
    }

    private func refresh(_ account: Account) {
        Task { [weak self, configuration] in
            let launch: CLIConfiguration
            do { launch = try await configuration(account) } catch {
                appLog(.warning, "ModelCatalogStore", "no launch for an account — \(error.localizedDescription)")
                return
            }
            guard let self, accounts.contains(where: { $0.id == account.id }), probed[account.id] != launch else {
                return
            }
            probed[account.id] = launch
            let count = (probeCount[account.id] ?? 0) + 1
            probeCount[account.id] = count
            do {
                let result = try await probe(launch)
                guard probeCount[account.id] == count, let current = accounts.first(where: { $0.id == account.id })
                else { return }
                entries[account.id] = AccountCatalog(account: current, result: result)
                publish()
                writeCache()
            } catch {
                if probeCount[account.id] == count { probed[account.id] = nil }
                appLog(.warning, "ModelCatalogStore", "a model probe failed — \(error.localizedDescription)")
            }
        }
    }

    private func publish() {
        let next = ModelCatalog(
            accounts: accounts.map { account in
                guard var entry = entries[account.id] else { return AccountCatalog(account: account) }
                // What Settings says about a provider wins over what was cached.
                if let provider = account.provider {
                    entry.name = AccountCatalog.name(of: provider)
                    entry.detail = provider.baseURLHost ?? ""
                }
                return entry
            })
        if next != catalog { catalog = next }
    }

    // MARK: - The disk cache

    private func writeCache() {
        let snapshot = accounts.compactMap { entries[$0.id] }.map(CachedAccount.init)
        let url = cacheURL
        let previous = lastWrite
        lastWrite = Task.detached {
            await previous?.value
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(CachedCatalog(accounts: snapshot)).write(to: url, options: .atomic)
            } catch {
                appLog(.warning, "ModelCatalogStore", "the model cache was not written: \(error.localizedDescription)")
            }
        }
    }

    private static func readCache(_ url: URL) -> [UUID: AccountCatalog] {
        guard let data = try? Data(contentsOf: url),
            let cached = try? JSONDecoder().decode(CachedCatalog.self, from: data),
            cached.version == CachedCatalog.current
        else { return [:] }
        return Dictionary(cached.accounts.map { ($0.id, $0.catalog) }, uniquingKeysWith: { $1 })
    }
}

// MARK: - From an `initialize` answer

extension AccountCatalog {
    /// `account` before its CLI has answered: *Loading…* in its section.
    init(account: Account) {
        self.init(
            id: account.id, name: Self.name(of: account, subscriptionType: nil),
            detail: Self.detail(of: account), isSubscription: account.provider == nil, isLoaded: false, models: [],
            shownModelCount: 0, commands: [], fastModeUnavailableReason: nil, defaultPermissionMode: nil)
    }

    /// `account` as its CLI's `initialize` answered.
    ///
    /// **Which models fold into *N More Models*.** The CLI's own picker keeps
    /// a row per family under its alias (`opus`, `sonnet`, `haiku`, `fable`,
    /// each resolving to the family's latest) after *Default*, and lists the
    /// versioned ids of earlier models behind them (its catalog marks those
    /// `picker.section = "overflow"`, which `initialize` doesn't pass on — the
    /// rows arrive in the picker's order, aliases first). So on the
    /// subscription *Default* and every alias row are listed and the rows
    /// named by a versioned id fold, kept after the listed ones in the CLI's
    /// order. A provider's models are the few names Settings gives it: all
    /// listed. An account with no alias row lists everything.
    init(account: Account, result: InitializationResult) {
        let subscriptionType = result.account?.subscriptionType
        var models = result.models
        var shown = models.count
        if account.provider == nil {
            let isListed = { (model: InitializationResult.Model) in
                model.value == "default" || Self.isAlias(model.value)
            }
            if models.contains(where: { $0.value != "default" && Self.isAlias($0.value) }) {
                let listed = models.filter(isListed)
                models = listed + models.filter { !isListed($0) }
                shown = listed.count
            }
        }
        self.init(
            id: account.id, name: Self.name(of: account, subscriptionType: subscriptionType),
            detail: Self.detail(of: account), isSubscription: account.provider == nil, isLoaded: true, models: models,
            shownModelCount: shown, commands: result.commands,
            fastModeUnavailableReason: result.fastModeDisabledReason.flatMap(Self.words(forFastModeReason:)),
            defaultPermissionMode: result.currentPermissionMode)
    }

    /// A model named by an alias (`opus`, `sonnet[1m]`) rather than a versioned id.
    private static func isAlias(_ value: String) -> Bool {
        value.range(of: #"^[a-z]+(\[[^\]]*\])?$"#, options: .regularExpression) != nil
    }

    static func name(of provider: Account.Provider) -> String {
        provider.name.isEmpty ? (provider.baseURLHost ?? String(localized: "Provider")) : provider.name
    }

    private static func name(of account: Account, subscriptionType: String?) -> String {
        if let provider = account.provider { return name(of: provider) }
        guard let type = subscriptionType?.trimmingCharacters(in: .whitespaces), !type.isEmpty else {
            return String(localized: "Claude")
        }
        return String(localized: "Claude \(type.capitalized)")
    }

    private static func detail(of account: Account) -> String {
        account.provider.map { $0.baseURLHost ?? "" } ?? String(localized: "Subscription")
    }

    /// `fast_mode_disabled_reason` in words; `nil` for one that doesn't stop
    /// ccterm (it opts in to Fast Mode itself).
    static func words(forFastModeReason reason: String) -> String? {
        switch reason {
        case "sdk_opt_in_required": nil
        case "extra_usage_disabled": String(localized: "Requires extra usage")
        case "free": String(localized: "Requires a paid plan")
        case "preference": String(localized: "Turned off by your organization")
        case "network_error": String(localized: "Unavailable without a network connection")
        case "not_first_party": String(localized: "Only with the subscription")
        case "disabled_by_env": String(localized: "Turned off in the environment")
        case "model_not_allowed": String(localized: "Not allowed for this model")
        case "pending": String(localized: "Still being checked")
        default: String(localized: "Currently unavailable")
        }
    }
}

// MARK: - The cache's shape

/// `InitializationResult.Model` and `SlashCommand` only decode, so the cache
/// keeps its own records of them.
private struct CachedCatalog: Codable {
    static let current = 1
    var version = CachedCatalog.current
    var accounts: [CachedAccount]
}

private struct CachedAccount: Codable {
    struct Model: Codable {
        var value: String
        var displayName: String
        var description: String
        var supportsEffort: Bool
        var supportedEffortLevels: [String]
        var supportsAdaptiveThinking: Bool
        var supportsFastMode: Bool
        var supportsAutoMode: Bool
        var resolvedModel: String?
        var isDisabled: Bool
    }

    struct Command: Codable {
        var name: String
        var description: String
        var argumentHint: String
    }

    var id: UUID
    var name: String
    var detail: String
    var isSubscription: Bool
    var models: [Model]
    var shownModelCount: Int
    var commands: [Command]
    var fastModeUnavailableReason: String?
    var defaultPermissionMode: String?

    init(_ catalog: AccountCatalog) {
        id = catalog.id
        name = catalog.name
        detail = catalog.detail
        isSubscription = catalog.isSubscription
        models = catalog.models.map {
            Model(
                value: $0.value, displayName: $0.displayName, description: $0.description,
                supportsEffort: $0.supportsEffort, supportedEffortLevels: $0.supportedEffortLevels,
                supportsAdaptiveThinking: $0.supportsAdaptiveThinking, supportsFastMode: $0.supportsFastMode,
                supportsAutoMode: $0.supportsAutoMode, resolvedModel: $0.resolvedModel, isDisabled: $0.isDisabled)
        }
        shownModelCount = catalog.shownModelCount
        commands = catalog.commands.map {
            Command(name: $0.name, description: $0.description, argumentHint: $0.argumentHint)
        }
        fastModeUnavailableReason = catalog.fastModeUnavailableReason
        defaultPermissionMode = catalog.defaultPermissionMode?.rawValue
    }

    var catalog: AccountCatalog {
        AccountCatalog(
            id: id, name: name, detail: detail, isSubscription: isSubscription, isLoaded: true,
            models: models.map { cached in
                var model = InitializationResult.Model(
                    value: cached.value, displayName: cached.displayName, description: cached.description,
                    supportsEffort: cached.supportsEffort, supportedEffortLevels: cached.supportedEffortLevels,
                    supportsAdaptiveThinking: cached.supportsAdaptiveThinking,
                    supportsFastMode: cached.supportsFastMode,
                    supportsAutoMode: cached.supportsAutoMode)
                model.resolvedModel = cached.resolvedModel
                model.isDisabled = cached.isDisabled
                return model
            },
            shownModelCount: shownModelCount,
            // `SlashCommand` decodes from the CLI's own shape; its `init` is the SDK's.
            commands: commands.compactMap { command in
                let json: [String: String] = [
                    "name": command.name, "description": command.description, "argumentHint": command.argumentHint,
                ]
                return (try? JSONSerialization.data(withJSONObject: json)).flatMap {
                    try? JSONDecoder().decode(SlashCommand.self, from: $0)
                }
            },
            fastModeUnavailableReason: fastModeUnavailableReason,
            defaultPermissionMode: defaultPermissionMode.flatMap(PermissionMode.init(rawValue:)))
    }
}

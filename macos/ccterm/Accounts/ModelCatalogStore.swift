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
    /// Each account's probe in flight; a newer launch or the account's removal
    /// cancels it, and a cancelled probe never lands.
    private var probes: [UUID: Task<Void, Never>] = [:]
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
            probes.removeValue(forKey: id)?.cancel()
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
            probes[account.id]?.cancel()
            probes[account.id] = Task { [weak self, probe] in
                do {
                    let result = try await probe(launch)
                    guard let self, !Task.isCancelled,
                        let current = accounts.first(where: { $0.id == account.id })
                    else { return }
                    probes[account.id] = nil
                    entries[account.id] = AccountCatalog(account: current, result: result)
                    publish()
                    writeCache()
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    probes[account.id] = nil
                    probed[account.id] = nil
                    appLog(.warning, "ModelCatalogStore", "a model probe failed — \(error.localizedDescription)")
                }
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
        let snapshot = accounts.compactMap { entries[$0.id] }
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
        return Dictionary(cached.accounts.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }
}

// MARK: - From an `initialize` answer

extension AccountCatalog {
    /// `account` before its CLI has answered: *Loading…* in its section.
    init(account: Account) {
        self.init(
            id: account.id, name: Self.name(of: account, subscriptionType: nil),
            detail: Self.detail(of: account), isSubscription: account.provider == nil, isLoaded: false, models: [],
            commands: [], fastModeUnavailableReason: nil, defaultPermissionMode: nil)
    }

    /// `account` as its CLI's `initialize` answered.
    ///
    /// **The models' order.** The CLI's own picker keeps a row per family
    /// under its alias (`opus`, `sonnet`, `haiku`, `fable`, each resolving to
    /// the family's latest) after *Default*, and the versioned ids of earlier
    /// models behind them. So on the subscription *Default* and every alias
    /// come first and the versioned ids after them, each in the CLI's order.
    /// A provider's models are the few names Settings gives it, as given.
    init(account: Account, result: InitializationResult) {
        let subscriptionType = result.account?.subscriptionType
        var models = result.models
        if account.provider == nil {
            let isAliasRow = { (model: InitializationResult.Model) in
                model.value == "default" || Self.isAlias(model.value)
            }
            models = models.filter(isAliasRow) + models.filter { !isAliasRow($0) }
        }
        self.init(
            id: account.id, name: Self.name(of: account, subscriptionType: subscriptionType),
            detail: Self.detail(of: account), isSubscription: account.provider == nil, isLoaded: true, models: models,
            commands: result.commands,
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
        // The CLI says `max` or, from some versions, `Claude Max`: the plan is
        // named once either way.
        let plan = type.lowercased().hasPrefix("claude ") ? String(type.dropFirst(7)) : type
        return String(localized: "Claude \(plan.capitalized)")
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

/// The catalogs as the SDK and the app code them; a file of another version
/// is dropped and the next probe writes this one.
private struct CachedCatalog: Codable {
    static let current = 2
    var version = CachedCatalog.current
    var accounts: [AccountCatalog]
}

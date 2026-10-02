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
/// `catalog` is set on the main actor only: a subscriber's first value — the
/// current one — arrives synchronously.
@MainActor
final class ModelCatalogStore {
    /// Every account's section, in Settings' order.
    @Published private(set) var catalog = ModelCatalog()

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
        // TODO(fill B): read the cache, publish it, probe each account (again
        // on change), fold each answer into `catalog` (`AccountCatalog` from
        // `InitializationResult`), write the cache. ModelCatalogStoreTests.
    }
}

import Foundation

/// Where accounts' secrets are kept, one item per account. Calls block — the
/// keychain may ask the person first — so they are made off the main actor.
nonisolated protocol SecretStore: Sendable {
    /// The item for `account`, or `nil` when there is none.
    func data(for account: UUID) throws -> Data?
    /// Creates or replaces the item for `account`.
    func setData(_ data: Data, for account: UUID) throws
    /// Removes the item for `account`; no item is not an error.
    func removeData(for account: UUID) throws
}

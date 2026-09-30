import Foundation
import os

@testable import ccterm

/// A ``SecretStore`` in memory, so no test touches the login keychain.
final class InMemorySecretStore: SecretStore {
    private let items = OSAllocatedUnfairLock(initialState: [UUID: Data]())

    var accounts: Set<UUID> { items.withLock { Set($0.keys) } }

    func data(for account: UUID) throws -> Data? {
        items.withLock { $0[account] }
    }

    func setData(_ data: Data, for account: UUID) throws {
        items.withLock { $0[account] = data }
    }

    func removeData(for account: UUID) throws {
        _ = items.withLock { $0.removeValue(forKey: account) }
    }
}

import Foundation
import Security

/// Secrets as generic passwords in the login keychain: one item per account,
/// under `service`, never synchronized to iCloud, readable only while the
/// Mac is unlocked. The keychain's access control limits reading them to this
/// app; any other asks the person first.
nonisolated struct KeychainSecretStore: SecretStore {
    /// Scopes the items to this app (its bundle identifier plus a suffix).
    let service: String

    struct Failure: Error, Equatable {
        let status: OSStatus
    }

    func data(for account: UUID) throws -> Data? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return result as? Data
    }

    func setData(_ data: Data, for account: UUID) throws {
        let update = SecItemUpdate(
            baseQuery(for: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure(status: update) }
        var item = baseQuery(for: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        item[kSecAttrLabel as String] = "ccterm account"
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw Failure(status: add) }
    }

    func removeData(for account: UUID) throws {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    private func baseQuery(for account: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.uuidString,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

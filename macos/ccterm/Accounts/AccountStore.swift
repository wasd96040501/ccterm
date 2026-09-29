import Combine
import Foundation

/// Every account the person has set up, in their order: the subscription's
/// settings first, then the API providers. Owns where they are kept — the
/// non-secret part in a JSON file only this user can read, each account's
/// ``AccountSecrets`` in the ``SecretStore`` — and publishes the list.
///
/// The list never holds a secret: they are read only when an account is
/// opened, off the main actor, since the keychain may ask the person first.
/// Changes are written one after another, in the order they were made.
@MainActor
final class AccountStore {
    /// The subscription's settings, then the providers.
    @Published private(set) var accounts: [Account]

    private let fileURL: URL
    private let secrets: SecretStore
    /// The last change being written; the next one waits for it.
    private var lastWrite: Task<Void, Never>?

    init(fileURL: URL, secrets: SecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
        accounts = Self.read(fileURL) ?? [.subscription()]
    }

    /// How sessions on the subscription start — its command, arguments and
    /// variables. Kept whether or not anyone is signed in.
    var subscriptionSettings: Account {
        accounts.first { $0.kind == .subscription } ?? .subscription()
    }

    var providers: [Account] {
        accounts.filter { $0.provider != nil }
    }

    /// The account's secrets; empty when it has none yet.
    func secrets(for id: UUID) async throws -> AccountSecrets {
        let store = secrets
        let data = try await Task.detached { try store.data(for: id) }.value
        guard let data else { return AccountSecrets() }
        return try JSONDecoder().decode(AccountSecrets.self, from: data)
    }

    /// Adds the account, or replaces the one with its id.
    func save(_ account: Account, secrets accountSecrets: AccountSecrets) async throws {
        try await serialized { [self] in
            try await writeSecrets(accountSecrets, for: account.id)
            var next = accounts
            if let index = next.firstIndex(where: { $0.id == account.id }) {
                next[index] = account
            } else {
                next.append(account)
            }
            try commit(next)
        }
    }

    /// A copy of the provider, secrets and all, right after it, named
    /// “<name> Copy”.
    @discardableResult
    func duplicate(_ id: UUID) async throws -> Account? {
        try await serialized { [self] in
            guard let original = accounts.first(where: { $0.id == id }), var provider = original.provider else {
                return nil
            }
            provider.name = String(localized: "\(provider.name) Copy")
            let copy = Account(
                id: UUID(), kind: .provider(provider), command: original.command, arguments: original.arguments)
            try await writeSecrets(try await secrets(for: id), for: copy.id)
            var next = accounts
            next.insert(copy, at: (next.firstIndex { $0.id == id } ?? next.count - 1) + 1)
            try commit(next)
            return copy
        }
    }

    /// Removes a provider and its secrets.
    func remove(_ id: UUID) async throws {
        try await serialized { [self] in
            guard accounts.contains(where: { $0.id == id && $0.provider != nil }) else { return }
            try commit(accounts.filter { $0.id != id })
            let store = secrets
            try await Task.detached { try store.removeData(for: id) }.value
        }
    }

    // MARK: - Writing

    /// Runs `operation` once every earlier write has finished.
    private func serialized<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = lastWrite
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        lastWrite = Task { _ = try? await task.value }
        return try await task.value
    }

    private func writeSecrets(_ accountSecrets: AccountSecrets, for id: UUID) async throws {
        let store = secrets
        let data = try JSONEncoder().encode(accountSecrets)
        try await Task.detached { try store.setData(data, for: id) }.value
    }

    private struct File: Codable {
        var version = 1
        var accounts: [Account]
    }

    private static func read(_ url: URL) -> [Account]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            var accounts = try JSONDecoder().decode(File.self, from: data).accounts
            if !accounts.contains(where: { $0.kind == .subscription }) { accounts.insert(.subscription(), at: 0) }
            return accounts
        } catch {
            appLog(.error, "AccountStore", "unreadable accounts file — \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes `next` and then publishes it: the file is replaced atomically,
    /// its folder is the user's alone (0700) and the file too (0600).
    private func commit(_ next: [Account]) throws {
        let folder = fileURL.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(accounts: next)).write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        accounts = next
    }
}

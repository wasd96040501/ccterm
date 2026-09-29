import XCTest

@testable import ccterm

/// ``AccountStore`` against a temp file and an in-memory ``SecretStore``:
/// what it writes where, and that a new store reads the same accounts back.
@MainActor
final class AccountStoreTests: XCTestCase {
    private var root: URL!
    private var fileURL: URL { root.appendingPathComponent("Support/Accounts.json") }

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static func provider(_ name: String) -> Account {
        var account = Account.newProvider()
        account.kind = .provider(
            Account.Provider(
                name: name, baseURL: "https://relay.example.com", authentication: .apiKey,
                models: Account.Models(main: "opus")))
        account.arguments = "--permission-mode auto"
        return account
    }

    func testStartsWithOnlyTheSubscriptionSettings() {
        let store = AccountStore(fileURL: fileURL, secrets: InMemorySecretStore())
        XCTAssertEqual(store.accounts.map(\.kind), [.subscription])
        XCTAssertTrue(store.providers.isEmpty)
    }

    func testSavedAccountsReadBackAndSecretsStayOutOfTheFile() async throws {
        let secrets = InMemorySecretStore()
        let store = AccountStore(fileURL: fileURL, secrets: secrets)
        let relay = Self.provider("Relay")
        let relaySecrets = AccountSecrets(
            credential: "sk-relay-secret", environment: [EnvironmentVariable(name: "OTHER_API_KEY", value: "k-1")])
        try await store.save(relay, secrets: relaySecrets)

        let reopened = AccountStore(fileURL: fileURL, secrets: secrets)
        XCTAssertEqual(reopened.accounts, store.accounts)
        XCTAssertEqual(reopened.providers, [relay])
        let read = try await reopened.secrets(for: relay.id)
        XCTAssertEqual(read, relaySecrets)

        let file = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(file.contains("sk-relay-secret"))
        XCTAssertFalse(file.contains("OTHER_API_KEY"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: fileURL.deletingLastPathComponent().path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testSavingAgainReplacesInPlace() async throws {
        let store = AccountStore(fileURL: fileURL, secrets: InMemorySecretStore())
        var relay = Self.provider("Relay")
        let other = Self.provider("Other")
        try await store.save(relay, secrets: AccountSecrets(credential: "a"))
        try await store.save(other, secrets: AccountSecrets(credential: "b"))
        relay.command = "relay-wrapper"
        try await store.save(relay, secrets: AccountSecrets(credential: "a"))
        XCTAssertEqual(store.providers.map(\.id), [relay.id, other.id])
        XCTAssertEqual(store.providers.first?.command, "relay-wrapper")
    }

    func testDuplicateCopiesSecretsRightAfterTheOriginal() async throws {
        let secrets = InMemorySecretStore()
        let store = AccountStore(fileURL: fileURL, secrets: secrets)
        let relay = Self.provider("Relay")
        let other = Self.provider("Other")
        try await store.save(relay, secrets: AccountSecrets(credential: "a"))
        try await store.save(other, secrets: AccountSecrets(credential: "b"))

        let duplicated = try await store.duplicate(relay.id)
        let copy = try XCTUnwrap(duplicated)
        XCTAssertEqual(store.providers.map(\.id), [relay.id, copy.id, other.id])
        XCTAssertEqual(copy.provider?.name, String(localized: "\("Relay") Copy"))
        let copied = try await store.secrets(for: copy.id)
        XCTAssertEqual(copied.credential, "a")
    }

    func testRemoveDeletesTheSecretsToo() async throws {
        let secrets = InMemorySecretStore()
        let store = AccountStore(fileURL: fileURL, secrets: secrets)
        let relay = Self.provider("Relay")
        try await store.save(relay, secrets: AccountSecrets(credential: "a"))
        try await store.remove(relay.id)
        XCTAssertTrue(store.providers.isEmpty)
        XCTAssertFalse(secrets.accounts.contains(relay.id))
    }

    func testTheSubscriptionSettingsCannotBeRemoved() async throws {
        let store = AccountStore(fileURL: fileURL, secrets: InMemorySecretStore())
        try await store.remove(store.subscriptionSettings.id)
        XCTAssertEqual(store.accounts.map(\.kind), [.subscription])
    }

    func testWritesLandInTheOrderTheyWereMade() async throws {
        let store = AccountStore(fileURL: fileURL, secrets: InMemorySecretStore())
        var relay = Self.provider("Relay")
        try await store.save(relay, secrets: AccountSecrets(credential: "a"))
        async let first: Void = store.save(relay, secrets: AccountSecrets(credential: "first"))
        relay.command = "second"
        async let second: Void = store.save(relay, secrets: AccountSecrets(credential: "second"))
        _ = try await (first, second)
        let reopened = AccountStore(fileURL: fileURL, secrets: InMemorySecretStore())
        XCTAssertEqual(reopened.providers.first?.command, "second")
    }
}

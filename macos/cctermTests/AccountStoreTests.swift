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

    func testDuplicatingTwiceNamesTheCopiesApart() async throws {
        let store = AccountStore(fileURL: fileURL, secrets: InMemorySecretStore())
        let relay = Self.provider("Relay")
        try await store.save(relay, secrets: AccountSecrets(credential: "a"))
        let first = try await store.duplicate(relay.id)
        let second = try await store.duplicate(relay.id)
        let copy = String(localized: "\("Relay") Copy")
        XCTAssertEqual(first?.provider?.name, copy)
        XCTAssertEqual(second?.provider?.name, "\(copy) 2")
    }

    func testAddWritesEveryAccountAndItsSecretsInOneCommit() async throws {
        let secrets = InMemorySecretStore()
        let store = AccountStore(fileURL: fileURL, secrets: secrets)
        let existing = Self.provider("Existing")
        try await store.save(existing, secrets: AccountSecrets(credential: "e"))
        let first = Self.provider("First")
        let second = Self.provider("Second")
        let published = record(store.$accounts)

        try await store.add([
            (first, AccountSecrets(credential: "1")), (second, AccountSecrets(credential: "2")),
        ])

        XCTAssertEqual(store.providers.map(\.id), [existing.id, first.id, second.id])
        XCTAssertEqual(published.values.count, 2, "the current list, then one for the whole batch")
        let one = try await store.secrets(for: first.id)
        let two = try await store.secrets(for: second.id)
        XCTAssertEqual([one.credential, two.credential], ["1", "2"])
        let reopened = AccountStore(fileURL: fileURL, secrets: secrets)
        XCTAssertEqual(reopened.providers.map(\.id), [existing.id, first.id, second.id])
    }

    func testAddingNothingWritesNothing() async throws {
        let store = AccountStore(fileURL: fileURL, secrets: InMemorySecretStore())
        try await store.add([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testAFailedAddKeepsNoAccountAndNoSecrets() async throws {
        let secrets = InMemorySecretStore()
        let store = AccountStore(fileURL: fileURL, secrets: secrets)
        // The accounts file's folder is a file, so the commit cannot land.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Support"))
        let relay = Self.provider("Relay")
        do {
            try await store.add([(relay, AccountSecrets(credential: "a"))])
            XCTFail("the write should have failed")
        } catch {}
        XCTAssertTrue(store.providers.isEmpty)
        XCTAssertFalse(secrets.accounts.contains(relay.id))
    }

    func testNamesAreMadeUniqueWithANumber() {
        XCTAssertEqual(Account.uniqueName("Relay", among: []), "Relay")
        XCTAssertEqual(Account.uniqueName("Relay", among: ["Other"]), "Relay")
        XCTAssertEqual(Account.uniqueName("Relay", among: ["Relay"]), "Relay 2")
        XCTAssertEqual(Account.uniqueName("Relay", among: ["Relay", "Relay 2"]), "Relay 3")
        XCTAssertEqual(Account.uniqueName("relay", among: ["Relay"]), "relay 2", "case does not tell names apart")
        XCTAssertEqual(Account.uniqueName("Relay", among: ["Relay", "Relay 3"]), "Relay 2")
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

    /// A file written before a model slot existed still reads.
    func testModelsWithoutALaterSlotDecode() throws {
        let models = try JSONDecoder().decode(
            Account.Models.self, from: Data(#"{"main": "m", "opus": "", "sonnet": "", "haiku": ""}"#.utf8))
        XCTAssertEqual(models, Account.Models(main: "m"))
    }
}

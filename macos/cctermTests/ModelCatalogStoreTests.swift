import AgentSDK
import Combine
import XCTest

@testable import ccterm

/// `ModelCatalogStore`: a section per account in Settings' order, filled from
/// each account's `initialize`, kept on disk, probed again only when a launch
/// changes.
@MainActor
final class ModelCatalogStoreTests: XCTestCase {
    private var cache: URL!
    private let accounts = CurrentValueSubject<[Account], Never>([])
    private let subscription = Account.subscription()
    private var relay = Account.newProvider()
    private var cancellables = Set<AnyCancellable>()

    override func setUp() {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        relay.kind = .provider(
            Account.Provider(
                name: "Work Relay", baseURL: "https://relay.example.com", authentication: .authToken,
                models: Account.Models()))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cache)
        cancellables.removeAll()
    }

    private func result(
        _ models: String, type: String = "max", mode: String = "auto", reason: String? = nil
    )
        -> InitializationResult
    {
        let reason = reason.map { #","fast_mode_disabled_reason":"\#($0)""# } ?? ""
        let json =
            #"{"models":\#(models),"commands":[{"name":"review","description":"Review","argumentHint":"<pr>"}],"account":{"subscriptionType":"\#(type)"},"current_permission_mode":"\#(mode)"\#(reason)}"#
        return SessionStateTests.initialization(json)
    }

    private let subscriptionModels =
        #"[{"value":"default","displayName":"Default (recommended)","description":"Opus 5.5","resolvedModel":"claude-opus-5-5","supportsFastMode":true},{"value":"claude-opus-4-6","displayName":"Opus 4.6"},{"value":"opus","displayName":"Opus 5.5","resolvedModel":"claude-opus-5-5"},{"value":"haiku","displayName":"Haiku 4.5"}]"#

    private func store(
        probe: @escaping @Sendable (CLIConfiguration) async throws -> InitializationResult
    ) -> ModelCatalogStore {
        ModelCatalogStore(
            accounts: accounts.eraseToAnyPublisher(),
            configuration: { account in
                CLIConfiguration(
                    customCommand: account.command.isEmpty
                        ? (account.provider == nil ? "claude" : "relay") : account.command,
                    env: ["ID": account.id.uuidString])
            }, probe: probe, cacheURL: cache)
    }

    private func wait(_ store: ModelCatalogStore, _ predicate: @escaping (ModelCatalog) -> Bool) async {
        let arrived = expectation(description: "catalog")
        let subscription = store.$catalog.first(where: predicate).sink { _ in arrived.fulfill() }
        await fulfillment(of: [arrived], timeout: 10)
        subscription.cancel()
    }

    // MARK: - Sections

    func testEveryAccountIsASectionInSettingsOrderLoadingUntilItAnswers() async {
        accounts.send([subscription, relay])
        let store = store { _ in
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        XCTAssertEqual(store.catalog.accounts.map(\.id), [subscription.id, relay.id])
        XCTAssertEqual(store.catalog.accounts.map(\.isLoaded), [false, false])
        XCTAssertEqual(store.catalog.accounts[1].name, "Work Relay")
        XCTAssertEqual(store.catalog.accounts[1].detail, "relay.example.com")
        XCTAssertTrue(store.catalog.accounts[0].isSubscription)
    }

    func testAnAnswerFillsItsAccountsSection() async throws {
        accounts.send([subscription])
        let answer = result(subscriptionModels, reason: "extra_usage_disabled")
        let store = store { _ in answer }
        await wait(store) { $0.accounts.first?.isLoaded == true }
        let section = try XCTUnwrap(store.catalog.subscription)
        XCTAssertEqual(section.name, "Claude Max")
        XCTAssertEqual(section.detail, String(localized: "Subscription"))
        XCTAssertEqual(section.commands.map(\.name), ["review"])
        XCTAssertEqual(section.defaultPermissionMode, .auto)
        XCTAssertEqual(section.fastModeUnavailableReason, String(localized: "Requires extra usage"))
    }

    /// A plan the CLI already names `Claude …` is named once.
    func testThePlanIsNamedOnce() async throws {
        accounts.send([subscription])
        let answer = result(subscriptionModels, type: "Claude Max")
        let store = store { _ in answer }
        await wait(store) { $0.accounts.first?.isLoaded == true }
        XCTAssertEqual(try XCTUnwrap(store.catalog.subscription).name, "Claude Max")
    }

    func testTheSubscriptionListsDefaultAndTheAliasesAndFoldsVersionedModelsAfterThem() async throws {
        accounts.send([subscription])
        let answer = result(subscriptionModels)
        let store = store { _ in answer }
        await wait(store) { $0.accounts.first?.isLoaded == true }
        let section = try XCTUnwrap(store.catalog.subscription)
        XCTAssertEqual(section.models.map(\.value), ["default", "opus", "haiku", "claude-opus-4-6"])
        XCTAssertEqual(section.shownModelCount, 3)
    }

    func testAProvidersModelsAreAllListed() async throws {
        accounts.send([relay])
        let answer = result(#"[{"value":"default"},{"value":"claude-sonnet-4-6"}]"#)
        let store = store { _ in answer }
        await wait(store) { $0.accounts.first?.isLoaded == true }
        let section = try XCTUnwrap(store.catalog.accounts.first)
        XCTAssertEqual(section.shownModelCount, 2)
        XCTAssertEqual(section.name, "Work Relay")
    }

    func testFastModeReasonsAreWords() {
        XCTAssertNil(AccountCatalog.words(forFastModeReason: "sdk_opt_in_required"), "ccterm opts in itself")
        XCTAssertEqual(
            AccountCatalog.words(forFastModeReason: "extra_usage_disabled"), String(localized: "Requires extra usage"))
        XCTAssertEqual(
            AccountCatalog.words(forFastModeReason: "something_new"), String(localized: "Currently unavailable"))
    }

    // MARK: - Probing

    func testTheSameLaunchIsNotProbedTwice() async throws {
        let count = Counter()
        accounts.send([subscription])
        let answer = result(subscriptionModels)
        let store = store { _ in
            count.increment()
            return answer
        }
        await wait(store) { $0.accounts.first?.isLoaded == true }
        accounts.send([subscription])
        accounts.send([subscription])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(count.value, 1)
    }

    func testAChangedLaunchIsProbedAgain() async throws {
        let count = Counter()
        accounts.send([relay])
        let answer = result(#"[{"value":"default"}]"#)
        let store = store { _ in
            count.increment()
            return answer
        }
        await wait(store) { $0.accounts.first?.isLoaded == true }
        var changed = relay
        changed.command = "other-relay"
        accounts.send([changed])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(count.value, 2)
        XCTAssertEqual(store.catalog.accounts.count, 1)
    }

    func testAnAccountRemovedLeavesTheCatalog() async {
        accounts.send([subscription, relay])
        let answer = result(#"[{"value":"default"}]"#)
        let store = store { _ in answer }
        await wait(store) { $0.accounts.allSatisfy(\.isLoaded) }
        accounts.send([subscription])
        XCTAssertEqual(store.catalog.accounts.map(\.id), [subscription.id])
    }

    func testAProbeThatFailsLeavesTheSectionLoadingAndIsTriedAgainOnTheNextChange() async throws {
        struct Failure: Error {}
        let count = Counter()
        accounts.send([subscription])
        let answer = result(subscriptionModels)
        let store = store { _ in
            if count.increment() == 1 { throw Failure() }
            return answer
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.catalog.accounts.map(\.isLoaded), [false])
        accounts.send([subscription])
        await wait(store) { $0.accounts.first?.isLoaded == true }
        XCTAssertEqual(count.value, 2)
    }

    // MARK: - The disk cache

    func testTheLastAnswerIsShownAtOnceByTheNextLaunch() async throws {
        accounts.send([subscription])
        let answer = result(subscriptionModels, reason: "extra_usage_disabled")
        let first = store { _ in answer }
        await wait(first) { $0.accounts.first?.isLoaded == true }
        try await Task.sleep(for: .milliseconds(300))

        let second = store { _ in
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        let section = try XCTUnwrap(second.catalog.subscription)
        XCTAssertTrue(section.isLoaded, "from the cache, before any probe")
        XCTAssertEqual(section.models.map(\.value), first.catalog.subscription?.models.map(\.value))
        XCTAssertEqual(section.models.first?.resolvedModel, "claude-opus-5-5")
        XCTAssertEqual(section.models.first?.supportsFastMode, true)
        XCTAssertEqual(section.commands.map(\.argumentHint), ["<pr>"])
        XCTAssertEqual(section.fastModeUnavailableReason, String(localized: "Requires extra usage"))
        XCTAssertEqual(section.shownModelCount, 3)
    }

    func testAnUnreadableCacheIsNoCache() {
        try? "not json".write(to: cache, atomically: true, encoding: .utf8)
        accounts.send([subscription])
        let store = store { _ in throw CancellationError() }
        XCTAssertEqual(store.catalog.accounts.map(\.isLoaded), [false])
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

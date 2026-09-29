import AgentSDK
import Combine
import XCTest

@testable import ccterm

/// ``LaunchStore``: what it reads from and writes to the defaults, the
/// configurations it publishes for General and the subscription, and the
/// session directory — first at once, then as a login shell says.
@MainActor
final class LaunchStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let accounts = CurrentValueSubject<[Account], Never>([.subscription()])

    override func setUp() {
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func store(
        resolve: @escaping @Sendable (CLIConfiguration) -> SessionDirectory = { _ in
            SessionDirectory(url: URL(fileURLWithPath: "/resolved"))
        }
    ) -> LaunchStore {
        LaunchStore(defaults: defaults, accounts: accounts.eraseToAnyPublisher(), resolveDirectory: resolve)
    }

    func testPreferencesReadAndWriteTheDefaultsKeys() {
        defaults.set("orange", forKey: "customCLICommand")
        defaults.set("/tmp/claude", forKey: "claudeConfigDirectory")
        let launch = store()
        XCTAssertEqual(launch.preferences, LaunchPreferences(command: "orange", configDirectory: "/tmp/claude"))

        launch.setCommand("  blue  ")
        launch.setConfigDirectory(" /tmp/other ")
        XCTAssertEqual(launch.preferences, LaunchPreferences(command: "blue", configDirectory: "/tmp/other"))
        XCTAssertEqual(defaults.string(forKey: "customCLICommand"), "blue")
        XCTAssertEqual(defaults.string(forKey: "claudeConfigDirectory"), "/tmp/other")

        launch.setCommand("")
        launch.setConfigDirectory("")
        XCTAssertNil(defaults.object(forKey: "customCLICommand"))
        XCTAssertNil(defaults.object(forKey: "claudeConfigDirectory"))
    }

    func testGeneralFollowsPreferencesAndIgnoresTheAccounts() {
        let launch = store()
        let recording = record(launch.$general)
        XCTAssertEqual(launch.general, CLIConfiguration())
        launch.setCommand("orange")
        launch.setConfigDirectory("/tmp/claude")
        XCTAssertEqual(launch.general.customCommand, "orange")
        XCTAssertEqual(launch.general.env, ["CLAUDE_CONFIG_DIR": "/tmp/claude"])
        launch.setCommand("orange")
        var subscription = Account.subscription()
        subscription.command = "own"
        accounts.send([subscription])
        XCTAssertEqual(recording.values.count, 3, "the current value, then one per change; nothing for a repeat")
    }

    func testTheSubscriptionsOwnCommandWinsOverGeneralsAndFollowsTheAccounts() {
        let launch = store()
        launch.setCommand("orange")
        XCTAssertEqual(launch.subscription.customCommand, "orange")

        var subscription = Account.subscription()
        subscription.command = "own-claude"
        accounts.send([subscription, .newProvider()])
        XCTAssertEqual(launch.subscription.customCommand, "own-claude")
        XCTAssertEqual(launch.general.customCommand, "orange")

        subscription.command = ""
        accounts.send([subscription])
        XCTAssertEqual(launch.subscription.customCommand, "orange")
        launch.setConfigDirectory("/tmp/claude")
        XCTAssertEqual(launch.subscription.env, ["CLAUDE_CONFIG_DIR": "/tmp/claude"])
    }

    func testTheSubscriptionsCommandIsKnownAtInit() {
        var subscription = Account.subscription()
        subscription.command = "own-claude"
        accounts.send([subscription])
        XCTAssertEqual(store().subscription.customCommand, "own-claude")
    }

    func testTheSessionDirectoryStartsFromGeneralsFolderThenTakesTheResolvedOne() async {
        defaults.set("/tmp/claude", forKey: "claudeConfigDirectory")
        let launch = store()
        XCTAssertEqual(launch.sessionDirectory.url.path, "/tmp/claude/projects")
        await waitFor(launch.$sessionDirectory) { $0.url.path == "/resolved" }
        XCTAssertEqual(launch.sessionDirectory.url.path, "/resolved")
    }

    func testTheSessionDirectoryIsResolvedForEachNewGeneral() async {
        let launch = store { configuration in
            SessionDirectory(url: URL(fileURLWithPath: "/for/\(configuration.customCommand ?? "default")"))
        }
        await waitFor(launch.$sessionDirectory) { $0.url.path == "/for/default" }
        launch.setCommand("orange")
        await waitFor(launch.$sessionDirectory) { $0.url.path == "/for/orange" }
    }

    func testAStaleResolutionIsDropped() async {
        let slow = DispatchSemaphore(value: 0)
        let slowStarted = expectation(description: "the slow resolution started")
        let slowDone = expectation(description: "the slow resolution finished")
        let launch = store { configuration in
            switch configuration.customCommand {
            case "slow":
                slowStarted.fulfill()
                slow.wait()
                slowDone.fulfill()
                return SessionDirectory(url: URL(fileURLWithPath: "/slow"))
            default:
                return SessionDirectory(url: URL(fileURLWithPath: "/for/\(configuration.customCommand ?? "default")"))
            }
        }
        await waitFor(launch.$sessionDirectory) { $0.url.path == "/for/default" }
        let seen = record(launch.$sessionDirectory)

        launch.setCommand("slow")
        await fulfillment(of: [slowStarted], timeout: 10)
        launch.setCommand("fast")
        await waitFor(launch.$sessionDirectory) { $0.url.path == "/for/fast" }

        slow.signal()
        await fulfillment(of: [slowDone], timeout: 10)
        // A later resolution lands after the stale one has been handled.
        launch.setCommand("last")
        await waitFor(launch.$sessionDirectory) { $0.url.path == "/for/last" }
        XCTAssertEqual(seen.values.map(\.url.path), ["/for/default", "/for/fast", "/for/last"])
    }
}

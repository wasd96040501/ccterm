import AgentSDK
import AppKit
import Combine
import XCTest

@testable import ccterm

// Combine has a `Subscription` too.
private typealias Subscription = ccterm.Subscription

/// Visual review for the Settings panes and sheets, in light and dark, with
/// the sample accounts of `design/settings/index.html` — so each PNG can be
/// laid over the mock's render of the same region. The panes render without
/// the window's toolbar: the mock's pane starts 52 below its top.
///
/// Opt-in (filename ends in `SnapshotTests`); see cctermTests/CLAUDE.md.
@MainActor
final class SettingsSnapshotTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The detail column under the toolbar: 880 − 180 wide, 680 − 52 tall.
    private let paneSize = CGSize(width: 700, height: 628)

    func testAccounts() throws {
        for appearance in Appearance.allCases {
            let store = try seeded { try await self.sampleStore() }
            let pane = try accountsPane(store, subscription: try seeded { await self.signedIn() })
            render(pane, size: paneSize, appearance: appearance, name: "Settings-Accounts")
        }
    }

    func testAccountsWithoutProviders() throws {
        for appearance in Appearance.allCases {
            let store = AccountStore(
                fileURL: root.appendingPathComponent("\(UUID()).json"), secrets: InMemorySecretStore())
            let pane = try accountsPane(store, subscription: try seeded { await self.signedOut() })
            render(pane, size: paneSize, appearance: appearance, name: "Settings-AccountsEmpty")
        }
    }

    func testGeneral() throws {
        for appearance in Appearance.allCases {
            let store = AccountStore(
                fileURL: root.appendingPathComponent("\(UUID()).json"), secrets: InMemorySecretStore())
            let (launch, check) = try launchSettings(store)
            render(
                GeneralSettingsViewController(launch: launch, launchCheck: check), size: paneSize,
                appearance: appearance, name: "Settings-General")
        }
    }

    func testProviderSheet() throws {
        for appearance in Appearance.allCases {
            let editor = try editorSheet(mode: .provider, account: Self.localProxy, secrets: Self.localProxySecrets)
            render(
                editor, size: AccountEditorViewController.size, appearance: appearance, name: "Settings-ProviderSheet")
        }
    }

    func testNewProviderSheet() throws {
        for appearance in Appearance.allCases {
            let editor = try editorSheet(mode: .newProvider, account: .newProvider(), secrets: AccountSecrets())
            render(
                editor, size: AccountEditorViewController.size, appearance: appearance,
                name: "Settings-NewProviderSheet")
        }
    }

    func testSubscriptionSheet() throws {
        for appearance in Appearance.allCases {
            let editor = try editorSheet(
                mode: .subscription(Self.subscription), account: .subscription(),
                secrets: AccountSecrets(
                    environment: [EnvironmentVariable(name: "CLAUDE_CODE_NO_FLICKER", value: "1")]))
            render(
                editor, size: AccountEditorViewController.size, appearance: appearance,
                name: "Settings-SubscriptionSheet")
        }
    }

    func testSignInSheet() throws {
        for appearance in Appearance.allCases {
            let sheet = SignInViewController()
            sheet.loadView()
            sheet.viewDidLoad()
            render(sheet, size: sheet.preferredContentSize, appearance: appearance, name: "Settings-SignIn")
        }
    }

    // MARK: - Fixtures (the mock's sample data)

    private enum Appearance: String, CaseIterable {
        case light, dark
        var named: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
    }

    private static let subscription = Subscription(
        email: "name@example.com", organization: "Personal", plan: "max", method: "claude.ai")

    private static let localProxy = Account(
        id: UUID(),
        kind: .provider(
            .init(
                name: "Local Proxy", baseURL: "http://127.0.0.1:8788", authentication: .authToken,
                models: .init(main: "claude-opus-5-5[1m]"))),
        command: "", arguments: "--permission-mode auto")

    private static let localProxySecrets = AccountSecrets(
        credential: "sk-proxy-example-4b0e9d2c7c1e",
        environment: [
            EnvironmentVariable(name: "NO_PROXY", value: "127.0.0.1,localhost"),
            EnvironmentVariable(name: "API_TIMEOUT_MS", value: "3000000"),
            EnvironmentVariable(name: "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", value: "1"),
            EnvironmentVariable(name: "CLAUDE_CODE_EFFORT_LEVEL", value: "xhigh"),
            EnvironmentVariable(name: "CLAUDE_CODE_ATTRIBUTION_HEADER", value: "0"),
            EnvironmentVariable(isEnabled: false, name: "ENABLE_TOOL_SEARCH", value: "false"),
        ])

    private func sampleStore() async throws -> AccountStore {
        let store = AccountStore(
            fileURL: root.appendingPathComponent("\(UUID()).json"), secrets: InMemorySecretStore())
        try await store.save(Self.localProxy, secrets: Self.localProxySecrets)
        let relay = Account(
            id: UUID(),
            kind: .provider(
                .init(
                    name: "Team Relay", baseURL: "https://relay.example.com", authentication: .authToken,
                    models: .init(main: "claude-opus-5-5[1m]"))),
            command: "", arguments: "--permission-mode auto")
        try await store.save(relay, secrets: AccountSecrets(credential: "sk-relay-example-91f3a0d85a27"))
        let glm = Account(
            id: UUID(),
            kind: .provider(
                .init(
                    name: "GLM", baseURL: "http://127.0.0.1:8788", authentication: .authToken,
                    models: .init(main: "glm-5.2[1m]", opus: "glm-5.2[1m]", sonnet: "glm-5.2[1m]", haiku: "glm-5.2[1m]")
                )),
            command: "", arguments: "")
        try await store.save(glm, secrets: AccountSecrets(credential: "sk-proxy-example-4b0e9d2c7c1e"))
        return store
    }

    /// The settings the panes read: defaults in a private suite, a session
    /// directory that isn't looked up, and a launch that checks out.
    private func launchSettings(_ accounts: AccountStore) throws -> (LaunchStore, LaunchCheckService) {
        let launch = LaunchStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, accounts: accounts.$accounts.eraseToAnyPublisher(),
            resolveDirectory: { _ in SessionDirectory(url: URL(fileURLWithPath: "/tmp/none")) })
        let check = LaunchCheckService(probe: { _ in
            CLIVersion(executable: "/Users/me/.local/bin/claude", version: "2.1.284")
        })
        _ = try seeded { await check.check(launch.general) }
        return (launch, check)
    }

    private func accountsPane(
        _ accounts: AccountStore, subscription: SubscriptionService
    ) throws
        -> AccountsSettingsViewController
    {
        let (launch, check) = try launchSettings(accounts)
        return AccountsSettingsViewController(
            accounts: accounts, launch: launch, launchCheck: check, subscription: subscription)
    }

    private func editorSheet(
        mode: AccountEditorMode, account: Account, secrets: AccountSecrets
    ) throws
        -> AccountEditorViewController
    {
        let store = AccountStore(fileURL: root.appendingPathComponent("\(UUID()).json"), secrets: InMemorySecretStore())
        let (launch, check) = try launchSettings(store)
        let validation = LaunchCommandValidation(
            check: check, configuration: { launch.configuration(accountCommand: $0) },
            text: account.command)
        return AccountEditorViewController(
            viewModel: AccountEditorViewModel(
                mode: mode, account: account, secrets: secrets, commandValidation: validation))
    }

    private func signedIn() async -> SubscriptionService {
        let service = SubscriptionService(
            auth: StubAuth(subscription: Self.subscription),
            configurations: Just(CLIConfiguration()).eraseToAnyPublisher())
        await service.refresh()
        return service
    }

    private func signedOut() async -> SubscriptionService {
        let service = SubscriptionService(
            auth: StubAuth(subscription: nil), configurations: Just(CLIConfiguration()).eraseToAnyPublisher())
        await service.refresh()
        return service
    }

    private struct StubAuth: SubscriptionAuth {
        let subscription: Subscription?
        func current(_ configuration: CLIConfiguration) async throws -> Subscription? { subscription }
        func signIn(_ configuration: CLIConfiguration) -> AsyncThrowingStream<URL, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func signOut(_ configuration: CLIConfiguration) async throws {}
    }

    /// Runs async seeding to its end from a synchronous test, so the run
    /// loop stays free to deliver the views' main-queue sinks.
    private func seeded<T>(_ make: @escaping @MainActor () async throws -> T) throws -> T {
        let done = expectation(description: "seeded")
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await make()) } catch { result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result).get()
    }

    private func render(_ controller: NSViewController, size: CGSize, appearance: Appearance, name: String) {
        controller.view.appearance = NSAppearance(named: appearance.named)
        let image = ViewSnapshot.renderViewController(controller, size: size, settle: 0.6)
        let url = ViewSnapshot.writePNG(image, name: "\(name)-\(appearance.rawValue)")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name)-\(appearance.rawValue).png"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
    }
}

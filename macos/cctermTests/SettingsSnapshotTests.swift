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

    /// ⌘V with three aliases on a list of three: two are added and tinted, the
    /// one without a token is skipped, and the pane's toast counts them.
    func testAccountsImported() throws {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        for appearance in Appearance.allCases {
            let store = try seeded { try await self.sampleStore() }
            let pane = try accountsPane(store, subscription: try seeded { await self.signedIn() })
            _ = pane.view
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.threeAliases, forType: .string)
            pane.paste(nil)
            let deadline = Date().addingTimeInterval(5)
            while store.providers.count < 5, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
            XCTAssertEqual(store.providers.count, 5)
            render(pane, size: paneSize, appearance: appearance, name: "Settings-AccountsImported")
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

    /// The list's + | − bar with the pointer over +, and a command that runs.
    func testProviderSheetHoveringAdd() throws {
        for appearance in Appearance.allCases {
            var account = Self.localProxy
            account.command = "~/bin/claude-relay"
            let editor = try editorSheet(mode: .provider, account: account, secrets: Self.localProxySecrets)
            let add = try XCTUnwrap(
                Self.descendants(of: editor.view, ofType: ListBarButton.self).first)
            add.mouseEntered(
                with: NSEvent.enterExitEvent(
                    with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
            render(
                editor, size: AccountEditorViewController.size, appearance: appearance,
                name: "Settings-ProviderSheetHover")
        }
    }

    /// A command that runs: the version under it, secondary, and no gap under
    /// Arguments.
    func testProviderSheetValidCommand() throws {
        for appearance in Appearance.allCases {
            var account = Self.localProxy
            account.command = "~/bin/claude-relay"
            let editor = try editorSheet(mode: .provider, account: account, secrets: Self.localProxySecrets)
            try scrollToEnd(editor)
            render(
                editor, size: AccountEditorViewController.size, appearance: appearance,
                name: "Settings-ProviderSheetValidCommand")
        }
    }

    /// A command that doesn't run: the reason in red under it, nothing else.
    func testProviderSheetInvalidCommand() throws {
        for appearance in Appearance.allCases {
            var account = Self.localProxy
            account.command = "missing-claude"
            let editor = try editorSheet(
                mode: .provider, account: account,
                secrets: AccountSecrets(
                    credential: "sk-proxy-example-4b0e9d2c7c1e",
                    environment: [EnvironmentVariable(name: "CLAUDE_CONFIG_DIR", value: "~/.claude-work")]),
                probe: { configuration in
                    if configuration.customCommand?.contains("missing") == true { throw AgentSDKError.binaryNotFound }
                    return CLIVersion(executable: "/Users/me/.local/bin/claude", version: "2.1.284")
                })
            try scrollToEnd(editor)
            render(
                editor, size: AccountEditorViewController.size, appearance: appearance,
                name: "Settings-ProviderSheetInvalidCommand")
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

    private static let threeAliases = """
        alias kimi="ANTHROPIC_BASE_URL=https://api.kimi.example.com ANTHROPIC_AUTH_TOKEN=sk-kimi-example-1a2b3c4d claude --model kimi-k2"
        alias deepseek="ANTHROPIC_BASE_URL=https://api.deepseek.example.com ANTHROPIC_AUTH_TOKEN=sk-ds-example-5e6f7a8b claude"
        alias noauth="ANTHROPIC_BASE_URL=https://api.other.example.com claude"
        """

    private static func descendants<T: NSView>(of view: NSView, ofType type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(of: $0, ofType: type) }
    }

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
    private func launchSettings(
        _ accounts: AccountStore,
        probe: @escaping LaunchCheckService.Probe = { _ in
            CLIVersion(executable: "/Users/me/.local/bin/claude", version: "2.1.284")
        }
    ) throws -> (LaunchStore, LaunchCheckService) {
        let launch = LaunchStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, accounts: accounts.$accounts.eraseToAnyPublisher(),
            resolveDirectory: { _ in SessionDirectory(url: URL(fileURLWithPath: "/tmp/none")) })
        let check = LaunchCheckService(probe: probe)
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
        mode: AccountEditorMode, account: Account, secrets: AccountSecrets,
        probe: @escaping LaunchCheckService.Probe = { _ in
            CLIVersion(executable: "/Users/me/.local/bin/claude", version: "2.1.284")
        }
    ) throws
        -> AccountEditorViewController
    {
        let store = AccountStore(fileURL: root.appendingPathComponent("\(UUID()).json"), secrets: InMemorySecretStore())
        let (launch, check) = try launchSettings(store, probe: probe)
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

    /// Scrolls the sheet's form to its end, where Launch is.
    private func scrollToEnd(_ editor: AccountEditorViewController) throws {
        editor.view.frame = CGRect(origin: .zero, size: AccountEditorViewController.size)
        editor.view.layoutSubtreeIfNeeded()
        let form = try XCTUnwrap(Self.descendants(of: editor.view, ofType: FormView.self).first)
        let clip = form.contentView
        let end = (form.documentView?.frame.height ?? 0) - clip.bounds.height
        clip.scroll(to: NSPoint(x: 0, y: max(0, end)))
        form.reflectScrolledClipView(clip)
    }

    private func render(_ controller: NSViewController, size: CGSize, appearance: Appearance, name: String) {
        controller.view.appearance = NSAppearance(named: appearance.named)
        // The views draw no background of their own, and a dark render on a
        // transparent PNG reads as blank.
        controller.view.wantsLayer = true
        controller.view.effectiveAppearance.performAsCurrentDrawingAppearance {
            controller.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        let image = ViewSnapshot.renderViewController(controller, size: size, settle: 0.6)
        let url = ViewSnapshot.writePNG(image, name: "\(name)-\(appearance.rawValue)")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name)-\(appearance.rawValue).png"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
    }
}

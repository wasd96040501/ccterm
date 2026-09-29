import AgentSDK
import AppKit
import Combine
import SwiftUI

/// AppKit-side application delegate and the app's composition root. Owns
/// the main window's lifecycle — creating it from
/// `applicationDidFinishLaunching` instead of declaring a SwiftUI `Window`
/// scene — and every auxiliary window's (lazy `SettingsWindowController` /
/// `AboutWindowController`), so the OS can't resurface them from saved
/// state at the next launch and SwiftUI can't auto-open them as the
/// leading `Window` scene.
///
/// `CCTermApp.body` keeps only a `Settings { EmptyView() }` placeholder to
/// satisfy the `App` protocol's `some Scene` requirement; menu items live
/// in `AppCommands` — a SwiftUI `Commands` block attached to that
/// placeholder scene. SwiftUI merges those into the app's main menu, so
/// cold-start menu clicks (⌘, → `showSettingsWindow()`, App > About ccterm
/// → `showAboutWindow()`) resolve their closures without an AppKit bridge.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindowController: MainWindowController?

    // The object graph, built once in `applicationDidFinishLaunching`; nil in
    // a hosted test run, which builds none of it.

    /// Every account: the subscription's settings and the API providers. They
    /// live under Application Support, their secrets in the login keychain.
    private var accounts: AccountStore?
    /// How the CLI is launched — General's settings and what the accounts make
    /// of them.
    private var launch: LaunchStore?
    /// Whether a launch works.
    private var launchCheck: LaunchCheckService?
    /// The CLI's claude.ai login, read for the launch of the subscription's
    /// sessions.
    private var subscription: SubscriptionService?
    /// Every transcript on disk, for the main window's sidebar. Process-wide:
    /// it mirrors a directory the CLI owns, and one scan serves every window.
    private var library: LibraryStore?

    /// Lazy AppKit-rooted Settings window. Created on the first
    /// `showSettingsWindow()` call (⌘, or App > Settings… menu item)
    /// — never at launch, so the OS cannot resurface it from saved
    /// state.
    private var settingsWindowController: SettingsWindowController?

    /// What Settings reads and changes; `nil` before launch has built it.
    private var settingsContext: SettingsContext? {
        guard let accounts, let launch, let launchCheck, let subscription else { return nil }
        return SettingsContext(
            accounts: accounts, launch: launch, launchCheck: launchCheck, subscription: subscription)
    }

    func showSettingsWindow() {
        guard let context = settingsContext else { return }
        let controller =
            settingsWindowController
            ?? {
                let c = SettingsWindowController(context: context)
                c.windowFrameAutosaveName = "SettingsWindow"
                settingsWindowController = c
                return c
            }()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Lazy AppKit-rooted About window. Same shape as
    /// `settingsWindowController` — created
    /// on the first `showAboutWindow()` call (App > About ccterm menu
    /// item) so SwiftUI cannot auto-open it as the leading `Window`
    /// scene and the OS cannot resurface it from saved state.
    private var aboutWindowController: AboutWindowController?

    func showAboutWindow() {
        let controller =
            aboutWindowController
            ?? {
                let c = AboutWindowController()
                aboutWindowController = c
                return c
            }()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Hosted unit tests keep NSApp alive for AppKit rendering, but the host
        // shows no Dock icon and opens no window of its own.
        if Self.isUnderXCTest {
            NSApp.setActivationPolicy(.accessory)
            return
        }
        UserDefaults.standard.set(0, forKey: "NSInitialToolTipDelay")
        MainThreadWatchdog.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isUnderXCTest { return }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.ccterm.app"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
        // The index only saves reading: Caches, which the system may clear.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)

        let accounts = AccountStore(
            fileURL: support.appendingPathComponent("Accounts.json"),
            secrets: KeychainSecretStore(service: bundleID + ".accounts"))
        let launch = LaunchStore(defaults: .standard, accounts: accounts.$accounts.eraseToAnyPublisher())
        let launchCheck = LaunchCheckService()
        let subscription = SubscriptionService(
            auth: CLISubscriptionAuth(),
            configurations: launch.$subscription.removeDuplicates().eraseToAnyPublisher())
        let library = LibraryStore(
            directories: launch.$sessionDirectory.removeDuplicates().eraseToAnyPublisher(), indexDirectory: caches)
        self.accounts = accounts
        self.launch = launch
        self.launchCheck = launchCheck
        self.subscription = subscription
        self.library = library
        let controller = MainWindowController(library: library, git: GitService())
        // Where the frame persists is the app's configuration, not the window's:
        // a `MainWindowController` built anywhere else writes no defaults.
        controller.windowFrameAutosaveName = "MainWindow"
        mainWindowController = controller
        library.start()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        // Settings opens on what is already known: the login is read as the
        // subscription service is built; whether the CLI runs, now.
        Task { _ = await launchCheck.check(launch.general) }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            mainWindowController?.showWindow(nil)
            mainWindowController?.window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// XCTest injects this into a hosted test run.
    private static let isUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

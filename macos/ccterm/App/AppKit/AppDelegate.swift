import AppKit

/// Application entry point. Owns process-wide lifecycle: XCTest
/// activation policy, launch-time side effects (model catalog prefetch,
/// tooltip delay, main-thread watchdog), the composition root, the
/// main menu, and shutdown of every active CLI subprocess. All window
/// creation is delegated to `AppCoordinator` — this class never touches
/// an `NSWindow` directly.
///
/// The composition root lives in `applicationWillFinishLaunching(_:)`:
/// every service is constructed inline and threaded top-down into the
/// `AppContext` value that every downstream window / view controller
/// reads. Nothing here uses a shared singleton — the one exception is
/// `ModelStore.shared.prefetchIfNeeded()`, which fronts a process-scope
/// cache backed by a spawned CLI subprocess.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appContext: AppContext!
    private var appCoordinator: AppCoordinator!

    /// Hosted unit tests inject `XCTestConfigurationFilePath`. Under
    /// that env, the test harness stands up its own composition root and
    /// main menu; the app-launched instances would race with the tests'
    /// per-suite fixtures and steal focus, so we keep NSApp alive with
    /// accessory activation policy and skip every side effect.
    private static let isUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Self.isUnderXCTest {
            NSApplication.shared.setActivationPolicy(.accessory)
            return
        }

        let activationTracker = AppActivationTracker()
        let sessionManager = SessionManager()
        let syntaxEngine = SyntaxHighlightEngine()
        let recentProjects = RecentProjectsStore()
        let inputDraftStore = InputDraftStore()
        let sidebarGroupOrder = SidebarSessionGroupOrderStore()
        let openInService = OpenInAppService()
        let notificationService = NotificationService(activation: activationTracker)

        sessionManager.onTurnEndedNotice = { [notifications = notificationService] notice in
            notifications.handleTurnEnded(notice)
        }
        sessionManager.onPermissionPromptNotice = { [notifications = notificationService] notice in
            notifications.handlePermissionPrompt(notice)
        }

        Task.detached(priority: .utility) { await syntaxEngine.load() }
        openInService.refresh()

        MainActor.assumeIsolated { ModelStore.shared.prefetchIfNeeded() }
        MainThreadWatchdog.start()
        UserDefaults.standard.set(0, forKey: "NSInitialToolTipDelay")

        appContext = AppContext(
            sessionManager: sessionManager,
            syntaxEngine: syntaxEngine,
            recentProjects: recentProjects,
            inputDraftStore: inputDraftStore,
            sidebarGroupOrder: sidebarGroupOrder,
            activationTracker: activationTracker,
            openInService: openInService,
            notificationService: notificationService
        )

        installMainMenu()
        appCoordinator = AppCoordinator(appContext: appContext)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isUnderXCTest { return }
        appCoordinator.start()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            appCoordinator.reopenMainWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Before NSApplication tears down the process, give every active
    /// CLI subprocess a chance to flush its session file. The shutdown
    /// runs sessions in parallel inside
    /// `SessionManager.shutdownAllAsync()`, so wall time is bounded by
    /// the slowest CLI (the AgentSDK enforces a 5s per-process graceful
    /// timeout before SIGTERM) rather than scaling linearly with the
    /// session count.
    ///
    /// Returning `.terminateLater` parks the quit; we reply once the
    /// task group finishes. Under XCTest we skip entirely — the test
    /// harness owns lifecycle and there's no real CLI to shut down.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.isUnderXCTest { return .terminateNow }
        appLog(.info, "AppDelegate", "applicationShouldTerminate — begin parallel CLI shutdown")
        Task { @MainActor in
            await appContext.sessionManager.shutdownAllAsync()
            appLog(.info, "AppDelegate", "applicationShouldTerminate — replying")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Menu actions

    @objc private func showAbout(_ sender: Any?) {
        appCoordinator.showAbout()
    }

    @objc private func showSettings(_ sender: Any?) {
        appCoordinator.showSettings()
    }

    @objc private func requestSearchFocus(_ sender: Any?) {
        appCoordinator.requestSearchFocus()
    }

    // MARK: - Main menu

    private func installMainMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        mainMenu.addItem(makeViewMenuItem())
        mainMenu.addItem(makeFindMenuItem())

        let windowMenuItem = makeWindowMenuItem()
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenuItem.submenu
    }

    private func makeAppMenuItem() -> NSMenuItem {
        let appName = "ccterm"
        let menu = NSMenu(title: appName)

        let about = NSMenuItem(
            title: String(localized: "About ccterm"),
            action: #selector(showAbout(_:)),
            keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: String(localized: "Settings…"),
            action: #selector(showSettings(_:)),
            keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let hide = NSMenuItem(
            title: String(localized: "Hide ccterm"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        hide.keyEquivalentModifierMask = [.command]
        menu.addItem(hide)

        let hideOthers = NSMenuItem(
            title: String(localized: "Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)

        let showAll = NSMenuItem(
            title: String(localized: "Show All"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        menu.addItem(showAll)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: String(localized: "Quit ccterm"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: String(localized: "Edit"))

        // `undo:` / `redo:` live on the first-responder chain (posted
        // by AppKit into whichever text control has focus); they aren't
        // declared as Swift selectors, so we build them by name.
        let undo = NSMenuItem(
            title: String(localized: "Undo"),
            action: NSSelectorFromString("undo:"),
            keyEquivalent: "z")
        undo.keyEquivalentModifierMask = [.command]
        menu.addItem(undo)

        let redo = NSMenuItem(
            title: String(localized: "Redo"),
            action: NSSelectorFromString("redo:"),
            keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())

        let cut = NSMenuItem(
            title: String(localized: "Cut"),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x")
        cut.keyEquivalentModifierMask = [.command]
        menu.addItem(cut)

        let copy = NSMenuItem(
            title: String(localized: "Copy"),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c")
        copy.keyEquivalentModifierMask = [.command]
        menu.addItem(copy)

        let paste = NSMenuItem(
            title: String(localized: "Paste"),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v")
        paste.keyEquivalentModifierMask = [.command]
        menu.addItem(paste)

        let delete = NSMenuItem(
            title: String(localized: "Delete"),
            action: #selector(NSText.delete(_:)),
            keyEquivalent: "")
        menu.addItem(delete)

        let selectAll = NSMenuItem(
            title: String(localized: "Select All"),
            action: #selector(NSResponder.selectAll(_:)),
            keyEquivalent: "a")
        selectAll.keyEquivalentModifierMask = [.command]
        menu.addItem(selectAll)

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeViewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: String(localized: "View"))

        let toggleSidebar = NSMenuItem(
            title: String(localized: "Toggle Sidebar"),
            action: #selector(NSSplitViewController.toggleSidebar(_:)),
            keyEquivalent: "s")
        toggleSidebar.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(toggleSidebar)

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeFindMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: String(localized: "Find"))

        let findInTranscript = NSMenuItem(
            title: String(localized: "Find in Transcript"),
            action: #selector(requestSearchFocus(_:)),
            keyEquivalent: "f")
        findInTranscript.keyEquivalentModifierMask = [.command]
        findInTranscript.target = self
        menu.addItem(findInTranscript)

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeWindowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: String(localized: "Window"))

        let minimize = NSMenuItem(
            title: String(localized: "Minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        minimize.keyEquivalentModifierMask = [.command]
        menu.addItem(minimize)

        let zoom = NSMenuItem(
            title: String(localized: "Zoom"),
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: "")
        menu.addItem(zoom)

        menu.addItem(.separator())

        let bringAllToFront = NSMenuItem(
            title: String(localized: "Bring All to Front"),
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: "")
        menu.addItem(bringAllToFront)

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}

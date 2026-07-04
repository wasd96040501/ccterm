import AppKit

/// Delegate protocol a `MainWindowCoordinator` reports up through.
/// Owned here because `AppCoordinator` is its only parent — declaring
/// it next to the parent implementation keeps "who ends the flow" and
/// "who owns the child" in one file.
@MainActor
protocol MainWindowCoordinatorParent: AnyObject {
    func mainWindowCoordinatorDidFinish(_ coordinator: MainWindowCoordinator)
}

/// Root of the coordinator tree. Owns the main window's coordinator
/// plus every auxiliary window's coordinator (Settings, About). All
/// three are created lazily on demand — the OS cannot resurface them
/// from saved state, and menu-driven opens land here rather than in
/// AppDelegate so the delegate stays a thin `NSApplicationDelegate`
/// shell around the composition root.
///
/// Retain topology: parent → child is strong (via `childCoordinators`
/// plus the typed slot); child → parent is weak (via the
/// `*CoordinatorParent` protocols). A child never removes itself —
/// on flow end it reports up via delegate and the parent releases the
/// slot + calls `removeChild(_:)`.
@MainActor
final class AppCoordinator: Coordinator,
    MainWindowCoordinatorParent,
    SettingsWindowCoordinatorParent,
    AboutWindowCoordinatorParent
{
    let appContext: AppContext
    var childCoordinators: [Coordinator] = []

    private var mainWindowCoordinator: MainWindowCoordinator?
    private var settingsCoordinator: SettingsWindowCoordinator?
    private var aboutCoordinator: AboutWindowCoordinator?

    init(appContext: AppContext) {
        self.appContext = appContext
    }

    func start() {
        let coordinator = MainWindowCoordinator(appContext: appContext, parent: self)
        mainWindowCoordinator = coordinator
        addChild(coordinator)
        coordinator.start()
    }

    /// Dock-icon reopen path: NSApplication asks whether we want to
    /// respond to a click when no windows are visible. If the main
    /// coordinator is still around, ask it to re-front its window;
    /// otherwise rebuild the whole flow from scratch.
    func reopenMainWindow() {
        if mainWindowCoordinator == nil {
            start()
        } else {
            mainWindowCoordinator?.showMainWindow()
        }
    }

    /// App > Settings… / ⌘, handler. Idempotent — a repeat call while
    /// the window is already open just re-fronts it.
    func showSettings() {
        if settingsCoordinator == nil {
            let coordinator = SettingsWindowCoordinator(parent: self)
            settingsCoordinator = coordinator
            addChild(coordinator)
        }
        settingsCoordinator?.start()
    }

    /// App > About ccterm handler. Same shape as `showSettings()`.
    func showAbout() {
        if aboutCoordinator == nil {
            let coordinator = AboutWindowCoordinator(parent: self)
            aboutCoordinator = coordinator
            addChild(coordinator)
        }
        aboutCoordinator?.start()
    }

    /// Find > Find in Transcript (⌘F). Routed through the main window's
    /// coordinator so the search-field focus request travels the same
    /// path any per-window bus would.
    func requestSearchFocus() {
        mainWindowCoordinator?.requestSearchFocus()
    }

    // MARK: - MainWindowCoordinatorParent

    func mainWindowCoordinatorDidFinish(_ coordinator: MainWindowCoordinator) {
        mainWindowCoordinator = nil
        removeChild(coordinator)
    }

    // MARK: - SettingsWindowCoordinatorParent

    func settingsWindowCoordinatorDidFinish(_ coordinator: SettingsWindowCoordinator) {
        settingsCoordinator = nil
        removeChild(coordinator)
    }

    // MARK: - AboutWindowCoordinatorParent

    func aboutWindowCoordinatorDidFinish(_ coordinator: AboutWindowCoordinator) {
        aboutCoordinator = nil
        removeChild(coordinator)
    }

    nonisolated deinit {}
}

import AppKit

/// Owns the placeholder Settings window's flow. Held by `AppCoordinator`
/// while the window is on screen; the coordinator's own weak parent
/// receives a "flow ended" report on window close and removes it from
/// its `childCoordinators` array, releasing the window controller.
///
/// The strong ref chain — `AppCoordinator (parent) → SettingsWindowCoordinator
/// (child) → SettingsPlaceholderWindowController` — is broken by the parent
/// dropping the child; only then does the placeholder controller release
/// its `NSWindow`. The child holds `parent` as `weak` (via the completion
/// delegate) so there is no cycle.
@MainActor
final class SettingsWindowCoordinator: Coordinator {
    weak var parent: SettingsWindowCoordinatorParent?
    var childCoordinators: [Coordinator] = []

    private var windowController: SettingsPlaceholderWindowController?

    init(parent: SettingsWindowCoordinatorParent) {
        self.parent = parent
    }

    func start() {
        if let existing = windowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = SettingsPlaceholderWindowController()
        controller.closeDelegate = self
        windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated deinit {}
}

/// Upward channel the coordinator uses to report flow end. The parent
/// (`AppCoordinator`) removes the child from its `childCoordinators`
/// array in response, which releases every window-scope object.
@MainActor
protocol SettingsWindowCoordinatorParent: AnyObject {
    func settingsWindowCoordinatorDidFinish(
        _ coordinator: SettingsWindowCoordinator)
}

extension SettingsWindowCoordinator: SettingsPlaceholderWindowCloseDelegate {
    func settingsPlaceholderWindowWillClose(
        _ controller: SettingsPlaceholderWindowController
    ) {
        windowController = nil
        parent?.settingsWindowCoordinatorDidFinish(self)
    }
}

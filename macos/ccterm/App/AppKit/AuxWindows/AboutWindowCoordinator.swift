import AppKit

/// Owns the placeholder About window's flow. Mirrors
/// `SettingsWindowCoordinator`.
@MainActor
final class AboutWindowCoordinator: Coordinator {
    weak var parent: AboutWindowCoordinatorParent?
    var childCoordinators: [Coordinator] = []

    private var windowController: AboutPlaceholderWindowController?

    init(parent: AboutWindowCoordinatorParent) {
        self.parent = parent
    }

    func start() {
        if let existing = windowController {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = AboutPlaceholderWindowController()
        controller.closeDelegate = self
        windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated deinit {}
}

@MainActor
protocol AboutWindowCoordinatorParent: AnyObject {
    func aboutWindowCoordinatorDidFinish(_ coordinator: AboutWindowCoordinator)
}

extension AboutWindowCoordinator: AboutPlaceholderWindowCloseDelegate {
    func aboutPlaceholderWindowWillClose(
        _ controller: AboutPlaceholderWindowController
    ) {
        windowController = nil
        parent?.aboutWindowCoordinatorDidFinish(self)
    }
}

import Foundation

/// Minimal coordinator protocol per the root CLAUDE.md § Coordinator &
/// navigation. Parent-strong / child-weak retain topology is enforced
/// at the callsite: `addChild(_:)` places the child in the parent's
/// `childCoordinators` array (strong); the child holds its `parent` as
/// `weak var`. `removeChild(_:)` breaks the strong edge.
///
/// Concrete coordinators (`AppCoordinator`, `MainWindowCoordinator`,
/// `DetailFlowCoordinator`, `SettingsWindowCoordinator`,
/// `AboutWindowCoordinator`) conform. They start their flow in
/// `start()`; end-of-flow is signaled up via a delegate/closure they
/// each define — the parent calls `removeChild` in response, so a child
/// never removes itself.
@MainActor
protocol Coordinator: AnyObject {
    /// Child flows this coordinator has started and still owns. Parent
    /// **strong** ref keeps the child alive; the child weakly refers
    /// back through its own `parent` field.
    var childCoordinators: [Coordinator] { get set }

    /// Kick off the flow. Called by the parent exactly once, right
    /// after `addChild(_:)`. Concrete coordinators may treat a repeat
    /// call as "re-front" (see `SettingsWindowCoordinator`) or as a
    /// programmer error (see `MainWindowCoordinator`) — the protocol
    /// itself makes no guarantee.
    func start()
}

extension Coordinator {
    /// Insert `child` into `childCoordinators` (strong retain). Does
    /// **not** call `child.start()` — the caller is responsible for
    /// starting the child, so "add" and "kick off" stay two separate,
    /// visible operations. This lets one call site both re-front an
    /// already-owned coordinator and start a freshly-added one via the
    /// same `.start()` line (see `AppCoordinator.showSettings()`),
    /// without the risk of double-starting the fresh one.
    func addChild(_ child: Coordinator) {
        childCoordinators.append(child)
    }

    /// Break the strong edge to `child`. Called by the parent when
    /// the child reports flow-end (via its dedicated delegate/closure).
    /// Safe when the child isn't in the array (no-op).
    func removeChild(_ child: Coordinator) {
        childCoordinators.removeAll { $0 === child }
    }
}

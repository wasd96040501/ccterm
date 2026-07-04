import AppKit

/// "User picked something in the sidebar" — the one semantic event the
/// sidebar reports upward. Per CLAUDE.md's "VC reports semantic events;
/// Coordinator decides routing" rule, the sidebar does not write into
/// the `SelectionStore` itself; it hands the selection value to its
/// delegate (the `MainWindowCoordinator`), which is the one place that
/// decides what routing implication a selection has and mutates the
/// store as part of that decision.
///
/// The sidebar's `selectionDelegate` is a **weak `var`** assigned by the
/// coordinator *after* `SidebarViewController.init` — Swift init rules
/// forbid passing `self` before every stored property is initialized, so
/// the delegate cannot be a non-optional init parameter. The window is
/// still off-screen at that point, so no user interaction can race with
/// the assignment.
///
/// The sidebar's view→model highlight sync (i.e. selection changing
/// elsewhere programmatically → sidebar row highlight follows) rides a
/// separate channel: the sidebar subscribes to `SelectionStore.$selection`
/// via Combine. That's a display-derivation subscription, not a routing
/// input.
@MainActor
protocol SidebarSelectionDelegate: AnyObject {
    func sidebar(
        _ sidebar: SidebarViewController,
        didSelect selection: MainSelection
    )
}

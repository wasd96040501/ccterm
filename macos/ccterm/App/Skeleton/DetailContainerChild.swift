import AppKit

/// A detail child the container VC can ask to release its per-attach
/// resources before removal. `DetailContainerViewController.setChild(_:_:)`
/// calls `prepareForRemoval()` on the outgoing child **before** it's
/// removed from the tree — deterministic teardown of subscriptions,
/// tasks, and observer registrations, per the root CLAUDE.md § Controllers
/// & containment.
///
/// Every VC that can be mounted in the detail slot conforms — including
/// placeholder VCs (whose implementation is a no-op) — so the container's
/// swap loop can treat them uniformly.
@MainActor
protocol DetailContainerChild: NSViewController {
    func prepareForRemoval()
}

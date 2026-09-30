import AppKit
import ExactListCore

/// Before or after the load point (SPEC L3–L6, V5).
///
/// An enum, so the loaded state's geometry can't be read before it exists, and
/// what was stored before loading can't outlive the load.
enum ListPhase {

    /// Before the load point. Updates are dropped (L5); the last scroll request
    /// is kept, to be applied at the load (L6).
    case waiting(pendingScroll: PendingScroll?)

    /// From the load point on.
    case loaded

    /// A scroll requested before the load point (L5).
    enum PendingScroll: Equatable {
        case toVisible(row: Int)
        case to(row: Int, position: NSCollectionView.ScrollPosition)
    }
}

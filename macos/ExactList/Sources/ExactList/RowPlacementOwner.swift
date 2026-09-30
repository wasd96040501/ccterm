import AppKit

/// What `RowPlacement` needs from the list: views for rows arriving, and where
/// to report views leaving (SPEC P2, P3).
@MainActor
protocol RowPlacementOwner: AnyObject {

    /// The delegate's view for `row` (P2).
    func placement(_ placement: RowPlacement, viewForRow row: Int) -> NSView

    /// U6: the delegate's view for mounted row `row`, which shows `view`. That
    /// view is offered back through the pool first; if another comes back, the
    /// delegate hears `didRemove` for it.
    func placement(_ placement: RowPlacement, reloadingRow row: Int, showing view: NSView) -> NSView

    /// The delegate's `didRemove`, then the pool (P3).
    func placement(_ placement: RowPlacement, didRemove view: NSView, forRow row: Int)
}

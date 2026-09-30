import AppKit

/// What `ListScrollView` reports: that it tiled, and so its clip view may have
/// changed width or height (SPEC W1, V1, V2).
@MainActor
protocol ListScrollViewDelegate: AnyObject {

    /// `tile()` ran. The clip view's frame and insets are final for this pass,
    /// and no row has been displayed at them yet.
    func scrollViewDidTile(_ scrollView: ListScrollView)
}

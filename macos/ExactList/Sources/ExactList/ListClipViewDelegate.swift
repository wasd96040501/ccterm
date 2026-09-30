import AppKit

/// What `ListClipView` reports: every change of the offset, from any cause
/// (SPEC P1, A8).
@MainActor
protocol ListClipViewDelegate: AnyObject {

    /// The bounds origin changed. The list mounts against the new `P` before
    /// returning, and re-evaluates tail following.
    func clipViewDidScroll(_ clipView: ListClipView)
}

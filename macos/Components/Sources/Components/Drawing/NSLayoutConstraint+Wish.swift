import AppKit

extension NSLayoutConstraint.Priority {
    /// A size a view would like but that never sizes what holds it: under the
    /// 250 a split view holds its panes at (`NSSplitViewItem.holdingPriority`)
    /// and the 500 a window keeps its size at, so neither a divider nor the
    /// window's edge moves for it; every required limit wins over it. The views
    /// inside what wishes hug at less, so they never pull it narrower. A wish
    /// any stronger takes the pane's width from the split.
    public static let wish = NSLayoutConstraint.Priority(240)
}

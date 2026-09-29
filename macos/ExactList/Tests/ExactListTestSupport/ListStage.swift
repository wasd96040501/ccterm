import AppKit
import ExactList

/// A real window, off screen, to mount a list in: the pattern of the app's
/// `cctermTests/Harness/AppKitStage`, which this package can't import.
///
/// The window sits at (−30 000, −30 000) with near-zero alpha, so the window
/// server still composites it and presentation layers are real. Every entry
/// point drives AppKit the way the app would: frames through the window,
/// a divider through `NSSplitView`, time through the run loop.
@MainActor
public final class ListStage {

    public let window: NSWindow

    /// The window's content view. The list, or the split holding it, goes in it.
    public var rootView: NSView { window.contentView! }

    /// An empty window of `size`, not yet holding anything.
    public init(size: NSSize) {
        fatalError("unimplemented: test support")
    }

    /// Adds `list` to fill the window, with Auto Layout, and runs the run loop
    /// until layout settles.
    public func mount(_ list: ExactListView) async {
        fatalError("unimplemented: test support")
    }

    /// Puts `tableView` in an `NSScrollView` configured like ExactList's own
    /// (L11), fills the window with it, and settles. It returns the scroll view.
    /// With `layOutFirst` false the table is wired and reloaded before the
    /// first layout, which is the order the §2 setup characterization needs.
    public func mountTable(_ tableView: NSTableView, layOutFirst: Bool) async -> NSScrollView {
        fatalError("unimplemented: test support")
    }

    /// Puts `list` in the right pane of an `NSSplitView` whose left pane is
    /// `leftWidth` wide, so tests can move the divider (W1).
    public func mountInSplit(_ list: ExactListView, leftWidth: CGFloat) async {
        fatalError("unimplemented: test support")
    }

    /// Moves the split's divider, animated through `animator()` or not, and
    /// returns once it has arrived.
    public func moveDivider(to position: CGFloat, animated: Bool) async {
        fatalError("unimplemented: test support")
    }

    /// Resizes the window's content, as a user's resize would.
    public func setContentSize(_ size: NSSize) async {
        fatalError("unimplemented: test support")
    }

    /// Removes `list` from the window, keeping it alive (L8).
    public func unmount(_ list: ExactListView) {
        fatalError("unimplemented: test support")
    }

    /// Runs the main run loop until no layout is pending and one more turn has
    /// passed.
    public func settle() async {
        fatalError("unimplemented: test support")
    }

    /// Runs the run loop until `condition` holds, or fails after `timeout`.
    public func drain(until condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        fatalError("unimplemented: test support")
    }

    /// Closes the window.
    public func teardown() {
        fatalError("unimplemented: test support")
    }
}

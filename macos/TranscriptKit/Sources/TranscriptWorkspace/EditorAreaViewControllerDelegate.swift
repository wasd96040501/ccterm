import AppKit

/// What an editor area tells its host. Every requirement has a default
/// implementations, the way `NSSplitViewDelegate`'s optional methods are optional.
@MainActor
public protocol EditorAreaViewControllerDelegate: AnyObject {

    /// The view controller the reader is working in changed: another tab was
    /// selected, the other editor was clicked or took the focus, or the tab that
    /// was active closed. `nil` once no editor has a tab.
    ///
    /// What a host hangs window-level controls on — a tool that acts on "the
    /// current editor" reads `activeViewController` when it is used, and redraws
    /// whatever it shows about it when this arrives.
    func editorArea(
        _ editorArea: EditorAreaViewController, didActivate viewController: NSViewController?)

    /// A tab is about to close, and its view controller with it.
    ///
    /// The deterministic moment to stop what the tab started — a timer, a stream,
    /// a subscription — rather than waiting for `deinit`, whose timing nothing
    /// promises. Not called when a tab moves to the other editor: it is the same
    /// tab, still open.
    func editorArea(
        _ editorArea: EditorAreaViewController, willClose viewController: NSViewController)

    /// Something of a type registered with `registerForDraggedTypes(_:)` was
    /// dropped on the area: the tab it opens, or `nil` to refuse it. Where the
    /// tab goes follows the drop — as a dragged tab's does.
    func editorArea(
        _ editorArea: EditorAreaViewController, tabViewItemForDrop draggingInfo: NSDraggingInfo
    ) -> NSTabViewItem?
}

extension EditorAreaViewControllerDelegate {

    public func editorArea(
        _ editorArea: EditorAreaViewController, didActivate viewController: NSViewController?
    ) {}

    public func editorArea(
        _ editorArea: EditorAreaViewController, willClose viewController: NSViewController
    ) {}

    public func editorArea(
        _ editorArea: EditorAreaViewController, tabViewItemForDrop draggingInfo: NSDraggingInfo
    ) -> NSTabViewItem? { nil }
}

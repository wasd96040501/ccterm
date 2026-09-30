import AppKit

/// What an editor tells, and asks of, the area it is in: everything that
/// crosses editors or reaches the host. The area is the only implementer; an
/// editor never names it, so the dependency runs one way, parent to child.
@MainActor
protocol EditorGroupViewControllerDelegate: AnyObject {

    /// The reader acted in `group` — clicked one of its tabs, or dropped
    /// something into it — so it is the editor they are working in.
    func editorGroupDidRequestActivation(_ group: EditorGroupViewController)

    /// Every change to `group`'s tabs ends here, since which editor is active,
    /// or how many there are, may have moved with it.
    func editorGroupDidChangeTabs(_ group: EditorGroupViewController)

    /// A tab of `group` is about to close, and its view controller with it.
    func editorGroup(_ group: EditorGroupViewController, willClose viewController: NSViewController)

    /// A new tab for something `group`'s history goes back or forward to, or
    /// `nil` if it can't be shown any more.
    func editorGroup(
        _ group: EditorGroupViewController, tabViewItemWithIdentifier identifier: AnyHashable
    ) -> NSTabViewItem?

    /// The tab a drop from outside the editors opens, or `nil` to refuse it.
    func editorGroup(
        _ group: EditorGroupViewController, tabViewItemForDrop draggingInfo: NSDraggingInfo
    ) -> NSTabViewItem?

    /// Where `group` is among the editors.
    func position(of group: EditorGroupViewController) -> EditorGroupViewController.Position

    /// Moves the tab at `index` of `source` into `group` at `position`, selected
    /// there, with `group` made active. Answers where it landed.
    func editorGroup(
        _ group: EditorGroupViewController, moveTabAt index: Int, of source: EditorGroupViewController,
        to position: Int
    ) -> Int

    /// Moves the tab at `index` of `group` to the other editor, opening one on
    /// the right if there is only this one.
    func editorGroup(_ group: EditorGroupViewController, didRequestMovingTabToOtherGroupAt index: Int)

    /// Opens a second editor on the right of `group` showing `item`.
    func editorGroup(_ group: EditorGroupViewController, didRequestNewGroupWith item: NSTabViewItem)
}

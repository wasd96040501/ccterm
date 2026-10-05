import DisplayModels
import Foundation

/// What the New view reports: choices about where Claude works, and the one
/// thing it asks — the branch menu's rows, which its owner filters. The
/// settings are the composer's, reported by it.
@MainActor
public protocol NewSessionViewControllerDelegate: AnyObject {
    /// A folder from *Recent*, or from *Choose Folder…* (⌘O)'s open panel.
    func newSessionViewController(_ newSessionViewController: NewSessionViewController, didChooseFolder url: URL)
    /// The *Use a new worktree* checkbox.
    func newSessionViewControllerDidToggleWorktree(_ newSessionViewController: NewSessionViewController)
    /// The branch menu for what is typed in its filter, asked each time the
    /// menu opens, the filter changes or the view is shown anew; `nil` when
    /// there is no branch to choose.
    func newSessionViewController(
        _ newSessionViewController: NewSessionViewController, branchMenuMatching query: String
    ) -> NewSessionBranchMenu?
    /// An item of that menu, by the `id` it was given.
    func newSessionViewController(
        _ newSessionViewController: NewSessionViewController, didChooseBranchItem id: AnyHashable)
}

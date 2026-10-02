import AppKit

/// What the New view reports: choices about where Claude works. The settings
/// are the composer's, reported by it.
@MainActor
protocol NewSessionViewControllerDelegate: AnyObject {
    /// A folder from *Recent*, or from *Choose Folder…* (⌘O)'s open panel.
    func newSessionViewController(_ newSessionViewController: NewSessionViewController, didChooseFolder url: URL)
    /// A branch, or a pull request typed as `#N`, from the branch popover.
    func newSessionViewController(
        _ newSessionViewController: NewSessionViewController, didChooseBranch branch: NewSessionDraft.Branch)
    /// The Worktree toggle.
    func newSessionViewControllerDidToggleWorktree(_ newSessionViewController: NewSessionViewController)
}

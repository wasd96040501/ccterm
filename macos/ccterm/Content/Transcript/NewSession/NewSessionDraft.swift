import Foundation

/// A New tab's choices before Send (design 08 *The New view*): the folder,
/// the branch and whether to work in a worktree, and the settings the
/// composer chose. A value the session tab holds as the New tab's state; its
/// rules — what one choice does to the others — are its mutating methods, and
/// `launch` is what Send hands the store.
nonisolated struct NewSessionDraft: Equatable, Sendable {
    /// The folder Claude will work in; `nil` until one is known (no recent
    /// project, nothing chosen) — Send is then disabled.
    private(set) var folder: URL?
    /// The branch chosen in the pop-up; `nil` is the checked-out one.
    private(set) var branch: Branch?
    private(set) var usesWorktree = false
    var settings: SessionSettings

    /// What the branch pop-up chose.
    enum Branch: Equatable, Sendable {
        case named(String)
        /// `#N` typed in the filter: checked out in a new worktree.
        case pullRequest(Int)
    }

    init(folder: URL?, settings: SessionSettings) {
        self.folder = folder
        self.settings = settings
    }

    /// Another folder: the branch goes back to its checkout, Worktree off.
    mutating func choose(folder: URL) {
        // TODO(fill D)
        self.folder = folder
    }

    /// A branch from the pop-up. A pull request turns Worktree on.
    mutating func choose(branch: Branch, in repository: RepositoryState) {
        // TODO(fill D)
        self.branch = branch
    }

    /// Toggles Worktree. Off again, a branch that can't be had in place
    /// (checked out elsewhere, uncommitted work here, a pull request) goes
    /// back to the checkout's.
    mutating func toggleWorktree(in repository: RepositoryState) {
        // TODO(fill D)
        usesWorktree.toggle()
    }

    /// The launch Send makes of the draft: `nil` without a folder. `repository`
    /// is `nil` for a folder that isn't a git repository (always in place).
    func launch(in repository: RepositoryState?) -> SessionLaunch? {
        // TODO(fill D): map branch + worktree onto `Checkout` (head for the
        // checked-out branch, defaultBranch for origin's default, branch(_:) else).
        guard let folder else { return nil }
        return SessionLaunch(folder: folder, checkout: .inPlace(switchTo: nil), settings: settings)
    }
}

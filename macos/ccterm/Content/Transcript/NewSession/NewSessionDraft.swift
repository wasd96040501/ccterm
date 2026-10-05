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
    enum Branch: Hashable, Sendable {
        case named(String)
        /// `#N` typed in the filter: checked out in a new worktree.
        case pullRequest(Int)
    }

    init(folder: URL?, settings: SessionSettings) {
        self.folder = folder
        self.settings = settings
    }

    /// Another folder: the branch goes back to its checkout, Worktree off.
    /// The same folder again changes nothing.
    mutating func choose(folder: URL) {
        guard folder != self.folder else { return }
        self.folder = folder
        branch = nil
        usesWorktree = false
    }

    /// A branch from the pop-up. A pull request turns Worktree on. The
    /// checked-out branch is the draft's `nil`. In place, a branch git would
    /// refuse or that would carry uncommitted work along can't be chosen (the
    /// pop-up greys it); the choice is then ignored.
    mutating func choose(branch: Branch, in repository: RepositoryState) {
        switch branch {
        case .pullRequest:
            self.branch = branch
            usesWorktree = true
        case .named(let name):
            if !usesWorktree, !BranchRules.canSwitchInPlace(to: name, in: repository) { return }
            self.branch = name == repository.branch ? nil : branch
        }
    }

    /// Toggles Worktree. Off again, a branch that can't be had in place
    /// (checked out elsewhere, uncommitted work here, a pull request) goes
    /// back to the checkout's.
    mutating func toggleWorktree(in repository: RepositoryState) {
        usesWorktree.toggle()
        guard !usesWorktree else { return }
        switch branch {
        case .pullRequest: branch = nil
        case .named(let name) where !BranchRules.canSwitchInPlace(to: name, in: repository): branch = nil
        case .named, nil: break
        }
    }

    /// The launch Send makes of the draft: `nil` without a folder. `repository`
    /// is `nil` for a folder that isn't a git repository (always in place).
    ///
    /// A worktree branches from `head` for the checked-out branch, from
    /// origin's default branch for that one, and from the named branch
    /// otherwise; in place, a branch other than the checked-out one is what
    /// the checkout switches to — a remote branch by its local name, which
    /// `git switch` creates tracking it.
    func launch(in repository: RepositoryState?) -> SessionLaunch? {
        guard let folder else { return nil }
        return SessionLaunch(folder: folder, checkout: checkout(in: repository), settings: settings)
    }

    private func checkout(in repository: RepositoryState?) -> Checkout {
        guard let repository else { return .inPlace(switchTo: nil) }
        guard usesWorktree else {
            guard case .named(let name) = branch, name != repository.branch else {
                return .inPlace(switchTo: nil)
            }
            return .inPlace(switchTo: BranchRules.localName(of: name, in: repository))
        }
        switch branch {
        case .pullRequest(let number):
            return .pullRequest(number)
        case nil:
            return .worktree(base: .head)
        case .named(let name):
            if name == repository.branch { return .worktree(base: .head) }
            if BranchRules.isDefaultBranch(name, in: repository) { return .worktree(base: .defaultBranch) }
            return .worktree(base: .branch(name))
        }
    }
}

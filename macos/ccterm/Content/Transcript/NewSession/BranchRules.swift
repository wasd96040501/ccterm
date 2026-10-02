import Foundation

/// What a repository allows of a branch choice in the New view (design 08
/// *What the branch means depends on Worktree*) — the questions the draft's
/// rules and the model's words both ask.
nonisolated enum BranchRules {
    /// Whether `git switch` can take the work to `name` here: not the branch
    /// another worktree has, and not away from uncommitted changes. The
    /// checked-out branch is always the one it is.
    static func canSwitchInPlace(to name: String, in repository: RepositoryState) -> Bool {
        if name == repository.branch { return true }
        return !repository.branchesCheckedOutElsewhere.contains(name) && !repository.hasUncommittedChanges
    }

    /// Why `name` can't be had in place, or `nil`.
    enum Refusal: Equatable, Sendable {
        case checkedOutElsewhere
        case uncommittedChanges
    }

    static func refusal(of name: String, in repository: RepositoryState) -> Refusal? {
        if name == repository.branch { return nil }
        if repository.branchesCheckedOutElsewhere.contains(name) { return .checkedOutElsewhere }
        if repository.hasUncommittedChanges { return .uncommittedChanges }
        return nil
    }

    /// `release/1.4` for the remote branch `origin/release/1.4`; a local
    /// branch is itself.
    static func localName(of name: String, in repository: RepositoryState) -> String {
        guard repository.remoteBranches.contains(name), let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    /// Whether `name` is origin's default branch, local or as `origin/<name>`.
    static func isDefaultBranch(_ name: String, in repository: RepositoryState) -> Bool {
        guard let defaultBranch = repository.defaultBranch else { return false }
        return name == defaultBranch || name == "origin/\(defaultBranch)"
    }
}

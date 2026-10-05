import Foundation

/// A folder's repository as the New view's branch row reads it (design 08
/// *Branch and Worktree*). `nil` where the folder is in no repository — the
/// row then says *Not a Git repository*.
nonisolated struct RepositoryState: Sendable, Equatable {
    /// The repository's top: the folder's own checkout (a worktree's root when
    /// the folder is inside one).
    var root: URL
    /// The checked-out branch; `nil` when HEAD is detached.
    var branch: String?
    /// Local branches, most recently committed first.
    var localBranches: [String]
    /// Remote branches without a local twin (`origin/release/1.4`).
    var remoteBranches: [String]
    /// Branches checked out in another worktree: git won't switch to them here.
    var branchesCheckedOutElsewhere: Set<String>
    /// Uncommitted changes: a switch in place would carry them along.
    var hasUncommittedChanges: Bool
    /// Origin's default branch (`main`), what a fresh worktree branches from;
    /// `nil` without a remote.
    var defaultBranch: String?
}

/// Where a launch runs once its workspace is made: the folder the CLI starts
/// in and what it is told.
nonisolated struct PreparedWorkspace: Sendable, Equatable {
    /// The CLI's `cwd`: the folder, or the worktree ccterm made.
    var workingDirectory: URL
    /// `--worktree <name>` (the CLI makes it), or `nil`.
    var worktreeName: String?
    /// `worktree.baseRef` for `--settings` (`"head"`), or `nil`.
    var worktreeBaseRef: String?
    /// Where the CLI will work — the folder whose project directory holds the
    /// transcript: `<repo>/.claude/worktrees/<name>` for a worktree (the CLI
    /// keys the transcript on it), else `workingDirectory`.
    var sessionDirectory: URL
}

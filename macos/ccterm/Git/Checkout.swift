import Foundation

/// Where in a folder's repository a session works (design 08 *Branch and
/// Worktree*). A folder that isn't a git repository is always
/// `.inPlace(switchTo: nil)`.
nonisolated enum Checkout: Sendable, Equatable {
    /// The folder itself; `switchTo` a branch other than the checked-out one
    /// is checked out with `git switch` before the CLI starts — ccterm's step,
    /// not the CLI's.
    case inPlace(switchTo: String?)
    /// A new worktree under `.claude/worktrees/<name>`, branched from `base`.
    case worktree(base: Base)
    /// The CLI's own `--worktree #N`: the pull request checked out in a new
    /// worktree, `pr-N`.
    case pullRequest(Int)

    /// Where a new worktree branches from. The CLI's `--worktree` starts only
    /// from `head` (with `--settings {"worktree":{"baseRef":"head"}}`) or
    /// origin's default branch; any other branch is `git worktree add` by ccterm.
    enum Base: Sendable, Equatable {
        case head
        case defaultBranch
        case branch(String)
    }
}

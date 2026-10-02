import Foundation

/// The git a New tab needs: what a folder's repository has (its branches,
/// which are checked out elsewhere, whether it has uncommitted work) and the
/// steps a launch takes before the CLI starts — `git switch` in place, or
/// `git worktree add` for a worktree from a branch the CLI can't start from.
/// Spawns `git`; `GitService` stays the read-only follower of a branch.
///
/// Every call runs off the caller's actor.
struct BranchService: Sendable {
    /// What `folder`'s repository has; `nil` when it is in none.
    @concurrent
    nonisolated func repository(at folder: URL) async -> RepositoryState? {
        // TODO(fill B): git rev-parse / for-each-ref / worktree list / status --porcelain. BranchServiceTests on a temp repo.
        nil
    }

    /// Makes `checkout` real in `folder` and says where the CLI runs:
    /// `.inPlace(switchTo:)` switches first; `.worktree(base: .head)` and
    /// `.defaultBranch` are the CLI's own `--worktree` (with `baseRef: head`
    /// for the first); `.worktree(base: .branch)` is `git worktree add -b
    /// <name> .claude/worktrees/<name> <branch>` here; `.pullRequest(N)` is
    /// the CLI's `--worktree #N`, named `pr-N`. ccterm names every worktree
    /// (`name`), so the transcript's URL is known before the CLI starts.
    /// Throws git's refusal in words.
    @concurrent
    nonisolated func prepare(
        _ checkout: Checkout, in folder: URL, name: String
    ) async throws -> PreparedWorkspace {
        // TODO(fill B)
        PreparedWorkspace(
            workingDirectory: folder, worktreeName: nil, worktreeBaseRef: nil, sessionDirectory: folder)
    }

    /// A fresh worktree name, in the CLI's own style (`quiet-otter`).
    nonisolated static func makeWorktreeName() -> String {
        // TODO(fill B)
        "worktree-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

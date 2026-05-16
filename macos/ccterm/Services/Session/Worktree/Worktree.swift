import Foundation

/// Identity of a git worktree. Value type, immutable; git-layer dynamic
/// state (current branch, HEAD) is not tracked here — the caller
/// (SessionHandle2 / SessionRecord) holds it.
///
/// Mirrors the `worktree` object claude.app's `p0r.createWorktree`
/// produces (`{ name, path, baseRepo, sourceBranch, ... }`, slice lines
/// 143-151), trimmed of sessionId / createdAt and other runtime fields —
/// SessionRecord owns those in ccterm.
///
/// Typical flow: `Worktree.create(from:)` → SessionHandle2 persists
/// path/name to db → LLM-generated rename → `wt.renameBranch(to:)` →
/// `wt.remove()` on archive → `Worktree.restore(at:baseRepo:branch:)` on
/// unarchive.
struct Worktree: Equatable, Hashable {

    /// Worktree absolute path.
    let path: String

    /// `<adj>-<sci>-<hex6>`. Doubles as the worktree directory name and
    /// the initial branch name. LLM rename later changes the git-layer
    /// branch, but `name` / `path` stay the same.
    let name: String

    /// Normalized main repo root (an input worktree path is resolved up
    /// to the main repo).
    let baseRepo: String

    /// Source branch the worktree was created from. nil means the
    /// baseRepo HEAD. Instances returned by `locate` / `restore` may set
    /// this to nil (cannot back-derive or don't care).
    let sourceBranch: String?

    // MARK: - Error

    enum Error: Swift.Error, LocalizedError {
        /// Input is not a git repository.
        case notGitRepository(path: String)
        /// Base is detached HEAD and no sourceBranch was provided.
        case detachedHeadWithoutSource
        /// `remove()` refused to delete a path outside the managed dir
        /// (safety check).
        case pathOutsideManagedDir(path: String)
        /// Parent directory creation failed.
        case directoryCreationFailed(path: String, underlying: String)
        /// Underlying git command failed. `isBranchConflict == true` means
        /// a conflict (rename hit 10 attempts, or create hit 5 regenerate
        /// attempts).
        case git(stderr: String, isBranchConflict: Bool)

        var errorDescription: String? {
            switch self {
            case .notGitRepository(let path):
                return "Not a git repository: \(path)"
            case .detachedHeadWithoutSource:
                return "Base repo is detached HEAD and no sourceBranch provided"
            case .pathOutsideManagedDir(let path):
                return "Refusing to operate on path outside managed worktree directory: \(path)"
            case .directoryCreationFailed(let path, let underlying):
                return "Failed to create worktree directory at \(path): \(underlying)"
            case .git(let stderr, _):
                return "Git worktree command failed: \(stderr)"
            }
        }
    }
}

// MARK: - Locate

extension Worktree {

    /// Reverse-look up a worktree identity from any git path; returns nil
    /// for non-worktrees or paths outside the managed dir. Mirrors
    /// claude.app `p0r.detectWorktreeInfo` (slice lines 187-205).
    ///
    /// - `gitDir` (`git rev-parse --git-dir`) must contain
    ///   `/.git/worktrees/` — that's git's own criterion for "this
    ///   checkout is a worktree".
    /// - The path must sit under `<baseRepo>/.claude/worktrees/` (managed
    ///   by this project's `create`). Manually `git worktree add`-ed
    ///   worktrees elsewhere are not recognized, avoiding external
    ///   management conflicts.
    static func locate(at path: String) -> Worktree? {
        guard let gitDir = GitQuery.gitDir(at: path),
            gitDir.contains("/.git/worktrees/"),
            let topLevel = GitQuery.showToplevel(at: path),
            let commonDir = GitQuery.gitCommonDir(at: path)
        else { return nil }

        // baseRepo = dirname(gitCommonDir) — the parent of the main
        // repo's .git. commonDir may be relative; resolve to absolute
        // before dirname.
        let absCommon =
            (commonDir as NSString).isAbsolutePath
            ? commonDir
            : ((path as NSString).appendingPathComponent(commonDir) as NSString).standardizingPath
        let baseRepo = (absCommon as NSString).deletingLastPathComponent

        let managedRoot = (baseRepo as NSString).appendingPathComponent(".claude/worktrees")
        guard isPathInside(topLevel, managedRoot) else { return nil }

        let name = (topLevel as NSString).lastPathComponent
        return Worktree(
            path: topLevel,
            name: name,
            baseRepo: baseRepo,
            sourceBranch: nil
        )
    }

    /// Whether `path` is a descendant of `container`. Symlinks are
    /// resolved first, then prefix-matched (macOS /tmp is a symlink to
    /// /private/tmp, so resolution is required for correctness).
    /// Equivalent to claude.app `isPathInside` (slice lines 68-71).
    static func isPathInside(_ path: String, _ container: String) -> Bool {
        let a = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let b = URL(fileURLWithPath: container).resolvingSymlinksInPath().path
        guard a != b else { return false }
        return a.hasPrefix(b + "/")
    }
}

import Foundation

/// 一个 git worktree 的身份。值类型、不可变；git 层动态状态（当前 branch、HEAD）
/// 不在此类型里追踪——由调用方（SessionHandle2 / SessionRecord）持有。
///
/// 对齐 claude.app `p0r.createWorktree` 产出 `{ name, path, baseRepo, sourceBranch, ... }`
/// 的 `worktree` 对象（slice 行 143-151），裁掉 sessionId / createdAt 等运行态字段
/// —— 那些字段在 ccterm 里由 SessionRecord 追踪。
///
/// 典型流程：`Worktree.create(from:)` → SessionHandle2 把 path/name 落 db →
/// LLM 生成 → `wt.renameBranch(to:)` → archive 时 `wt.remove()` →
/// unarchive 时 `Worktree.restore(at:baseRepo:branch:)`。
struct Worktree: Equatable, Hashable {

    /// Worktree 绝对路径。
    let path: String

    /// `<adj>-<sci>-<hex6>`，同时作为 worktree 目录名与创建时的初始 branch 名。
    /// LLM rename 之后 git 层 branch 会变，但 name / path 不变。
    let name: String

    /// 规范化后的 main repo root（入参若是 worktree 路径会被解析到主仓）。
    let baseRepo: String

    /// 创建时依据的源 branch。nil 表示使用 baseRepo 的 HEAD。
    /// `locate` / `restore` 返回的实例可能填 nil（反查不出或不关心）。
    let sourceBranch: String?

    // MARK: - Error

    enum Error: Swift.Error, LocalizedError {
        /// 入参不是 git 仓库。
        case notGitRepository(path: String)
        /// base 是 detached HEAD 且调用方未提供 sourceBranch。
        case detachedHeadWithoutSource
        /// `remove()` 拒绝删除 managed dir 之外的路径（安全校验）。
        case pathOutsideManagedDir(path: String)
        /// 父目录创建失败。
        case directoryCreationFailed(path: String, underlying: String)
        /// 底层 git 命令失败。`isBranchConflict` 为 true 表示冲突（rename 10 次耗尽、
        /// 或 create 5 次 regenerate 耗尽）。
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

    /// 从任意 git 路径反查 worktree 身份；非 worktree 或不在 managed dir 内返回 nil。
    /// 对齐 claude.app `p0r.detectWorktreeInfo`（slice 行 187-205）。
    ///
    /// - `gitDir`（`git rev-parse --git-dir`）必须包含 `/.git/worktrees/`——这是
    ///   git 认为某 checkout 是 worktree 的判据。
    /// - 路径必须在 `<baseRepo>/.claude/worktrees/` 下（由本项目 `create` 管理）。
    ///   手工 `git worktree add` 到别处的 worktree 不会被识别，避免外部管理冲突。
    static func locate(at path: String) -> Worktree? {
        guard let gitDir = GitQuery.gitDir(at: path),
              gitDir.contains("/.git/worktrees/"),
              let topLevel = GitQuery.showToplevel(at: path),
              let commonDir = GitQuery.gitCommonDir(at: path)
        else { return nil }

        // baseRepo = dirname(gitCommonDir) —— main repo 的 .git 的父。
        // commonDir 可能是相对路径，resolve 成绝对后再 dirname。
        let absCommon = (commonDir as NSString).isAbsolutePath
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

    /// 检查 `path` 是否为 `container` 的子孙。解析 symlink 后做前缀匹配（macOS tmp
    /// 是 /private/tmp 的 symlink，必须先 resolve 才能正确比较）。
    /// 等效 claude.app `isPathInside`（slice 行 68-71）。
    static func isPathInside(_ path: String, _ container: String) -> Bool {
        let a = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let b = URL(fileURLWithPath: container).resolvingSymlinksInPath().path
        guard a != b else { return false }
        return a.hasPrefix(b + "/")
    }
}

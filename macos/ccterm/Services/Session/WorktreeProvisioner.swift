import Foundation

/// Provisions git worktrees for SessionHandle2 with behaviors aligned with
/// Claude.app's `createWorktree` (see `/tmp/claude-worktree-slice.js`):
///
/// 1. `git fetch --prune origin` with throttle + 15s wall-clock timeout (non-fatal)
/// 2. `maybeFastForwardLocalBranch` — 若本地 source branch 落后 origin 且未分叉，`--ff-only` 更新
/// 3. `resolveStartPoint` — 优先 `refs/remotes/origin/<src>`（当 local is-ancestor-of origin 或 local 不存在）
///    否则 `refs/heads/<src>`，否则 raw `<src>`
/// 4. `git worktree add --detach <path> <startPoint>` — branch name 留空，待 LLM 挂载
/// 5. `extensions.worktreeConfig = true` + `core.longpaths = true`
/// 6. inheritHooksPath — 从 base 继承 `core.hooksPath` / `.husky` / `git-common-dir/hooks`
/// 7. 拷贝 `.claude/settings.local.json` 到 worktree
enum WorktreeProvisioner {

    // MARK: - Errors

    enum WorktreeError: Error, LocalizedError {
        case notGitRepository(path: String)
        case detachedHeadWithoutSource
        case directoryCreationFailed(path: String, underlying: String)
        case gitError(stderr: String)

        var errorDescription: String? {
            switch self {
            case .notGitRepository(let path):
                return "Not a git repository: \(path)"
            case .detachedHeadWithoutSource:
                return "Base repo is detached HEAD and no sourceBranch provided"
            case .directoryCreationFailed(let path, let underlying):
                return "Failed to create worktree directory at \(path): \(underlying)"
            case .gitError(let stderr):
                return "Git worktree creation failed: \(stderr)"
            }
        }
    }

    // MARK: - Public API

    /// Create a new detached-HEAD worktree. Branch name is **not** assigned here —
    /// the caller is expected to `checkout -b <branch>` once the LLM returns a name.
    ///
    /// Returns the absolute path to the new worktree.
    static func createDetachedWorktree(
        repoPath: String,
        sourceBranch: String?
    ) throws -> String {
        guard GitUtils.isGitRepository(at: repoPath) else {
            throw WorktreeError.notGitRepository(path: repoPath)
        }

        refreshOriginIfStale(repoPath: repoPath)

        if let src = sourceBranch {
            maybeFastForwardLocalBranch(repoPath: repoPath, branch: src)
        }

        let startPoint = resolveStartPoint(repoPath: repoPath, sourceBranch: sourceBranch)
        guard let startPoint else {
            throw WorktreeError.detachedHeadWithoutSource
        }

        let name = randomWorktreeName()
        let worktreePath = worktreeDir(repoPath: repoPath, name: name)
        let parentDir = (worktreePath as NSString).deletingLastPathComponent

        do {
            try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        } catch {
            throw WorktreeError.directoryCreationFailed(path: parentDir, underlying: error.localizedDescription)
        }

        let createResult = GitUtils.createWorktreeDetached(
            repoPath: repoPath,
            worktreePath: worktreePath,
            baseBranch: startPoint
        )
        if case .failure(let err) = createResult {
            try? FileManager.default.removeItem(atPath: worktreePath)
            throw WorktreeError.gitError(stderr: err.stderr)
        }

        enableWorktreeConfigExtensions(at: worktreePath)
        inheritHooksPath(basePath: repoPath, worktreePath: worktreePath)
        copyLocalSettings(from: repoPath, to: worktreePath)

        return worktreePath
    }

    // MARK: - fetch origin (throttled)

    private static let fetchAttemptStore = FetchAttemptStore()
    private static let fetchStaleThreshold: TimeInterval = 10 * 60  // 10 min（与 Claude.app OOe 对齐）
    private static let fetchTimeoutSeconds: TimeInterval = 15

    /// 只有当 FETCH_HEAD 陈旧（> 10 分钟）且本 app 会话没最近 fetch 过才触发；
    /// 失败不抛，因为 on-disk refs 仍可用。
    private static func refreshOriginIfStale(repoPath: String) {
        if fetchAttemptStore.recentlyAttempted(repoPath, threshold: fetchStaleThreshold) {
            return
        }
        if let age = fetchHeadAge(repoPath: repoPath), age < fetchStaleThreshold {
            return
        }
        fetchAttemptStore.mark(repoPath)
        _ = runGit(
            args: ["fetch", "--prune", "origin"],
            cwd: repoPath,
            timeout: fetchTimeoutSeconds,
            extraEnv: [
                "GCM_INTERACTIVE": "never",
                "GIT_ASKPASS": "",
                "SSH_ASKPASS": "",
                "GIT_SSH_COMMAND": "ssh -o BatchMode=yes",
            ]
        )
    }

    private static func fetchHeadAge(repoPath: String) -> TimeInterval? {
        let gitDir = (repoPath as NSString).appendingPathComponent(".git")
        let fetchHead = (gitDir as NSString).appendingPathComponent("FETCH_HEAD")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fetchHead),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }
        return Date().timeIntervalSince(mtime)
    }

    private final class FetchAttemptStore {
        private let queue = DispatchQueue(label: "WorktreeProvisioner.FetchAttemptStore")
        private var lastAttempts: [String: Date] = [:]

        func recentlyAttempted(_ repo: String, threshold: TimeInterval) -> Bool {
            queue.sync {
                guard let last = lastAttempts[repo] else { return false }
                return Date().timeIntervalSince(last) < threshold
            }
        }

        func mark(_ repo: String) {
            queue.sync { lastAttempts[repo] = Date() }
        }
    }

    // MARK: - maybeFastForwardLocalBranch

    /// 若本地 <branch> 落后 origin/<branch> 且未分叉，用 `update-ref` 或 `merge --ff-only` 更新。
    /// 对齐 Claude.app 的 maybeFastForwardLocalBranch。失败静默，不阻塞主流程。
    private static func maybeFastForwardLocalBranch(repoPath: String, branch: String) {
        let localRef = "refs/heads/\(branch)"
        let originRef = "refs/remotes/origin/\(branch)"

        guard let local = revParse(repoPath: repoPath, ref: localRef),
              let origin = revParse(repoPath: repoPath, ref: originRef),
              local != origin else {
            return
        }
        // 仅当 local is-ancestor-of origin（即 origin 前进，local 没分叉）
        guard isAncestor(repoPath: repoPath, ancestor: localRef, descendant: originRef) else {
            return
        }
        // 看这个 branch 是否已 checked out 到某个 worktree
        let checkoutPath = worktreeCheckoutPath(repoPath: repoPath, localRef: localRef)
        if let wt = checkoutPath {
            _ = runGit(args: ["merge", "--ff-only", originRef], cwd: wt, timeout: 10)
        } else {
            _ = runGit(args: ["update-ref", localRef, origin, local], cwd: repoPath, timeout: 10)
        }
    }

    private static func worktreeCheckoutPath(repoPath: String, localRef: String) -> String? {
        let result = runGit(
            args: ["for-each-ref", "--format=%(worktreepath)", localRef],
            cwd: repoPath,
            timeout: 5
        )
        guard result.exitCode == 0,
              let out = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty else {
            return nil
        }
        return out
    }

    // MARK: - resolveStartPoint

    /// 决定 worktree add 的 start point：
    /// - sourceBranch == nil：用 base 的当前 branch；detached 时返回 nil（调用方报错）
    /// - 优先 origin/<src>：当 origin 存在 && （local 不存在 || local is-ancestor-of origin）
    /// - 否则 local refs/heads/<src>
    /// - 否则 raw <src>
    /// - 都不存在 → nil
    private static func resolveStartPoint(repoPath: String, sourceBranch: String?) -> String? {
        guard let src = sourceBranch else {
            return GitUtils.currentBranch(at: repoPath)
        }
        let originRef = "refs/remotes/origin/\(src)"
        let localRef = "refs/heads/\(src)"
        let originExists = revParse(repoPath: repoPath, ref: originRef) != nil
        let localExists = revParse(repoPath: repoPath, ref: localRef) != nil

        if originExists {
            let preferOrigin = !localExists
                || isAncestor(repoPath: repoPath, ancestor: localRef, descendant: originRef)
            if preferOrigin { return originRef }
        }
        if localExists { return localRef }
        if revParse(repoPath: repoPath, ref: src) != nil { return src }
        return nil
    }

    // MARK: - extensions.worktreeConfig / core.longpaths

    private static func enableWorktreeConfigExtensions(at worktreePath: String) {
        _ = runGit(args: ["config", "extensions.worktreeConfig", "true"], cwd: worktreePath, timeout: 5)
        _ = runGit(args: ["config", "--worktree", "core.longpaths", "true"], cwd: worktreePath, timeout: 5)
    }

    // MARK: - inheritHooksPath

    /// 把 base 的 `core.hooksPath`（若有）、`.husky/`（若有）、或 git-common-dir/hooks（如有
    /// 非 .sample 文件）继承到 worktree 的 `--worktree` config。失败静默。
    private static func inheritHooksPath(basePath: String, worktreePath: String) {
        // 前置：确保 worktreeConfig 已开启（enableWorktreeConfigExtensions 已做，此处幂等）
        _ = runGit(args: ["config", "extensions.worktreeConfig", "true"], cwd: worktreePath, timeout: 5)

        // 1. base 有显式 core.hooksPath？
        let baseHooks = runGit(
            args: ["config", "--type=path", "--get", "core.hooksPath"],
            cwd: basePath,
            timeout: 5
        )
        if baseHooks.exitCode == 0, let out = baseHooks.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
            let absolute = (out as NSString).isAbsolutePath ? out : (basePath as NSString).appendingPathComponent(out)
            let setResult = runGit(
                args: ["config", "--worktree", "core.hooksPath", absolute],
                cwd: worktreePath,
                timeout: 5
            )
            if setResult.exitCode == 0 { return }
        }

        // 2. .husky/
        let husky = (basePath as NSString).appendingPathComponent(".husky")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: husky, isDirectory: &isDir), isDir.boolValue {
            let r = runGit(
                args: ["config", "--worktree", "core.hooksPath", husky],
                cwd: worktreePath,
                timeout: 5
            )
            if r.exitCode == 0 { return }
        }

        // 3. git-common-dir/hooks 有非 .sample 文件？
        let commonDir = runGit(args: ["rev-parse", "--git-common-dir"], cwd: basePath, timeout: 5)
        if commonDir.exitCode == 0, let out = commonDir.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
            let hooksDir = (out as NSString).isAbsolutePath
                ? (out as NSString).appendingPathComponent("hooks")
                : ((basePath as NSString).appendingPathComponent(out) as NSString).appendingPathComponent("hooks")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: hooksDir),
               files.contains(where: { !$0.hasSuffix(".sample") }) {
                _ = runGit(
                    args: ["config", "--worktree", "core.hooksPath", hooksDir],
                    cwd: worktreePath,
                    timeout: 5
                )
            }
        }
    }

    // MARK: - copyLocalSettings

    /// 将 `<base>/.claude/settings.local.json` 拷到 `<worktree>/.claude/settings.local.json`（若存在）。
    /// 与现有 `SessionService.copyLocalSettings` 行为一致。
    private static func copyLocalSettings(from basePath: String, to worktreePath: String) {
        let source = (basePath as NSString).appendingPathComponent(".claude/settings.local.json")
        guard FileManager.default.fileExists(atPath: source) else { return }
        let destDir = (worktreePath as NSString).appendingPathComponent(".claude")
        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let dest = (destDir as NSString).appendingPathComponent("settings.local.json")
        try? FileManager.default.copyItem(atPath: source, toPath: dest)
    }

    // MARK: - Naming

    private static func randomWorktreeName() -> String {
        let suffix = String((0..<8).map { _ in
            "0123456789abcdefghijklmnopqrstuvwxyz".randomElement()!
        })
        return suffix
    }

    private static func worktreeDir(repoPath: String, name: String) -> String {
        let projectName = (repoPath as NSString).lastPathComponent
        let base = (repoPath as NSString).appendingPathComponent(".claude/worktrees")
        let full = (base as NSString).appendingPathComponent("\(name)/\(projectName)")
        return full
    }

    // MARK: - git helpers

    private struct GitResult {
        let exitCode: Int32
        let stdout: String?
        let stderr: String?
    }

    @discardableResult
    private static func runGit(
        args: [String],
        cwd: String,
        timeout: TimeInterval,
        extraEnv: [String: String] = [:]
    ) -> GitResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", cwd] + args
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        proc.environment = env
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            return GitResult(exitCode: -1, stdout: nil, stderr: error.localizedDescription)
        }

        let timeoutItem = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        timeoutItem.cancel()

        return GitResult(
            exitCode: proc.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8),
            stderr: String(data: stderrData, encoding: .utf8)
        )
    }

    private static func revParse(repoPath: String, ref: String) -> String? {
        let r = runGit(args: ["rev-parse", "--verify", "--quiet", ref], cwd: repoPath, timeout: 5)
        guard r.exitCode == 0, let sha = r.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty else {
            return nil
        }
        return sha
    }

    private static func isAncestor(repoPath: String, ancestor: String, descendant: String) -> Bool {
        let r = runGit(
            args: ["merge-base", "--is-ancestor", ancestor, descendant],
            cwd: repoPath,
            timeout: 5
        )
        return r.exitCode == 0
    }
}

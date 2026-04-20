import Foundation

// MARK: - create

extension Worktree {

    /// 从 baseRepo 新建 worktree。对齐 claude.app `p0r.createWorktree`。
    ///
    /// 流程：
    /// 1. `resolveBaseRepo` 规范化（入参若是 worktree → main repo root）
    /// 2. `fetch --prune origin`（throttled，失败非致命）
    /// 3. `maybeFastForwardLocalBranch`（sourceBranch 非 nil 时）
    /// 4. `resolveStartPoint`（origin 优先 / local fallback / raw）
    /// 5. `generateName()`；`worktree add` 因 branch 冲突失败时重抽，最多 5 次
    /// 6. `git worktree add <lfsFlags> -c core.longpaths=true -b <name> <path> <startPoint>`
    /// 7. `extensions.worktreeConfig` + `--worktree core.longpaths`
    /// 8. `inheritHooksPath`
    /// 9. 从**原传入 repoPath**（非规范化后的 baseRepo）拷贝 `.worktreeinclude` /
    ///    `.claude` gitignored 文件（对齐 slice 行 142 `B0r(t, E)` / `Q0r(t, E)`）
    static func create(
        from repoPath: String,
        sourceBranch: String? = nil
    ) throws -> Worktree {
        guard GitUtils.isGitRepository(at: repoPath) else {
            throw Error.notGitRepository(path: repoPath)
        }

        let baseRepo = resolveBaseRepo(repoPath)

        refreshOriginIfStale(baseRepo: baseRepo)
        if let src = sourceBranch {
            maybeFastForwardLocalBranch(baseRepo: baseRepo, branch: src)
        }

        guard let startPoint = resolveStartPoint(baseRepo: baseRepo, sourceBranch: sourceBranch) else {
            throw Error.detachedHeadWithoutSource
        }

        let lfsFlags = lfsFlagsIfUnavailable()

        // 初始名冲突极罕见（2.66 亿空间），兜 5 次。
        let maxNameAttempts = 5
        var lastStderr = ""
        for _ in 0..<maxNameAttempts {
            let name = generateName()
            let path = worktreeDir(baseRepo: baseRepo, name: name)
            let parentDir = (path as NSString).deletingLastPathComponent

            do {
                try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            } catch {
                throw Error.directoryCreationFailed(path: parentDir, underlying: error.localizedDescription)
            }

            // git <lfsFlags> -C <baseRepo> -c core.longpaths=true worktree add -b <name> <path> <startPoint>
            let args = lfsFlags
                + ["-C", baseRepo, "-c", "core.longpaths=true",
                   "worktree", "add", "-b", name, path, startPoint]
            let r = runCommand("/usr/bin/git", args, cwd: baseRepo, timeout: 60)

            if r.exitCode == 0 {
                enableWorktreeConfigExtensions(at: path)
                inheritHooksPath(source: baseRepo, worktree: path)
                // 源用原传入 repoPath（对齐 slice 行 142），非 baseRepo。
                copyWorktreeIncludeFiles(source: repoPath, worktree: path)
                copyGitignoredClaudeFiles(source: repoPath, worktree: path)
                appLog(.info, "Worktree", "created \(name) at \(path) from \(startPoint)")
                return Worktree(
                    path: path,
                    name: name,
                    baseRepo: baseRepo,
                    sourceBranch: sourceBranch
                )
            }

            let stderr = r.stderr ?? ""
            lastStderr = stderr
            // 清掉已创建的空目录
            try? FileManager.default.removeItem(atPath: path)

            // `already exists` = 新 branch 名 / 目录撞上，重抽 name 能解决。
            // `already checked out` = startPoint 分支已被其它 worktree 签出，与 name
            // 无关，重抽无效，直接抛。
            if stderr.contains("already exists") {
                continue
            }
            throw Error.git(stderr: stderr, isBranchConflict: false)
        }
        throw Error.git(stderr: lastStderr, isBranchConflict: true)
    }
}

// MARK: - remove

extension Worktree {

    /// 销毁本 worktree（branch 保留）。对齐 claude.app `p0r.removeWorktree`。
    /// `path` 必须在 `<baseRepo>/.claude/worktrees/` 下才物理删除，防篡改。
    func remove() throws {
        let managedRoot = (baseRepo as NSString).appendingPathComponent(".claude/worktrees")
        guard Self.isPathInside(path, managedRoot) else {
            throw Error.pathOutsideManagedDir(path: path)
        }

        // git -C baseRepo -c core.longpaths=true worktree remove --force <path>
        // 失败仅 warn，继续物理删除。
        let r = Self.runCommand(
            "/usr/bin/git",
            ["-C", baseRepo, "-c", "core.longpaths=true", "worktree", "remove", "--force", path],
            cwd: baseRepo,
            timeout: 30
        )
        if r.exitCode != 0 {
            appLog(.warning, "Worktree", "worktree remove failed \(name): \(r.stderr ?? "")")
        }

        // 物理兜底
        if FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                appLog(.warning, "Worktree", "rm -rf failed \(name): \(error.localizedDescription)")
            }
        }

        appLog(.info, "Worktree", "removed \(name) from \(path)")
    }
}

// MARK: - restore

extension Worktree {

    /// 按 (path, baseRepo, branch) 重建 worktree。unarchive 场景。
    /// `git -C <baseRepo> worktree add <path> <branch>`（不 `-b`，branch 已存在）。
    /// 失败返回 nil。不重新拷贝 `.worktreeinclude` / `.claude` gitignored 文件。
    static func restore(
        at path: String,
        baseRepo: String,
        branch: String
    ) -> Worktree? {
        // 父目录可能已被清空，先确保存在
        let parentDir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let r = runCommand(
            "/usr/bin/git",
            ["-C", baseRepo, "-c", "core.longpaths=true", "worktree", "add", path, branch],
            cwd: baseRepo,
            timeout: 30
        )
        if r.exitCode != 0 {
            appLog(.warning, "Worktree", "restore failed branch=\(branch) path=\(path): \(r.stderr ?? "")")
            return nil
        }

        let name = (path as NSString).lastPathComponent
        appLog(.info, "Worktree", "restored \(name) at \(path) branch=\(branch)")
        return Worktree(
            path: path,
            name: name,
            baseRepo: baseRepo,
            sourceBranch: branch
        )
    }
}

// MARK: - renameBranch

extension Worktree {

    /// Rename 本 worktree 的 branch。冲突时追加 `-2`/`-3`/.../`-10` suffix，
    /// 10 次耗尽返 `.failure(.git(_, isBranchConflict: true))`。
    ///
    /// - Returns: 成功 → 最终实际使用的 branch 名（可能带 `-N` 后缀）；
    ///   失败 → `.failure`，branch 未变。
    func renameBranch(to newName: String) -> Result<String, Error> {
        let maxAttempts = 10
        var lastStderr = ""

        for attempt in 1...maxAttempts {
            let target = attempt == 1 ? newName : "\(newName)-\(attempt)"
            let r = Self.runGit(
                ["branch", "-m", name, target],
                cwd: path,
                timeout: 10
            )
            if r.exitCode == 0 {
                appLog(.info, "Worktree", "branch renamed \(name) → \(target)")
                return .success(target)
            }

            let stderr = r.stderr ?? ""
            lastStderr = stderr
            // 冲突：git 通常输出 "A branch named '<target>' already exists."
            if stderr.contains("already exists") {
                continue
            }
            // 其他错误不重试
            return .failure(.git(stderr: stderr, isBranchConflict: false))
        }
        return .failure(.git(stderr: lastStderr, isBranchConflict: true))
    }
}

import Foundation

// MARK: - create

extension Worktree {

    /// Create a new worktree from `baseRepo`. Mirrors claude.app
    /// `p0r.createWorktree`.
    ///
    /// Flow:
    /// 1. `resolveBaseRepo` normalize (input worktree → main repo root).
    /// 2. `fetch --prune origin` (throttled; failure is non-fatal).
    /// 3. `maybeFastForwardLocalBranch` (when sourceBranch is non-nil).
    /// 4. `resolveStartPoint` (origin preferred / local fallback / raw).
    /// 5. `generateName()`; on branch-conflict `worktree add` failure,
    ///    regenerate up to 5 times.
    /// 6. `git worktree add <lfsFlags> -c core.longpaths=true -b <name> <path> <startPoint>`
    /// 7. `extensions.worktreeConfig` + `--worktree core.longpaths`
    /// 8. `inheritHooksPath`
    /// 9. Copy `.worktreeinclude` / `.claude` gitignored files from the
    ///    **original input repoPath** (not the normalized baseRepo).
    ///    Mirrors slice line 142 `B0r(t, E)` / `Q0r(t, E)`.
    static func create(
        from repoPath: String,
        sourceBranch: String? = nil,
        preferredName: String? = nil
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

        // Initial name collisions are vanishingly rare (266M space); 5 retries.
        // First attempt uses `preferredName` when supplied so the caller
        // (SessionHandle2's eager-persist path) can pre-compute the worktree
        // directory + branch and write a complete db row before this
        // function ever runs. Collision retries fall back to fresh
        // `generateName()` calls.
        let maxNameAttempts = 5
        var lastStderr = ""
        for attempt in 0..<maxNameAttempts {
            let name = (attempt == 0 ? preferredName : nil) ?? generateName()
            let path = worktreeDir(baseRepo: baseRepo, name: name)
            let parentDir = (path as NSString).deletingLastPathComponent

            do {
                try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            } catch {
                throw Error.directoryCreationFailed(path: parentDir, underlying: error.localizedDescription)
            }

            // git <lfsFlags> -C <baseRepo> -c core.longpaths=true worktree add -b <name> <path> <startPoint>
            let args =
                lfsFlags
                + [
                    "-C", baseRepo, "-c", "core.longpaths=true",
                    "worktree", "add", "-b", name, path, startPoint,
                ]
            let r = runCommand("/usr/bin/git", args, cwd: baseRepo, timeout: 60)

            if r.exitCode == 0 {
                enableWorktreeConfigExtensions(at: path)
                inheritHooksPath(source: baseRepo, worktree: path)
                // Source is the original input repoPath (matches slice line
                // 142), not baseRepo.
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
            // Clean up the empty directory we created
            try? FileManager.default.removeItem(atPath: path)

            // `already exists` = new branch name / directory collision —
            // regenerating the name fixes it.
            // `already checked out` = the startPoint branch is already
            // checked out by another worktree; name is irrelevant, retry
            // won't help — throw.
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

    /// Destroy this worktree (branch is kept). Mirrors claude.app
    /// `p0r.removeWorktree`. `path` must be inside
    /// `<baseRepo>/.claude/worktrees/` for physical deletion to proceed —
    /// guard against tampering.
    func remove() throws {
        let managedRoot = (baseRepo as NSString).appendingPathComponent(".claude/worktrees")
        guard Self.isPathInside(path, managedRoot) else {
            throw Error.pathOutsideManagedDir(path: path)
        }

        // git -C baseRepo -c core.longpaths=true worktree remove --force <path>
        // Failure is warn-only; physical delete still proceeds.
        let r = Self.runCommand(
            "/usr/bin/git",
            ["-C", baseRepo, "-c", "core.longpaths=true", "worktree", "remove", "--force", path],
            cwd: baseRepo,
            timeout: 30
        )
        if r.exitCode != 0 {
            appLog(.warning, "Worktree", "worktree remove failed \(name): \(r.stderr ?? "")")
        }

        // Physical fallback
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

    /// Rebuild a worktree from (path, baseRepo, branch). Used by unarchive.
    /// `git -C <baseRepo> worktree add <path> <branch>` (no `-b`, branch
    /// already exists). Returns nil on failure. Does not re-copy
    /// `.worktreeinclude` / `.claude` gitignored files.
    static func restore(
        at path: String,
        baseRepo: String,
        branch: String
    ) -> Worktree? {
        // The parent dir may have been wiped; ensure it exists first.
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

    /// Rename this worktree's branch. On conflict appends `-2`/`-3`/.../
    /// `-10` suffixes; after 10 attempts returns
    /// `.failure(.git(_, isBranchConflict: true))`.
    ///
    /// - Returns: success → the final branch name (may have a `-N`
    ///   suffix); failure → `.failure`, branch unchanged.
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
            // Conflict: git typically prints
            // "A branch named '<target>' already exists."
            if stderr.contains("already exists") {
                continue
            }
            // Other errors are not retried.
            return .failure(.git(stderr: stderr, isBranchConflict: false))
        }
        return .failure(.git(stderr: lastStderr, isBranchConflict: true))
    }
}

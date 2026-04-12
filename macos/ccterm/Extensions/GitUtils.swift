import Foundation

enum GitUtils {

    /// Reads the current branch name from `.git/HEAD` without spawning a process.
    /// Handles both normal repos (`.git/` is a directory) and worktrees (`.git` is a file).
    /// Returns `nil` if not a git repo or HEAD is detached.
    static func currentBranch(at directory: String) -> String? {
        let gitPath = (directory as NSString).appendingPathComponent(".git")
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: gitPath, isDirectory: &isDir) else {
            return nil
        }

        let headPath: String
        if isDir.boolValue {
            // Normal repo: .git/HEAD
            headPath = (gitPath as NSString).appendingPathComponent("HEAD")
        } else {
            // Worktree: .git is a file containing "gitdir: /path/to/.git/worktrees/xxx"
            guard let content = try? String(contentsOfFile: gitPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  content.hasPrefix("gitdir: ") else {
                return nil
            }
            let gitdir = String(content.dropFirst("gitdir: ".count))
            let resolved = gitdir.hasPrefix("/") ? gitdir : (directory as NSString).appendingPathComponent(gitdir)
            headPath = (resolved as NSString).appendingPathComponent("HEAD")
        }

        guard let head = try? String(contentsOfFile: headPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        // "ref: refs/heads/main" → "main"
        let prefix = "ref: refs/heads/"
        guard head.hasPrefix(prefix) else {
            return nil // Detached HEAD
        }
        return String(head.dropFirst(prefix.count))
    }

    /// Returns `true` if the directory is inside a git repository.
    static func isGitRepository(at directory: String) -> Bool {
        let gitPath = (directory as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitPath)
    }

    /// Resolves the `.git` directory path, handling both normal repos and worktrees.
    private static func resolveGitDir(at directory: String) -> String? {
        let gitPath = (directory as NSString).appendingPathComponent(".git")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gitPath, isDirectory: &isDir) else { return nil }

        if isDir.boolValue {
            return gitPath
        }
        // Worktree: .git file → "gitdir: ..."
        guard let content = try? String(contentsOfFile: gitPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              content.hasPrefix("gitdir: ") else { return nil }
        let gitdir = String(content.dropFirst("gitdir: ".count))
        let resolved = gitdir.hasPrefix("/") ? gitdir : (directory as NSString).appendingPathComponent(gitdir)
        // Walk up to the real .git dir (worktrees/xxx → ../..)
        let parent = (resolved as NSString).deletingLastPathComponent
        let grandparent = (parent as NSString).deletingLastPathComponent
        if (grandparent as NSString).lastPathComponent == ".git" {
            return grandparent
        }
        return resolved
    }

    /// Lists local branch names by reading `.git/refs/heads/` and `.git/packed-refs`.
    /// Runs on the calling thread without spawning a process.
    static func listBranches(at directory: String) -> [String] {
        guard let gitDir = resolveGitDir(at: directory) else { return [] }

        var branches = Set<String>()
        let fm = FileManager.default

        // 1. Loose refs: .git/refs/heads/**
        let headsDir = (gitDir as NSString).appendingPathComponent("refs/heads")
        if let enumerator = fm.enumerator(atPath: headsDir) {
            while let relative = enumerator.nextObject() as? String {
                let fullPath = (headsDir as NSString).appendingPathComponent(relative)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue {
                    branches.insert(relative)
                }
            }
        }

        // 2. Packed refs
        let packedPath = (gitDir as NSString).appendingPathComponent("packed-refs")
        if let packed = try? String(contentsOfFile: packedPath, encoding: .utf8) {
            let refPrefix = "refs/heads/"
            for line in packed.components(separatedBy: .newlines) {
                guard !line.hasPrefix("#"), !line.hasPrefix("^") else { continue }
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let ref = String(parts[1])
                if ref.hasPrefix(refPrefix) {
                    branches.insert(String(ref.dropFirst(refPrefix.count)))
                }
            }
        }

        // Sort with main/master first, then alphabetical
        let mainBranches: Set<String> = ["main", "master"]
        let pinned = branches.filter { mainBranches.contains($0) }.sorted()
        let rest = branches.filter { !mainBranches.contains($0) }.sorted()
        return pinned + rest
    }

    // MARK: - Head Path Resolution

    /// Resolves the actual `.git/HEAD` file path, handling worktree `.git` files.
    /// Returns `nil` if the directory is not a git repository.
    static func resolveHeadPath(at directory: String) -> String? {
        let gitPath = (directory as NSString).appendingPathComponent(".git")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gitPath, isDirectory: &isDir) else { return nil }

        if isDir.boolValue {
            return (gitPath as NSString).appendingPathComponent("HEAD")
        }

        // Worktree: .git is a file containing "gitdir: /path/to/.git/worktrees/xxx"
        guard let content = try? String(contentsOfFile: gitPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              content.hasPrefix("gitdir: ") else { return nil }
        let gitdir = String(content.dropFirst("gitdir: ".count))
        let resolved = gitdir.hasPrefix("/") ? gitdir : (directory as NSString).appendingPathComponent(gitdir)
        return (resolved as NSString).appendingPathComponent("HEAD")
    }

    // MARK: - Branch Switching

    /// Switches to the specified branch using `git switch`.
    /// Returns `true` if the switch was successful.
    @discardableResult
    static func switchBranch(at directory: String, branch: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory, "switch", branch]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Worktree Management

    /// Creates a git worktree at the specified path in detached HEAD state (no new branch).
    /// Returns `true` if the worktree was created successfully.
    @discardableResult
    static func createDetachedWorktree(repoPath: String, worktreePath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath, "worktree", "add", "--detach", worktreePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Creates a git worktree at the specified path with a new branch based on the given base branch.
    /// Returns `.success` or `.failure` with the git stderr message.
    static func createWorktree(repoPath: String, worktreePath: String, branch: String, baseBranch: String) -> Result<Void, WorktreeError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath, "worktree", "add", worktreePath, "-b", branch, baseBranch]
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return .success(())
            }
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isBranchConflict = stderr.contains("already exists")
            return .failure(WorktreeError(stderr: stderr, isBranchConflict: isBranchConflict))
        } catch {
            return .failure(WorktreeError(stderr: error.localizedDescription, isBranchConflict: false))
        }
    }

    struct WorktreeError: Error, LocalizedError {
        let stderr: String
        let isBranchConflict: Bool
        var errorDescription: String? { stderr }
    }

    /// Creates a git worktree in detached HEAD mode (no branch).
    /// Used for async branch generation: worktree starts immediately, branch is created later.
    static func createWorktreeDetached(repoPath: String, worktreePath: String, baseBranch: String) -> Result<Void, WorktreeError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath, "worktree", "add", "--detach", worktreePath, baseBranch]
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return .success(())
            }
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(WorktreeError(stderr: stderr, isBranchConflict: false))
        } catch {
            return .failure(WorktreeError(stderr: error.localizedDescription, isBranchConflict: false))
        }
    }

    /// Creates a new branch at the current HEAD in the given worktree directory.
    /// Used after async branch name generation to attach a branch to a detached HEAD worktree.
    static func checkoutNewBranch(at worktreePath: String, branch: String) -> Result<Void, WorktreeError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", worktreePath, "checkout", "-b", branch]
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return .success(())
            }
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isBranchConflict = stderr.contains("already exists")
            return .failure(WorktreeError(stderr: stderr, isBranchConflict: isBranchConflict))
        } catch {
            return .failure(WorktreeError(stderr: error.localizedDescription, isBranchConflict: false))
        }
    }

    /// Creates a git worktree at the specified path for an existing branch (no `-b`).
    /// Used when restoring a worktree from archive.
    /// Returns `true` if the worktree was created successfully.
    @discardableResult
    static func addWorktreeForExistingBranch(repoPath: String, worktreePath: String, branch: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath, "worktree", "add", worktreePath, branch]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Removes a git worktree at the specified path.
    static func removeWorktree(repoPath: String, worktreePath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath, "worktree", "remove", worktreePath, "--force"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Deletes a local branch from the repository.
    static func deleteBranch(at repoPath: String, branch: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath, "branch", "-D", branch]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

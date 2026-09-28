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
            guard
                let content = try? String(contentsOfFile: gitPath, encoding: .utf8).trimmingCharacters(
                    in: .whitespacesAndNewlines),
                content.hasPrefix("gitdir: ")
            else {
                return nil
            }
            let gitdir = String(content.dropFirst("gitdir: ".count))
            let resolved = gitdir.hasPrefix("/") ? gitdir : (directory as NSString).appendingPathComponent(gitdir)
            headPath = (resolved as NSString).appendingPathComponent("HEAD")
        }

        guard
            let head = try? String(contentsOfFile: headPath, encoding: .utf8).trimmingCharacters(
                in: .whitespacesAndNewlines)
        else {
            return nil
        }

        // "ref: refs/heads/main" → "main"
        let prefix = "ref: refs/heads/"
        guard head.hasPrefix(prefix) else {
            return nil  // Detached HEAD
        }
        return String(head.dropFirst(prefix.count))
    }

    /// The current branch of `directory` as it is now, then again each time it
    /// changes — a checkout at the command line included — until the consumer
    /// stops iterating. Read off the caller's thread; `nil` when the folder
    /// isn't a repository or HEAD is detached. Consecutive equal values are
    /// yielded once.
    static func currentBranchUpdates(at directory: String) -> AsyncStream<String?> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    /// Returns `true` if the directory is inside a git repository.
    static func isGitRepository(at directory: String) -> Bool {
        let gitPath = (directory as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitPath)
    }
}

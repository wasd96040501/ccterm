import Foundation

enum GitUtils {

    /// Reads the current branch name from `.git/HEAD` without spawning a process.
    /// Handles both normal repos (`.git/` is a directory) and worktrees (`.git` is a file).
    /// Returns `nil` if not a git repo or HEAD is detached.
    nonisolated static func currentBranch(at directory: String) -> String? {
        guard
            let headPath = headPath(at: directory),
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

    /// The current branch of `directory` as it is now, then again whenever the
    /// directory holding its HEAD changes — a checkout at the command line
    /// included — until the consumer stops iterating. Read on a queue of its own;
    /// `nil` when the folder isn't a repository or HEAD is detached. A change
    /// there that isn't a checkout yields the same branch again.
    ///
    /// Watches the directory rather than HEAD itself: git writes `HEAD.lock` and
    /// renames it over HEAD, so the file watched would be the one replaced.
    nonisolated static func currentBranchUpdates(at directory: String) -> AsyncStream<String?> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "GitUtils.currentBranchUpdates", qos: .userInitiated)
            queue.async {
                continuation.yield(currentBranch(at: directory))
                guard let headPath = headPath(at: directory) else { return continuation.finish() }
                let descriptor = open((headPath as NSString).deletingLastPathComponent, O_EVTONLY)
                guard descriptor >= 0 else { return continuation.finish() }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor, eventMask: .write, queue: queue)
                source.setEventHandler { continuation.yield(currentBranch(at: directory)) }
                source.setCancelHandler { close(descriptor) }
                continuation.onTermination = { _ in source.cancel() }
                source.resume()
            }
        }
    }

    /// The nearest directory at or above `path` that is a repository or a
    /// worktree's checkout — where its `.git` is. `nil` outside any, and when
    /// `path` no longer exists: a removed worktree's folder
    /// (`<repo>/.claude/worktrees/<name>`) lies inside the repository it was
    /// checked out from, which is on another branch.
    nonisolated static func repositoryRoot(containing path: String) -> String? {
        var directory = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        while true {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory.path
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }

    /// Where `directory`'s HEAD is: `.git/HEAD` in a repository, the `gitdir`'s
    /// HEAD in a worktree (where `.git` is a file naming it). `nil` if neither.
    private nonisolated static func headPath(at directory: String) -> String? {
        let gitPath = (directory as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else {
            return nil
        }
        if isDir.boolValue {
            return (gitPath as NSString).appendingPathComponent("HEAD")
        }
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
        return (resolved as NSString).appendingPathComponent("HEAD")
    }

    /// Returns `true` if the directory is inside a git repository.
    static func isGitRepository(at directory: String) -> Bool {
        let gitPath = (directory as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitPath)
    }
}

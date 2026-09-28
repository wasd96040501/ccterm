import Foundation

/// What the app reads from git: which branch a folder's repository is on, and
/// when that changes. Reads the repository's files; spawns no `git` process.
struct GitService: Sendable {
    /// The branch of the repository or worktree checkout that holds
    /// `directory`, now and then whenever a checkout changes it, until the
    /// consumer stops iterating; `nil` elements while HEAD is detached. The
    /// stream itself is `nil` when `directory` is in no repository — so the
    /// caller can tell "no branch" from "nothing to follow".
    ///
    /// Reads nothing on the caller's actor.
    @concurrent
    nonisolated func branchUpdates(at directory: String) async -> AsyncStream<String?>? {
        guard let root = Self.repositoryRoot(containing: directory) else { return nil }
        return Self.currentBranchUpdates(at: root)
    }

    /// The current branch of `directory` as it is now, then again whenever the
    /// directory holding its HEAD changes, on a queue of its own. A change there
    /// that isn't a checkout yields the same branch again.
    ///
    /// Watches the directory rather than HEAD itself: git writes `HEAD.lock` and
    /// renames it over HEAD, so the file watched would be the one replaced.
    private static func currentBranchUpdates(at directory: String) -> AsyncStream<String?> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "GitService.branchUpdates", qos: .userInitiated)
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

    /// The branch HEAD names ("ref: refs/heads/main" → "main"); `nil` when HEAD
    /// is detached or unreadable.
    private static func currentBranch(at directory: String) -> String? {
        guard
            let headPath = headPath(at: directory),
            let head = try? String(contentsOfFile: headPath, encoding: .utf8).trimmingCharacters(
                in: .whitespacesAndNewlines)
        else {
            return nil
        }
        let prefix = "ref: refs/heads/"
        guard head.hasPrefix(prefix) else { return nil }
        return String(head.dropFirst(prefix.count))
    }

    /// The nearest directory at or above `path` that is a repository or a
    /// worktree's checkout — where its `.git` is. `nil` outside any.
    private static func repositoryRoot(containing path: String) -> String? {
        var directory = URL(fileURLWithPath: path).standardizedFileURL
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
    private static func headPath(at directory: String) -> String? {
        let gitPath = (directory as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else {
            return nil
        }
        if isDir.boolValue {
            return (gitPath as NSString).appendingPathComponent("HEAD")
        }
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
}

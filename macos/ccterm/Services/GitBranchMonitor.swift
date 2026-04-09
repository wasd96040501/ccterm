import Foundation
import Observation

/// Monitors .git/HEAD for branch changes using DispatchSource file system events.
/// Works for both regular repos and worktrees.
@Observable
final class GitBranchMonitor {

    private(set) var branch: String?

    private var source: DispatchSourceFileSystemObject?
    private var monitoredDir: String?
    private var fileDescriptor: Int32 = -1

    func monitor(directory: String) {
        guard directory != monitoredDir else { return }
        stop()
        monitoredDir = directory
        branch = GitUtils.currentBranch(at: directory)
        startWatching(directory)
    }

    func stop() {
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        monitoredDir = nil
        branch = nil
    }

    deinit {
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    // MARK: - Private

    private func startWatching(_ directory: String) {
        guard let headPath = resolveHeadPath(directory) else { return }

        fileDescriptor = Darwin.open(headPath, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self, let dir = self.monitoredDir else { return }
            let newBranch = GitUtils.currentBranch(at: dir)
            DispatchQueue.main.async {
                self.branch = newBranch
            }

            // If file was deleted/renamed (e.g. rebase), re-register
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.restartWatching()
                }
            }
        }

        source.setCancelHandler { [fd = fileDescriptor] in
            if fd >= 0 { Darwin.close(fd) }
        }
        // We'll let the cancel handler close the fd
        self.fileDescriptor = -1

        source.resume()
        self.source = source
    }

    private func restartWatching() {
        source?.cancel()
        source = nil
        // fd is closed by cancel handler

        guard let dir = monitoredDir else { return }
        // Small delay to allow file recreation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.monitoredDir == dir else { return }
            self.startWatching(dir)
        }
    }

    /// Resolve the actual HEAD file path, handling worktree `.git` files.
    private func resolveHeadPath(_ directory: String) -> String? {
        let gitPath = (directory as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false

        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else {
            return nil
        }

        if isDir.boolValue {
            // Regular repo
            return (gitPath as NSString).appendingPathComponent("HEAD")
        } else {
            // Worktree: .git is a file containing "gitdir: <path>"
            guard let content = try? String(contentsOfFile: gitPath, encoding: .utf8),
                  content.hasPrefix("gitdir: ") else {
                return nil
            }
            let gitdir = content.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "gitdir: ", with: "")
            let resolvedGitdir: String
            if gitdir.hasPrefix("/") {
                resolvedGitdir = gitdir
            } else {
                resolvedGitdir = (directory as NSString).appendingPathComponent(gitdir)
            }
            return (resolvedGitdir as NSString).appendingPathComponent("HEAD")
        }
    }
}

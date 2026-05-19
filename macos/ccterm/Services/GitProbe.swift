import Foundation
import Observation

/// Lazily-loaded git information for a single folder. Owns the @Observable
/// state read by `BranchPickerView` (branches list, current branch, remote
/// main, working-tree status summary) so the picker can render the moment
/// its popover opens, without paying the subprocess cost on the user's
/// click. The view drives the lifecycle:
///
/// 1. `refresh(folderPath:)` — synchronous, cheap. Reads `.git/HEAD` and
///    checks `.git` existence; no subprocesses. Sets `isGitRepo` and
///    `currentBranch` immediately, and resets the heavy cache when the
///    folder changes so a stale list doesn't briefly flash through.
/// 2. `loadHeavy(folderPath:)` — async, spawns three `git` subprocesses on
///    a detached background task. Idempotent for the same path (cache
///    hits return immediately), and the result is dropped if `refresh`
///    has since been called with a different folder.
///
/// Both methods accept the folderPath explicitly rather than reading from
/// internal state. This makes the lifecycle explicit at the call site
/// (the configurator's `.task(id: folderPath)`) and keeps the probe
/// directly testable — a unit test constructs one, calls these methods
/// against a temp git repo, and asserts on the @Observable properties.
@Observable
final class GitProbe {

    /// Branch list from `git for-each-ref refs/heads`. Empty when the
    /// folder isn't a repo, when the heavy load hasn't run yet, or when
    /// `refresh` reset the cache because the folder changed.
    private(set) var branches: [String] = []
    /// HEAD's branch name, read directly from `.git/HEAD`. Nil when the
    /// folder isn't a repo, or when HEAD is detached.
    private(set) var currentBranch: String? = nil
    /// Remote default branch (e.g. `origin/main`), via `git symbolic-ref
    /// refs/remotes/origin/HEAD`. Nil when there's no remote default.
    private(set) var remoteMainBranch: String? = nil
    /// One-line working-tree status (e.g. `"3 changed · ↑2"`), computed
    /// from `git status --porcelain` + `git rev-list ... @{upstream}`.
    /// Nil when the probes returned nothing useful.
    private(set) var currentBranchStatus: String? = nil
    /// Quick `.git`-exists check from `refresh`. Read by `loadHeavy` to
    /// short-circuit non-repos before shelling out.
    private(set) var isGitRepo: Bool = false

    /// Folder we've already cached heavy git info for. Lets repeat
    /// loadHeavy calls return instantly without re-shelling. Reset to
    /// nil by `refresh` whenever the folder changes.
    @ObservationIgnored private var heavyGitLoadedForFolder: String? = nil
    /// The most recent folder passed to `refresh`. Used by `loadHeavy`'s
    /// post-`await` guard to drop a stale result when the caller has
    /// since switched folders.
    @ObservationIgnored private var pendingFolder: String? = nil

    /// `seedFolderPath` runs the cheap probe (`.git/HEAD` read + `.git`
    /// existence check) synchronously, so the consumer's first frame sees
    /// `isGitRepo` / `currentBranch` already filled in. Without this seed
    /// the branch pill in the New Session card pops in one frame later
    /// when `.task(id: folderPath)` fires, shoving the divider, recents,
    /// and input bar down by a row.
    init(seedFolderPath: String? = nil) {
        if let path = seedFolderPath, FileManager.default.fileExists(atPath: path) {
            let repo = GitUtils.isGitRepository(at: path)
            isGitRepo = repo
            currentBranch = repo ? GitUtils.currentBranch(at: path) : nil
            pendingFolder = path
        }
    }

    /// Synchronous, cheap probe. Updates `isGitRepo` and `currentBranch`,
    /// and resets the heavy cache when `folderPath` differs from the
    /// previously-cached folder. Safe to call from a SwiftUI `.task`'s
    /// synchronous prefix.
    func refresh(folderPath: String?) {
        pendingFolder = folderPath
        guard let path = folderPath else {
            resetAll()
            return
        }
        if !FileManager.default.fileExists(atPath: path) {
            resetAll()
            return
        }
        let repo = GitUtils.isGitRepository(at: path)
        let head = repo ? GitUtils.currentBranch(at: path) : nil
        isGitRepo = repo
        currentBranch = head
        if heavyGitLoadedForFolder != path {
            branches = []
            remoteMainBranch = nil
            currentBranchStatus = nil
            heavyGitLoadedForFolder = nil
        }
    }

    /// Async heavy probe. Spawns three `git` subprocesses on a detached
    /// background task, populates `branches` / `remoteMainBranch` /
    /// `currentBranchStatus` when done. Gating:
    ///
    /// 1. No folder, or `isGitRepo` is false → bail (don't shell out for
    ///    plain folders).
    /// 2. Cache hit (`heavyGitLoadedForFolder == path`) → bail; idempotent.
    /// 3. After `await`, `pendingFolder` no longer matches → drop the
    ///    result (the caller called `refresh` with a different folder).
    func loadHeavy(folderPath: String?) async {
        guard let path = folderPath, isGitRepo else { return }
        if heavyGitLoadedForFolder == path { return }
        let result = await Task.detached(priority: .userInitiated) {
            let l = Self.listBranches(at: path)
            let r = Self.remoteMainBranchName(at: path)
            let s = Self.gitStatusSummary(at: path)
            return (l, r, s)
        }.value
        guard pendingFolder == path else { return }
        branches = result.0
        remoteMainBranch = result.1
        currentBranchStatus = result.2
        heavyGitLoadedForFolder = path
    }

    private func resetAll() {
        isGitRepo = false
        currentBranch = nil
        branches = []
        remoteMainBranch = nil
        currentBranchStatus = nil
        heavyGitLoadedForFolder = nil
    }

    // MARK: - Git subprocess helpers

    static func listBranches(at path: String) -> [String] {
        let result = Worktree.runGit(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
            cwd: path,
            timeout: 5
        )
        guard result.exitCode == 0, let stdout = result.stdout else { return [] }
        return
            stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func remoteMainBranchName(at path: String) -> String? {
        let result = Worktree.runGit(
            ["symbolic-ref", "--short", "--quiet", "refs/remotes/origin/HEAD"],
            cwd: path,
            timeout: 5
        )
        guard result.exitCode == 0,
            let stdout = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
            !stdout.isEmpty
        else {
            return nil
        }
        return stdout
    }

    static func gitStatusSummary(at path: String) -> String? {
        var parts: [String] = []
        let porcelain = Worktree.runGit(
            ["status", "--porcelain"],
            cwd: path,
            timeout: 5
        )
        if porcelain.exitCode == 0, let out = porcelain.stdout {
            var modified = 0
            var untracked = 0
            for raw in out.split(separator: "\n") {
                let line = String(raw)
                if line.hasPrefix("??") {
                    untracked += 1
                } else if !line.isEmpty {
                    modified += 1
                }
            }
            if modified == 0 && untracked == 0 {
                parts.append(String(localized: "Clean"))
            } else {
                var subs: [String] = []
                if modified > 0 { subs.append(String(localized: "\(modified) changed")) }
                if untracked > 0 { subs.append(String(localized: "\(untracked) untracked")) }
                parts.append(subs.joined(separator: ", "))
            }
        }

        let tracking = Worktree.runGit(
            ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"],
            cwd: path,
            timeout: 5
        )
        if tracking.exitCode == 0,
            let out = tracking.stdout?.trimmingCharacters(in: .whitespacesAndNewlines)
        {
            let cols = out.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            if cols.count == 2, let behind = Int(cols[0]), let ahead = Int(cols[1]) {
                var arrows: [String] = []
                if ahead > 0 { arrows.append("↑\(ahead)") }
                if behind > 0 { arrows.append("↓\(behind)") }
                if !arrows.isEmpty {
                    parts.append(arrows.joined(separator: " "))
                }
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

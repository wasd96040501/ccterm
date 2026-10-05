import Foundation

/// The git a New tab needs: what a folder's repository has (its branches,
/// which are checked out elsewhere, whether it has uncommitted work) and the
/// steps a launch takes before the CLI starts — `git switch` in place, or
/// `git worktree add` for a worktree from a branch the CLI can't start from.
/// Spawns `git`; `GitService` stays the read-only follower of a branch.
///
/// Every call runs off the caller's actor.
struct BranchService: Sendable {
    /// What `folder`'s repository has; `nil` when it is in none.
    @concurrent
    nonisolated func repository(at folder: URL) async -> RepositoryState? {
        guard let top = try? Self.git(["rev-parse", "--show-toplevel"], in: folder).trimmedLines.first else {
            return nil
        }
        let root = URL(fileURLWithPath: top, isDirectory: true)
        let branch = (try? Self.git(["symbolic-ref", "--short", "-q", "HEAD"], in: root))?.trimmedLines.first
        let local = (try? Self.refs("refs/heads/", prefix: "refs/heads/", in: root)) ?? []
        let localSet = Set(local)
        // `origin/main` has the twin `main`; `origin/HEAD` is a pointer, not a branch.
        let remote = ((try? Self.refs("refs/remotes/", prefix: "refs/remotes/", in: root)) ?? []).filter { name in
            guard !name.hasSuffix("/HEAD"), let slash = name.firstIndex(of: "/") else { return false }
            return !localSet.contains(String(name[name.index(after: slash)...]))
        }
        let defaultBranch = (try? Self.git(["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"], in: root))?
            .trimmedLines.first.map { $0.hasPrefix("origin/") ? String($0.dropFirst("origin/".count)) : $0 }
        let dirty =
            ((try? Self.git(["status", "--porcelain", "--untracked-files=no"], in: root)) ?? "")
            .trimmedLines.isEmpty == false
        return RepositoryState(
            root: root, branch: branch, localBranches: local, remoteBranches: remote,
            branchesCheckedOutElsewhere: Self.branchesCheckedOut(besides: root, in: root),
            hasUncommittedChanges: dirty, defaultBranch: defaultBranch)
    }

    /// Makes `checkout` real in `folder` and says where the CLI runs:
    /// `.inPlace(switchTo:)` switches first; `.worktree(base: .head)` and
    /// `.defaultBranch` are the CLI's own `--worktree` (with `baseRef: head`
    /// for the first); `.worktree(base: .branch)` is `git worktree add -b
    /// <name> .claude/worktrees/<name> <branch>` here; `.pullRequest(N)` is
    /// the CLI's `--worktree #N`, named `pr-N`. ccterm names every worktree
    /// (`name`), so the transcript's URL is known before the CLI starts.
    /// Throws git's refusal in words.
    @concurrent
    nonisolated func prepare(
        _ checkout: Checkout, in folder: URL, name: String
    ) async throws -> PreparedWorkspace {
        let planned = Self.plannedDirectory(for: checkout, in: folder, name: name)
        switch checkout {
        case .inPlace(let target):
            if let target {
                let isRemote =
                    (try? Self.git(["show-ref", "--verify", "--quiet", "refs/remotes/\(target)"], in: folder))
                    != nil
                let arguments = isRemote ? ["switch", "--track", target] : ["switch", target]
                do { _ = try Self.git(arguments, in: folder) } catch let GitFailure.failed(message) {
                    throw GitRefusal(message: message)
                }
            }
            return PreparedWorkspace(
                workingDirectory: folder, worktreeName: nil, worktreeBaseRef: nil, sessionDirectory: folder)
        case .worktree(let base):
            guard let planned else { throw GitRefusal(message: Self.notARepository) }
            switch base {
            case .head:
                return PreparedWorkspace(
                    workingDirectory: folder, worktreeName: name, worktreeBaseRef: "head", sessionDirectory: planned)
            case .defaultBranch:
                return PreparedWorkspace(
                    workingDirectory: folder, worktreeName: name, worktreeBaseRef: nil, sessionDirectory: planned)
            case .branch(let branch):
                try FileManager.default.createDirectory(
                    at: planned.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    _ = try Self.git(["worktree", "add", "-b", "worktree-\(name)", planned.path, branch], in: folder)
                } catch let GitFailure.failed(message) {
                    throw GitRefusal(message: message)
                }
                return PreparedWorkspace(
                    workingDirectory: planned, worktreeName: nil, worktreeBaseRef: nil, sessionDirectory: planned)
            }
        case .pullRequest(let number):
            guard let planned else { throw GitRefusal(message: Self.notARepository) }
            return PreparedWorkspace(
                workingDirectory: folder, worktreeName: "#\(number)", worktreeBaseRef: nil, sessionDirectory: planned)
        }
    }

    /// Where the CLI will work for `checkout`, known without running git: the
    /// folder itself, or `<repository>/.claude/worktrees/<name>` (`pr-N` for a
    /// pull request) — the folder whose project directory holds the
    /// transcript. `nil` for a worktree asked of a folder in no repository.
    nonisolated static func plannedDirectory(for checkout: Checkout, in folder: URL, name: String) -> URL? {
        let leaf: String
        switch checkout {
        case .inPlace: return folder
        case .worktree: leaf = name
        case .pullRequest(let number): leaf = "pr-\(number)"
        }
        guard let root = repositoryRoot(containing: folder) else { return nil }
        return root.appendingPathComponent(".claude/worktrees/\(leaf)", isDirectory: true)
    }

    /// The nearest directory at or above `folder` with a `.git` — a repository's
    /// or a worktree's top.
    nonisolated static func repositoryRoot(containing folder: URL) -> URL? {
        var directory = folder.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory
            }
            // `deletingLastPathComponent` of the root is `/..`, never itself.
            guard directory.path != "/" else { return nil }
            directory = directory.deletingLastPathComponent().standardizedFileURL
        }
    }

    private nonisolated static let adjectives = [
        "quiet", "brave", "calm", "eager", "gentle", "happy", "jolly", "keen", "lively", "mellow", "nimble", "proud",
        "swift", "witty", "zesty", "bright", "cosmic", "dapper", "fuzzy", "golden", "humble", "lucky", "merry", "noble",
    ]
    private nonisolated static let animals = [
        "otter", "badger", "falcon", "heron", "lynx", "marmot", "newt", "owl", "panda", "quail", "raven", "seal",
        "tiger", "vole", "walrus", "yak", "zebra", "beaver", "crane", "dolphin", "ferret", "gecko", "koala", "lemur",
    ]

    /// A fresh worktree name, in the CLI's own style (`quiet-otter`).
    nonisolated static func makeWorktreeName() -> String {
        "\(adjectives.randomElement()!)-\(animals.randomElement()!)"
    }

    // MARK: - git

    private nonisolated static let notARepository = String(localized: "Not a Git repository")

    /// Branch names under `namespace`, newest commit first, `prefix` cut.
    private nonisolated static func refs(_ namespace: String, prefix: String, in directory: URL) throws -> [String] {
        try git(["for-each-ref", "--sort=-committerdate", "--format=%(refname)", namespace], in: directory)
            .trimmedLines.map { String($0.dropFirst(prefix.count)) }
    }

    /// Branches checked out in a worktree other than the one at `root`.
    private nonisolated static func branchesCheckedOut(besides root: URL, in directory: URL) -> Set<String> {
        guard let listing = try? git(["worktree", "list", "--porcelain"], in: directory) else { return [] }
        let own = root.resolvingSymlinksInPath().path
        var branches: Set<String> = []
        var path: String?
        for line in listing.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/"), let path,
                URL(fileURLWithPath: path).resolvingSymlinksInPath().path != own
            {
                branches.insert(String(line.dropFirst("branch refs/heads/".count)))
            }
        }
        return branches
    }

    private enum GitFailure: Error {
        case failed(String)
    }

    /// Runs `git` in `directory`; its output, or git's last words on failure.
    /// Its two pipes drain at once: git blocks writing to a full pipe, so
    /// reading one to its end before the other could wait forever. Reads take
    /// no optional locks, so a `status` never holds up the user's own git.
    @discardableResult
    private nonisolated static func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let errorRead = DrainedPipe(errors)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorRead.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message =
                String(decoding: errorData, as: UTF8.self).trimmedLines.last
                ?? "git exited with status \(process.terminationStatus)"
            throw GitFailure.failed(message.replacingOccurrences(of: "fatal: ", with: ""))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A pipe read to its end on a queue of its own, while the caller reads another.
private final class DrainedPipe: @unchecked Sendable {
    private let done = DispatchGroup()
    /// Written once, before `done` is left.
    private var data = Data()

    init(_ pipe: Pipe) {
        done.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.leave()
        }
    }

    /// What the pipe held, once it closed.
    func wait() -> Data {
        done.wait()
        return data
    }
}

/// What git said when it refused a step, ready to show.
struct GitRefusal: Error, LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

extension String {
    fileprivate nonisolated var trimmedLines: [String] {
        split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

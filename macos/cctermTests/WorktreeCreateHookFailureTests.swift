import XCTest

@testable import ccterm

/// Covers `Worktree.create`'s behavior when `git worktree add` exits
/// non-zero because of a failing **`post-checkout` hook** rather than a
/// real provisioning failure.
///
/// `git worktree add` checks out the files and registers the worktree
/// *before* running the `post-checkout` hook, then propagates the hook's
/// exit code as its own. An LFS repo's `post-checkout` hook
/// (`git lfs post-checkout`) returning non-zero therefore makes the whole
/// command exit non-zero even though the worktree is fully present and
/// usable. Such hooks are advisory — git's own `git checkout` doesn't
/// abort on them — so `create` must keep the worktree instead of deleting
/// a good checkout and failing session start.
///
/// Each test builds a self-contained temp git repo (own UUID dir, torn
/// down in `tearDown`) and drives the real `Worktree.create` through a
/// real `git worktree add` — the failure mode only reproduces against
/// actual git, so there's no fake seam here.
final class WorktreeCreateHookFailureTests: XCTestCase {

    private var rootDir: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccterm-wt-hook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        rootDir = dir
    }

    override func tearDown() async throws {
        if let dir = rootDir {
            try? FileManager.default.removeItem(at: dir)
        }
        rootDir = nil
    }

    // MARK: - The fix: adopt a worktree whose post-checkout hook failed

    /// A `post-checkout` hook that exits non-zero makes `git worktree add`
    /// exit non-zero, but the worktree is already checked out and
    /// registered. `create` must return it (not throw, not delete it).
    func testCreateAdoptsWorktreeWhenPostCheckoutHookFails() throws {
        let repo = try makeRepoWithCommit(trackedFile: "hello.txt", contents: "hi\n")
        try installPostCheckoutHook(in: repo, body: "exit 2\n")

        let wt = try Worktree.create(from: repo.path)

        // It exists on disk and is a registered worktree.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: wt.path),
            "the worktree directory must survive a failing post-checkout hook")
        XCTAssertTrue(
            Worktree.isRegisteredWorktree(at: wt.path),
            "the adopted worktree must be a real, git-registered worktree")

        // The checkout actually happened — the committed file is present.
        let checkedOut = (wt.path as NSString).appendingPathComponent("hello.txt")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: checkedOut),
            "the tracked file must be checked out into the worktree")
        XCTAssertEqual(try String(contentsOfFile: checkedOut, encoding: .utf8), "hi\n")

        // The branch was created and matches the worktree name.
        XCTAssertFalse(wt.name.isEmpty)
        XCTAssertTrue(
            branchExists(in: repo, branch: wt.name),
            "the new branch must exist even though the hook failed")
    }

    // MARK: - Regression: a passing post-checkout hook still works

    /// Guards the happy path: a repo with a `post-checkout` hook that
    /// succeeds still provisions normally.
    func testCreateSucceedsWhenPostCheckoutHookPasses() throws {
        let repo = try makeRepoWithCommit(trackedFile: "hello.txt", contents: "hi\n")
        try installPostCheckoutHook(in: repo, body: "exit 0\n")

        let wt = try Worktree.create(from: repo.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path))
        XCTAssertTrue(Worktree.isRegisteredWorktree(at: wt.path))
        XCTAssertTrue(branchExists(in: repo, branch: wt.name))
    }

    // MARK: - The discriminator that keeps the adopt branch honest

    /// `isRegisteredWorktree` is the gate that prevents `create` from
    /// "adopting" garbage: it must be true only for a real, git-registered
    /// worktree, and false for a plain directory that merely sits under
    /// `.claude/worktrees/`.
    func testIsRegisteredWorktreeDiscriminatesRealWorktreeFromPlainDir() throws {
        let repo = try makeRepoWithCommit(trackedFile: "hello.txt", contents: "hi\n")

        // A real worktree (hook passes here; we only care about registration).
        let wt = try Worktree.create(from: repo.path)
        XCTAssertTrue(
            Worktree.isRegisteredWorktree(at: wt.path),
            "a git-registered worktree must be detected")

        // A plain directory under .claude/worktrees that git never registered.
        let bogus = repo.appendingPathComponent(".claude/worktrees/not-a-worktree")
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
        try "x".write(
            to: bogus.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(
            Worktree.isRegisteredWorktree(at: bogus.path),
            "a plain directory under .claude/worktrees must NOT be mistaken for a worktree")
    }

    // MARK: - Fixture helpers

    /// `git init` a repo, set a local identity, write + commit one tracked
    /// file so a default branch with a real commit exists (the worktree
    /// start point).
    private func makeRepoWithCommit(trackedFile: String, contents: String) throws -> URL {
        let dir = try requireRoot().appendingPathComponent("repo-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try runGit(in: dir, "init", "-q")
        try runGit(in: dir, "config", "user.email", "test@example.com")
        try runGit(in: dir, "config", "user.name", "test")

        try contents.write(
            to: dir.appendingPathComponent(trackedFile), atomically: true, encoding: .utf8)
        try runGit(in: dir, "add", "-A")
        try runGit(in: dir, "commit", "-q", "-m", "init")
        return dir
    }

    /// Drop an executable `post-checkout` hook into the repo's default
    /// hooks dir (`.git/hooks`). `body` is the shell after `#!/bin/sh`.
    private func installPostCheckoutHook(in repo: URL, body: String) throws {
        let hook = repo.appendingPathComponent(".git/hooks/post-checkout")
        try "#!/bin/sh\n\(body)".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    private func branchExists(in repo: URL, branch: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = [
            "-C", repo.path, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)",
        ]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    private func requireRoot() throws -> URL {
        guard let root = rootDir else {
            throw XCTSkip("rootDir not set up")
        }
        return root
    }

    private func runGit(in dir: URL, _ args: String...) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir.path] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let stderr =
                String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "GitHelper", code: Int(proc.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "git \(args.joined(separator: " ")) failed: \(stderr)"
                ])
        }
    }
}

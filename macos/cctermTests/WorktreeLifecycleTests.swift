import XCTest
@testable import ccterm

/// Covers `Worktree.remove()` / `Worktree.restore(...)` / `Worktree.renameBranch(to:)`。
final class WorktreeLifecycleTests: XCTestCase {

    // MARK: - Helpers

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtlife-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root = tmpRoot, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @discardableResult
    private func runGit(_ args: [String], cwd: String) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", cwd] + args
        let out = Pipe(); p.standardOutput = out
        let err = Pipe(); p.standardError = err
        try? p.run()
        p.waitUntilExit()
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, o + e)
    }

    private func initRepo(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        _ = runGit(["init", "-b", "main"], cwd: path)
        _ = runGit(["config", "user.email", "t@example.com"], cwd: path)
        _ = runGit(["config", "user.name", "t"], cwd: path)
        let file = (path as NSString).appendingPathComponent("init.txt")
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        _ = runGit(["add", "-A"], cwd: path)
        _ = runGit(["commit", "-m", "init"], cwd: path)
    }

    private func branchList(at path: String) -> [String] {
        let (_, out) = runGit(["branch", "--list", "--format=%(refname:short)"], cwd: path)
        return out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func currentBranch(at path: String) -> String {
        let (_, out) = runGit(["branch", "--show-current"], cwd: path)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - remove

    func test_remove_deletesWorktreeKeepsBranch() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)
        let wt = try Worktree.create(from: repo, sourceBranch: nil)

        try wt.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path),
                       "worktree directory should be deleted")
        XCTAssertTrue(branchList(at: repo).contains(wt.name),
                      "branch must be preserved in main repo, got: \(branchList(at: repo))")
    }

    func test_remove_refusesPathOutsideManagedDir() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)

        // 手工在 tmpRoot 下而不是 .claude/worktrees 下建 worktree
        let outsidePath = tmpRoot.appendingPathComponent("outside-wt").path
        let (ec, _) = runGit(
            ["-c", "core.longpaths=true", "worktree", "add", "-b", "test/outside", outsidePath, "main"],
            cwd: repo
        )
        XCTAssertEqual(ec, 0)

        // 构造 Worktree 实例，指向 outside 路径
        let rogue = Worktree(
            path: outsidePath,
            name: "outside-wt",
            baseRepo: repo,
            sourceBranch: nil
        )
        do {
            try rogue.remove()
            XCTFail("expected pathOutsideManagedDir")
        } catch Worktree.Error.pathOutsideManagedDir {
            // ok
        }

        // outside worktree 仍在
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsidePath))

        // cleanup
        _ = runGit(["worktree", "remove", "--force", outsidePath], cwd: repo)
    }

    // MARK: - restore

    func test_restore_rebuildsFromBranch() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)
        let wt = try Worktree.create(from: repo, sourceBranch: nil)
        let savedPath = wt.path
        let savedName = wt.name

        try wt.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedPath))

        let restored = Worktree.restore(at: savedPath, baseRepo: repo, branch: savedName)
        XCTAssertNotNil(restored)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedPath))
        XCTAssertEqual(currentBranch(at: savedPath), savedName)
        XCTAssertEqual(restored?.sourceBranch, savedName)
    }

    func test_restore_returnsNilForMissingBranch() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)

        let fakePath = (repo as NSString).appendingPathComponent(".claude/worktrees/ghost")
        let r = Worktree.restore(at: fakePath, baseRepo: repo, branch: "no-such-branch")
        XCTAssertNil(r)
    }

    // MARK: - renameBranch

    func test_renameBranch_success() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)
        let wt = try Worktree.create(from: repo, sourceBranch: nil)

        switch wt.renameBranch(to: "feat/new") {
        case .success(let final):
            XCTAssertEqual(final, "feat/new")
        case .failure(let err):
            XCTFail("rename failed: \(err)")
        }

        XCTAssertEqual(currentBranch(at: wt.path), "feat/new")
        XCTAssertFalse(branchList(at: repo).contains(wt.name))
        XCTAssertTrue(branchList(at: repo).contains("feat/new"))
    }

    func test_renameBranch_conflictAppendsSuffix() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)
        // 预先占用目标 branch
        _ = runGit(["branch", "feat/auth"], cwd: repo)

        let wt = try Worktree.create(from: repo, sourceBranch: nil)

        switch wt.renameBranch(to: "feat/auth") {
        case .success(let final):
            XCTAssertEqual(final, "feat/auth-2")
        case .failure(let err):
            XCTFail("expected suffix success, got: \(err)")
        }

        XCTAssertEqual(currentBranch(at: wt.path), "feat/auth-2")
        let branches = branchList(at: repo)
        XCTAssertTrue(branches.contains("feat/auth"))
        XCTAssertTrue(branches.contains("feat/auth-2"))
    }

    func test_renameBranch_conflictExhaustedAfter10Retries() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)
        // 占用 feat/auth 和 feat/auth-2 .. feat/auth-10
        _ = runGit(["branch", "feat/auth"], cwd: repo)
        for n in 2...10 {
            _ = runGit(["branch", "feat/auth-\(n)"], cwd: repo)
        }

        let wt = try Worktree.create(from: repo, sourceBranch: nil)

        switch wt.renameBranch(to: "feat/auth") {
        case .success(let final):
            XCTFail("expected exhaustion, got success final=\(final)")
        case .failure(.git(_, let isConflict)):
            XCTAssertTrue(isConflict, "should flag as branch conflict exhausted")
        case .failure(let err):
            XCTFail("unexpected error: \(err)")
        }

        XCTAssertEqual(currentBranch(at: wt.path), wt.name, "current branch stays initial on exhaustion")
    }

    func test_renameBranch_failsWhenBranchMissing() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)
        let wt = try Worktree.create(from: repo, sourceBranch: nil)

        // 把 worktree 切到另一个 branch，原 initial name branch 保留但 HEAD 指别处
        _ = runGit(["checkout", "-b", "other"], cwd: wt.path)

        // 构造一个"name 是根本不存在的 branch"的 Worktree 实例
        let bogus = Worktree(
            path: wt.path,
            name: "no-such-branch-xyz",
            baseRepo: repo,
            sourceBranch: nil
        )
        switch bogus.renameBranch(to: "target") {
        case .success:
            XCTFail("expected failure")
        case .failure(.git(_, let isConflict)):
            XCTAssertFalse(isConflict, "should not flag as conflict when source is missing")
        case .failure(let err):
            XCTFail("unexpected error: \(err)")
        }
    }
}

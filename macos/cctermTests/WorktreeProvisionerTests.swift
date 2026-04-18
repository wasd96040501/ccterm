import XCTest
@testable import ccterm

/// Covers `WorktreeProvisioner.createDetachedWorktree` — real `git` subprocess,
/// uses a fresh throw-away repo in `/tmp`. No network (so `refreshOriginIfStale`
/// may produce a no-op fetch via `--prune origin` when origin is absent; that's
/// tolerated — the function is non-fatal on fetch failure).
final class WorktreeProvisionerTests: XCTestCase {

    // MARK: - Git helpers (real subprocess)

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtp-test-\(UUID().uuidString.prefix(8))")
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

    private func initRepo(_ path: String, commits: [String] = ["initial"]) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        _ = runGit(["init", "-b", "main"], cwd: path)
        _ = runGit(["config", "user.email", "t@example.com"], cwd: path)
        _ = runGit(["config", "user.name", "t"], cwd: path)
        for (i, msg) in commits.enumerated() {
            let file = (path as NSString).appendingPathComponent("f\(i).txt")
            try "content \(i)".write(toFile: file, atomically: true, encoding: .utf8)
            _ = runGit(["add", "-A"], cwd: path)
            _ = runGit(["commit", "-m", msg], cwd: path)
        }
    }

    // MARK: - Happy path

    func test_createDetached_withNilSource_usesCurrentBranch() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)

        let wt = try WorktreeProvisioner.createDetachedWorktree(
            repoPath: repo,
            sourceBranch: nil
        )

        XCTAssertTrue(wt.hasPrefix(repo + "/.claude/worktrees/"), "worktree should live under <repo>/.claude/worktrees")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt))

        // worktree 应处于 detached HEAD
        let (status, output) = runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: wt)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "HEAD", "should be detached HEAD")
    }

    func test_createDetached_withExplicitSourceBranch_basesOnIt() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)
        _ = runGit(["checkout", "-b", "feat/x"], cwd: repo)
        let file = (repo as NSString).appendingPathComponent("x.txt")
        try "x content".write(toFile: file, atomically: true, encoding: .utf8)
        _ = runGit(["add", "-A"], cwd: repo)
        _ = runGit(["commit", "-m", "feat commit"], cwd: repo)
        let (_, featHead) = runGit(["rev-parse", "HEAD"], cwd: repo)

        let wt = try WorktreeProvisioner.createDetachedWorktree(
            repoPath: repo,
            sourceBranch: "feat/x"
        )
        let (_, wtHead) = runGit(["rev-parse", "HEAD"], cwd: wt)
        XCTAssertEqual(
            wtHead.trimmingCharacters(in: .whitespacesAndNewlines),
            featHead.trimmingCharacters(in: .whitespacesAndNewlines),
            "worktree HEAD 应等于 feat/x 顶端"
        )
    }

    func test_createDetached_enablesWorktreeConfigAndLongpaths() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)

        let wt = try WorktreeProvisioner.createDetachedWorktree(
            repoPath: repo,
            sourceBranch: nil
        )

        let (s1, out1) = runGit(["config", "--get", "extensions.worktreeConfig"], cwd: wt)
        XCTAssertEqual(s1, 0)
        XCTAssertEqual(out1.trimmingCharacters(in: .whitespacesAndNewlines), "true")

        let (s2, out2) = runGit(["config", "--worktree", "--get", "core.longpaths"], cwd: wt)
        XCTAssertEqual(s2, 0)
        XCTAssertEqual(out2.trimmingCharacters(in: .whitespacesAndNewlines), "true")
    }

    func test_createDetached_copiesSettingsLocalJson() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)
        let dotClaude = (repo as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(atPath: dotClaude, withIntermediateDirectories: true)
        let settingsLocal = (dotClaude as NSString).appendingPathComponent("settings.local.json")
        let content = #"{"foo":"bar"}"#
        try content.write(toFile: settingsLocal, atomically: true, encoding: .utf8)

        let wt = try WorktreeProvisioner.createDetachedWorktree(
            repoPath: repo,
            sourceBranch: nil
        )

        let copied = ((wt as NSString).appendingPathComponent(".claude") as NSString)
            .appendingPathComponent("settings.local.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied))
        let back = try String(contentsOfFile: copied, encoding: .utf8)
        XCTAssertEqual(back, content)
    }

    func test_createDetached_inheritsHuskyHooks() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)
        let husky = (repo as NSString).appendingPathComponent(".husky")
        try FileManager.default.createDirectory(atPath: husky, withIntermediateDirectories: true)
        let preCommit = (husky as NSString).appendingPathComponent("pre-commit")
        try "#!/bin/sh\nexit 0\n".write(toFile: preCommit, atomically: true, encoding: .utf8)

        let wt = try WorktreeProvisioner.createDetachedWorktree(
            repoPath: repo,
            sourceBranch: nil
        )

        let (status, output) = runGit(["config", "--worktree", "--get", "core.hooksPath"], cwd: wt)
        XCTAssertEqual(status, 0, "worktree 应有 --worktree core.hooksPath")
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(path, husky, "core.hooksPath 应指向 base 的 .husky 目录")
    }

    func test_createDetached_inheritsExplicitHooksPath() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)
        // base 显式配置 core.hooksPath（不用 .husky）
        let customHooks = (repo as NSString).appendingPathComponent("custom-hooks")
        try FileManager.default.createDirectory(atPath: customHooks, withIntermediateDirectories: true)
        _ = runGit(["config", "core.hooksPath", customHooks], cwd: repo)

        let wt = try WorktreeProvisioner.createDetachedWorktree(
            repoPath: repo,
            sourceBranch: nil
        )

        let (status, output) = runGit(["config", "--worktree", "--get", "core.hooksPath"], cwd: wt)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), customHooks)
    }

    // MARK: - Error paths

    func test_createDetached_rejectsNonGitDir() {
        let notRepo = tmpRoot.appendingPathComponent("plain-dir").path
        try? FileManager.default.createDirectory(atPath: notRepo, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try WorktreeProvisioner.createDetachedWorktree(repoPath: notRepo, sourceBranch: nil)
        ) { err in
            guard case WorktreeProvisioner.WorktreeError.notGitRepository = err else {
                return XCTFail("expected .notGitRepository, got \(err)")
            }
        }
    }

    func test_createDetached_errorsWhenSourceBranchDoesNotExist() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)

        XCTAssertThrowsError(
            try WorktreeProvisioner.createDetachedWorktree(
                repoPath: repo,
                sourceBranch: "does/not/exist"
            )
        ) { err in
            // 无分支可解析 → .detachedHeadWithoutSource
            guard case WorktreeProvisioner.WorktreeError.detachedHeadWithoutSource = err else {
                return XCTFail("expected .detachedHeadWithoutSource, got \(err)")
            }
        }
    }
}

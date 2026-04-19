import XCTest
@testable import ccterm

/// Covers `Worktree.create(from:sourceBranch:)` — 真 `git` 子进程，临时目录，
/// 不打网络（origin 不存在时 `refreshOriginIfStale` 的 fetch 失败不阻塞）。
final class WorktreeTests: XCTestCase {

    // MARK: - Git helpers

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-test-\(UUID().uuidString.prefix(8))")
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

    private func headBranch(at path: String) -> String {
        let (_, out) = runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let adjSciHexRegex = try! NSRegularExpression(
        pattern: "^[a-z]+-[a-z]+-[0-9a-f]{6}$"
    )

    private func matchesAdjSciHex(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return Self.adjSciHexRegex.firstMatch(in: s, range: range) != nil
    }

    // MARK: - Happy paths

    func test_create_withNilSource_usesCurrentBranch() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)

        let wt = try Worktree.create(from: repo, sourceBranch: nil)

        // 目录形状：<repo>/.claude/worktrees/<name>/（单层，无 projectName）
        let expectedPrefix = repo + "/.claude/worktrees/"
        XCTAssertTrue(wt.path.hasPrefix(expectedPrefix))
        let suffix = wt.path.dropFirst(expectedPrefix.count)
        XCTAssertFalse(suffix.contains("/"), "worktree dir must be single-level under .claude/worktrees/, got: \(wt.path)")

        // name 格式
        XCTAssertTrue(matchesAdjSciHex(wt.name), "name should match adj-sci-hex6, got: \(wt.name)")
        XCTAssertEqual((wt.path as NSString).lastPathComponent, wt.name)

        // 物理目录存在
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path))

        // HEAD 非 detached，指向 wt.name
        XCTAssertEqual(headBranch(at: wt.path), wt.name)

        // baseRepo 规范化后等于原 repo（本身就是 main repo）
        XCTAssertEqual(URL(fileURLWithPath: wt.baseRepo).resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: repo).resolvingSymlinksInPath().path)
    }

    func test_create_withExplicitSourceBranch_basesOnIt() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)
        _ = runGit(["checkout", "-b", "feat/x"], cwd: repo)
        let file = (repo as NSString).appendingPathComponent("x.txt")
        try "x content".write(toFile: file, atomically: true, encoding: .utf8)
        _ = runGit(["add", "-A"], cwd: repo)
        _ = runGit(["commit", "-m", "feat commit"], cwd: repo)

        let (_, featSHA) = runGit(["rev-parse", "feat/x"], cwd: repo)
        let featHEAD = featSHA.trimmingCharacters(in: .whitespacesAndNewlines)

        _ = runGit(["checkout", "main"], cwd: repo)

        let wt = try Worktree.create(from: repo, sourceBranch: "feat/x")

        let (_, wtSHA) = runGit(["rev-parse", "HEAD"], cwd: wt.path)
        XCTAssertEqual(wtSHA.trimmingCharacters(in: .whitespacesAndNewlines), featHEAD)
        XCTAssertEqual(wt.sourceBranch, "feat/x")
    }

    func test_create_enablesWorktreeConfigAndLongpaths() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)

        let wt = try Worktree.create(from: repo, sourceBranch: nil)

        let (ec1, out1) = runGit(["config", "--get", "extensions.worktreeConfig"], cwd: wt.path)
        XCTAssertEqual(ec1, 0)
        XCTAssertEqual(out1.trimmingCharacters(in: .whitespacesAndNewlines), "true")

        let (ec2, out2) = runGit(["config", "--worktree", "--get", "core.longpaths"], cwd: wt.path)
        XCTAssertEqual(ec2, 0)
        XCTAssertEqual(out2.trimmingCharacters(in: .whitespacesAndNewlines), "true")
    }

    func test_create_inheritsHuskyHooks() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)

        let husky = (repo as NSString).appendingPathComponent(".husky")
        try FileManager.default.createDirectory(atPath: husky, withIntermediateDirectories: true)
        let preCommit = (husky as NSString).appendingPathComponent("pre-commit")
        try "#!/bin/sh\necho hi".write(toFile: preCommit, atomically: true, encoding: .utf8)

        let wt = try Worktree.create(from: repo, sourceBranch: nil)

        let (ec, out) = runGit(["config", "--worktree", "--get", "core.hooksPath"], cwd: wt.path)
        XCTAssertEqual(ec, 0)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), husky)
    }

    func test_create_inheritsExplicitHooksPath() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)

        let customHooks = tmpRoot.appendingPathComponent("custom-hooks").path
        try FileManager.default.createDirectory(atPath: customHooks, withIntermediateDirectories: true)
        _ = runGit(["config", "core.hooksPath", customHooks], cwd: repo)

        let wt = try Worktree.create(from: repo, sourceBranch: nil)

        let (ec, out) = runGit(["config", "--worktree", "--get", "core.hooksPath"], cwd: wt.path)
        XCTAssertEqual(ec, 0)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), customHooks)
    }

    func test_create_copiesSettingsLocalJson() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)

        let claudeDir = (repo as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.local.json")
        try "{\"foo\":1}".write(toFile: settingsPath, atomically: true, encoding: .utf8)
        // .gitignore 忽略 .claude
        try ".claude/\n".write(
            toFile: (repo as NSString).appendingPathComponent(".gitignore"),
            atomically: true, encoding: .utf8)
        _ = runGit(["add", "-A"], cwd: repo)
        _ = runGit(["commit", "-m", "add gitignore"], cwd: repo)

        let wt = try Worktree.create(from: repo, sourceBranch: nil)

        let dest = (wt.path as NSString).appendingPathComponent(".claude/settings.local.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest))
        XCTAssertEqual(try String(contentsOfFile: dest, encoding: .utf8), "{\"foo\":1}")
    }

    func test_create_copiesWorktreeIncludeFiles() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)

        // gitignore .env
        try ".env\n".write(
            toFile: (repo as NSString).appendingPathComponent(".gitignore"),
            atomically: true, encoding: .utf8)
        _ = runGit(["add", "-A"], cwd: repo)
        _ = runGit(["commit", "-m", "add gitignore"], cwd: repo)

        // .env 存在但被忽略
        let envPath = (repo as NSString).appendingPathComponent(".env")
        try "SECRET=1".write(toFile: envPath, atomically: true, encoding: .utf8)

        // .worktreeinclude 声明 .env
        let includePath = (repo as NSString).appendingPathComponent(".worktreeinclude")
        try ".env\n# comment\n".write(toFile: includePath, atomically: true, encoding: .utf8)

        let wt = try Worktree.create(from: repo, sourceBranch: nil)

        let destEnv = (wt.path as NSString).appendingPathComponent(".env")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destEnv), "worktreeinclude 声明的 gitignored .env 应拷到 worktree")
        XCTAssertEqual(try String(contentsOfFile: destEnv, encoding: .utf8), "SECRET=1")
    }

    func test_create_copiesGitignoredClaudeSubtree() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)

        try ".claude/\n".write(
            toFile: (repo as NSString).appendingPathComponent(".gitignore"),
            atomically: true, encoding: .utf8)
        _ = runGit(["add", "-A"], cwd: repo)
        _ = runGit(["commit", "-m", "ignore .claude"], cwd: repo)

        // .claude/commands/foo.md gitignored
        let cmdDir = (repo as NSString).appendingPathComponent(".claude/commands")
        try FileManager.default.createDirectory(atPath: cmdDir, withIntermediateDirectories: true)
        let cmd = (cmdDir as NSString).appendingPathComponent("foo.md")
        try "# foo".write(toFile: cmd, atomically: true, encoding: .utf8)

        let wt = try Worktree.create(from: repo, sourceBranch: nil)

        let dest = (wt.path as NSString).appendingPathComponent(".claude/commands/foo.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest))
        XCTAssertEqual(try String(contentsOfFile: dest, encoding: .utf8), "# foo")
    }

    func test_create_normalizesBaseRepoWhenPathIsWorktree() throws {
        let mainRepo = tmpRoot.appendingPathComponent("main").path
        try initRepo(mainRepo)

        // 用 Worktree.create 产出 A，再以 A.path 当入参建 B。
        let a = try Worktree.create(from: mainRepo, sourceBranch: nil)
        let b = try Worktree.create(from: a.path, sourceBranch: nil)

        // 两端 resolveSymlinks 后比较（macOS tmp = /var → /private/var symlink）
        let resolvedMain = URL(fileURLWithPath: mainRepo).resolvingSymlinksInPath().path
        let resolvedBaseB = URL(fileURLWithPath: b.baseRepo).resolvingSymlinksInPath().path
        let resolvedPathB = URL(fileURLWithPath: b.path).resolvingSymlinksInPath().path

        XCTAssertEqual(resolvedBaseB, resolvedMain)
        XCTAssertTrue(resolvedPathB.hasPrefix(resolvedMain + "/.claude/worktrees/"),
                      "B.path should be under main repo's managed dir, got: \(b.path)")
    }

    // MARK: - Error paths

    func test_create_rejectsNonGitDir() throws {
        let plain = tmpRoot.appendingPathComponent("plain").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)

        do {
            _ = try Worktree.create(from: plain, sourceBranch: nil)
            XCTFail("expected notGitRepository")
        } catch Worktree.Error.notGitRepository {
            // ok
        }
    }

    func test_create_errorsWhenSourceBranchDoesNotExist() throws {
        let repo = tmpRoot.appendingPathComponent("repo").path
        try initRepo(repo)

        do {
            _ = try Worktree.create(from: repo, sourceBranch: "does/not/exist")
            XCTFail("expected detachedHeadWithoutSource")
        } catch Worktree.Error.detachedHeadWithoutSource {
            // ok
        }
    }
}

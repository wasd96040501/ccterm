import XCTest
import AgentSDK
@testable import ccterm

/// Covers `SessionHandle2.generateTitle(from:)` 与 `applyGeneratedTitle(_:)`。
///
/// 单元类只测正交入口的 guard / apply 行为——不起真 LLM，所以不覆盖 "已在生成中"
/// 和 "有 firstMessage" 的 happy path 任务启动（那会真的 Task.detached 去跑 CLI）。
/// 集成类真起 claude CLI，驱动 `generateTitle(from:)` 端到端。
@MainActor
final class SessionHandle2TitleGenTests: XCTestCase {

    // MARK: - Helpers

    private func makeRepo() -> SessionRepository {
        SessionRepository(coreDataStack: CoreDataStack(inMemory: true))
    }

    private func makeHandle(id: String, in repo: SessionRepository) -> SessionHandle2 {
        let h = SessionHandle2(sessionId: id, repository: repo)
        h.skipBootstrapForTesting = true
        return h
    }

    // MARK: - generateTitle(from:) guards (sync-only, no LLM)

    func test_generateTitle_emptyMessage_doesNotFlipFlag() {
        let repo = makeRepo()
        let handle = makeHandle(id: "gen-empty", in: repo)
        handle.start()

        handle.generateTitle(from: "")

        XCTAssertFalse(handle.isGeneratingTitle, "空 firstMessage 应直接 no-op")
    }

    func test_generateTitle_whenAlreadyGenerating_noop() {
        let repo = makeRepo()
        let handle = makeHandle(id: "gen-busy", in: repo)
        handle.start()
        handle.isGeneratingTitle = true  // 模拟已有生成任务在跑

        // 第二次调用：guard 命中直接返回，不会再起 Task
        handle.generateTitle(from: "second call ignored")

        XCTAssertTrue(handle.isGeneratingTitle, "已在生成中 → 不重复触发，也不改 flag")
    }

    // MARK: - applyGeneratedTitle (direct drive, no LLM)

    /// worktree 场景：apply 更新 title，worktreeBranch 保持 `start()` provision 的初始随机名不变。
    func test_applyGeneratedTitle_worktree_preservesInitialBranch() throws {
        let gitRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh2-apply-\(UUID().uuidString.prefix(8))")
            .path
        try initGitRepo(at: gitRoot)
        defer { try? FileManager.default.removeItem(atPath: gitRoot) }

        let sessionRepo = makeRepo()
        let handle = SessionHandle2(sessionId: "apply-keep", repository: sessionRepo)
        handle.skipBootstrapForTesting = true
        handle.isWorktree = true
        handle.originPath = gitRoot

        handle.start()

        let initialBranch = try XCTUnwrap(handle.worktreeBranch)
        handle.isGeneratingTitle = true  // 模拟进入生成中

        handle.applyGeneratedTitle(
            .init(title: "New Title", titleI18n: "New Title", branch: "feat/ignored")
        )

        XCTAssertFalse(handle.isGeneratingTitle)
        XCTAssertEqual(handle.title, "New Title")
        XCTAssertEqual(handle.worktreeBranch, initialBranch, "branch 应保持 provision 初始名")

        let record = sessionRepo.find("apply-keep")
        XCTAssertEqual(record?.title, "New Title")
        XCTAssertEqual(record?.worktreeBranch, initialBranch)

        // git 层：当前 branch 还是 initialBranch，feat/ignored 未创建
        let (_, cur) = runGit(["branch", "--show-current"], cwd: handle.cwd!)
        XCTAssertEqual(cur.trimmingCharacters(in: .whitespacesAndNewlines), initialBranch)
        let (_, list) = runGit(["branch", "--list", "--format=%(refname:short)"], cwd: gitRoot)
        XCTAssertTrue(list.contains(initialBranch))
        XCTAssertFalse(list.contains("feat/ignored"), "LLM 给的 branch 不应被挂载")
    }

    /// 非 worktree 会话：apply 只更新 title，不触碰 branch。
    func test_applyGeneratedTitle_nonWorktree_onlyUpdatesTitle() {
        let sessionRepo = makeRepo()
        let handle = SessionHandle2(sessionId: "apply-plain", repository: sessionRepo)
        handle.skipBootstrapForTesting = true
        handle.cwd = FileManager.default.temporaryDirectory.path
        handle.start()

        handle.applyGeneratedTitle(
            .init(title: "Plain Title", titleI18n: "Plain Title", branch: "feat/ignored")
        )

        XCTAssertEqual(handle.title, "Plain Title")
        XCTAssertNil(handle.worktreeBranch)
        XCTAssertNil(sessionRepo.find("apply-plain")?.worktreeBranch)
    }

    // MARK: - Integration — real LLM + optional worktree

    func test_integration_generateTitle_updatesTitleInHandleAndRepo() async throws {
        if ProcessInfo.processInfo.environment["SKIP_CLI_TESTS"] != nil {
            throw XCTSkip("SKIP_CLI_TESTS set")
        }

        let repo = makeRepo()
        let handle = SessionHandle2(sessionId: "title-int", repository: repo)
        handle.skipBootstrapForTesting = true  // 不关心 CLI bootstrap，只测 title-gen
        handle.cwd = FileManager.default.temporaryDirectory.path
        handle.start()

        handle.generateTitle(from: "Fix the login page crashing when users enter an empty password")
        XCTAssertTrue(handle.isGeneratingTitle, "入口同步翻转 flag")

        // 等 isGeneratingTitle 归零
        try await waitForFlag(handle, targetFalse: \.isGeneratingTitle, timeout: 30)

        XCTAssertFalse(handle.title.isEmpty, "handle.title 应被回写")
        let record = repo.find("title-int")
        XCTAssertEqual(record?.title, handle.title, "DB 与 handle 应同步")
    }

    func test_integration_generateTitle_withWorktree_keepsProvisionedBranch() async throws {
        if ProcessInfo.processInfo.environment["SKIP_CLI_TESTS"] != nil {
            throw XCTSkip("SKIP_CLI_TESTS set")
        }

        // 搭一个 real git repo
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh2-tg-wt-\(UUID().uuidString.prefix(8))")
            .path
        try initGitRepo(at: repo)
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let sessionRepo = makeRepo()
        let handle = SessionHandle2(sessionId: "title-int-wt", repository: sessionRepo)
        handle.skipBootstrapForTesting = true
        handle.isWorktree = true
        handle.originPath = repo

        handle.start()
        XCTAssertNotNil(handle.cwd, "worktree 应被 provision")
        let initialBranch = try XCTUnwrap(handle.worktreeBranch)

        handle.generateTitle(from: "Add dark mode toggle to settings page")
        XCTAssertTrue(handle.isGeneratingTitle)

        try await waitForFlag(handle, targetFalse: \.isGeneratingTitle, timeout: 30)

        XCTAssertFalse(handle.title.isEmpty)
        XCTAssertEqual(handle.worktreeBranch, initialBranch, "branch 应保持 provision 初始名不变")
        XCTAssertEqual(sessionRepo.find("title-int-wt")?.worktreeBranch, initialBranch)

        // 验证 worktree 真的还在 initial branch 上
        let (status, output) = runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: handle.cwd!)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), initialBranch)
    }

    // MARK: - Wait + git helpers

    private func waitForFlag<T: AnyObject>(
        _ handle: T,
        targetFalse path: KeyPath<T, Bool>,
        timeout: TimeInterval
    ) async throws {
        let start = Date()
        while handle[keyPath: path] {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("timed out waiting for flag to become false at \(path)")
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func initGitRepo(at path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        @discardableResult
        func run(_ args: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        _ = run(["init", "-b", "main"])
        _ = run(["config", "user.email", "t@example.com"])
        _ = run(["config", "user.name", "t"])
        let f = (path as NSString).appendingPathComponent("init.txt")
        try "x".write(toFile: f, atomically: true, encoding: .utf8)
        _ = run(["add", "-A"])
        _ = run(["commit", "-m", "init"])
    }

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
}

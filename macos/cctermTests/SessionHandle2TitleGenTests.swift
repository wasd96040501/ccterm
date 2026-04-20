import XCTest
import AgentSDK
@testable import ccterm

/// Covers stage 3：首次 `send()` 触发的 title LLM 流程。
///
/// 同步断言用 `skipTitleGenForTesting = true` + `skipBootstrapForTesting = true`，
/// 只验证 `needsTitleGen` / `isGeneratingTitle` flag 翻转和"只触发一次"的契约。
/// 集成用例真起 claude CLI，验证 title 被回写到 handle + repository。
@MainActor
final class SessionHandle2TitleGenTests: XCTestCase {

    // MARK: - Helpers

    private func makeRepo() -> SessionRepository {
        SessionRepository(coreDataStack: CoreDataStack(inMemory: true))
    }

    private func makeHandle(id: String, in repo: SessionRepository) -> SessionHandle2 {
        let h = SessionHandle2(sessionId: id, repository: repo)
        h.skipBootstrapForTesting = true
        h.skipTitleGenForTesting = true
        return h
    }

    // MARK: - Flag transitions (sync-only, no LLM)

    func test_firstSend_whenNeedsTitleGen_flipsFlags() {
        let repo = makeRepo()
        let handle = makeHandle(id: "flag-first", in: repo)
        handle.start()
        XCTAssertTrue(handle.needsTitleGen, "fresh + empty title → needsTitleGen=true")
        XCTAssertFalse(handle.isGeneratingTitle)

        handle.send(.text("hello world"))

        XCTAssertFalse(handle.needsTitleGen, "一旦消费就清零（防重复 Task）")
        XCTAssertTrue(handle.isGeneratingTitle, "generation 已起（虽然被 test hook 跳过）")
    }

    func test_secondSend_doesNotReTrigger() {
        let repo = makeRepo()
        let handle = makeHandle(id: "flag-second", in: repo)
        handle.start()

        handle.send(.text("first"))
        XCTAssertTrue(handle.isGeneratingTitle)

        // 模拟 generation 完成（正常情况下 Task 回调 main actor 置回）
        handle.isGeneratingTitle = false

        handle.send(.text("second"))
        XCTAssertFalse(handle.needsTitleGen)
        XCTAssertFalse(handle.isGeneratingTitle, "第二条不再触发 LLM")
    }

    func test_send_whenNotNeedsTitleGen_doesNothing() {
        let repo = makeRepo()
        // resume：repo 里已有记录 → needsTitleGen=false
        repo.save(SessionRecord(sessionId: "flag-resume", title: "existing", cwd: "/tmp"))
        let handle = SessionHandle2(sessionId: "flag-resume", repository: repo)
        handle.skipBootstrapForTesting = true
        handle.skipTitleGenForTesting = true
        handle.start()
        XCTAssertFalse(handle.needsTitleGen, "resume 不产 title")

        handle.send(.text("anything"))

        XCTAssertFalse(handle.isGeneratingTitle, "resume 下 send 不触发 gen")
    }

    func test_send_emptyText_doesNotTriggerGen() {
        let repo = makeRepo()
        let handle = makeHandle(id: "empty-text", in: repo)
        handle.start()
        XCTAssertTrue(handle.needsTitleGen)

        handle.send(.text(""))  // 空文本

        XCTAssertTrue(handle.needsTitleGen, "空文本不该消费 flag")
        XCTAssertFalse(handle.isGeneratingTitle)
    }

    func test_send_imageFirst_doesNotTriggerGen() {
        let repo = makeRepo()
        let handle = makeHandle(id: "image-first", in: repo)
        handle.start()

        handle.send(.image(Data([0x89, 0x50]), mediaType: "image/png"))

        XCTAssertTrue(handle.needsTitleGen, "image 不消费 title flag（只 text 触发）")
        XCTAssertFalse(handle.isGeneratingTitle)
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
        handle.skipTitleGenForTesting = true
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
        handle.skipTitleGenForTesting = true
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

    func test_integration_firstSend_updatesTitleInHandleAndRepo() async throws {
        if ProcessInfo.processInfo.environment["SKIP_CLI_TESTS"] != nil {
            throw XCTSkip("SKIP_CLI_TESTS set")
        }

        let repo = makeRepo()
        let handle = SessionHandle2(sessionId: "title-int", repository: repo)
        handle.skipBootstrapForTesting = true  // 不关心 CLI bootstrap，只测 title-gen
        handle.cwd = FileManager.default.temporaryDirectory.path
        handle.start()
        XCTAssertTrue(handle.needsTitleGen)

        handle.send(.text("Fix the login page crashing when users enter an empty password"))

        // 等 isGeneratingTitle 归零
        try await waitForFlag(handle, targetFalse: \.isGeneratingTitle, timeout: 30)

        XCTAssertFalse(handle.title.isEmpty, "handle.title 应被回写")
        let record = repo.find("title-int")
        XCTAssertEqual(record?.title, handle.title, "DB 与 handle 应同步")
    }

    func test_integration_firstSend_withWorktree_keepsProvisionedBranch() async throws {
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
        XCTAssertTrue(handle.needsTitleGen)

        handle.send(.text("Add dark mode toggle to settings page"))

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

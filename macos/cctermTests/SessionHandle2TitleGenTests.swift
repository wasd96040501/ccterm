import XCTest
import AgentSDK
@testable import ccterm

/// Covers stage 3：首次 `send()` 触发的 title/branch LLM 流程。
///
/// 同步断言用 `skipTitleGenForTesting = true` + `skipBootstrapForTesting = true`，
/// 只验证 `needsTitleGen` / `isGeneratingTitle` flag 翻转和"只触发一次"的契约。
/// 集成用例真起 claude CLI，验证 title 被回写到 handle + repository，worktree 场景
/// 下 branch 被 `git checkout -b` 挂载。
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

    // MARK: - applyGeneratedTitleAndBranch (direct drive, no LLM)

    /// worktree 场景：apply 应把 title 和 branch 都更新；branch 走 rename 路径。
    func test_applyGeneratedTitleAndBranch_renamesWorktreeBranch() throws {
        let gitRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh2-apply-\(UUID().uuidString.prefix(8))")
            .path
        try initGitRepo(at: gitRoot)
        defer { try? FileManager.default.removeItem(atPath: gitRoot) }

        let sessionRepo = makeRepo()
        let handle = SessionHandle2(sessionId: "apply-rename", repository: sessionRepo)
        handle.skipBootstrapForTesting = true
        handle.skipTitleGenForTesting = true
        handle.isWorktree = true
        handle.originPath = gitRoot

        handle.start()

        let initialBranch = try XCTUnwrap(handle.worktreeBranch)
        handle.isGeneratingTitle = true  // 模拟进入生成中

        handle.applyGeneratedTitleAndBranch(
            .init(title: "New Title", titleI18n: "New Title", branch: "feat/apply-test")
        )

        XCTAssertFalse(handle.isGeneratingTitle)
        XCTAssertEqual(handle.title, "New Title")
        XCTAssertEqual(handle.worktreeBranch, "feat/apply-test")

        let record = sessionRepo.find("apply-rename")
        XCTAssertEqual(record?.title, "New Title")
        XCTAssertEqual(record?.worktreeBranch, "feat/apply-test")

        // git 层：当前 branch 是 feat/apply-test，initial 名不在 branch 列表
        let (_, cur) = runGit(["branch", "--show-current"], cwd: handle.cwd!)
        XCTAssertEqual(cur.trimmingCharacters(in: .whitespacesAndNewlines), "feat/apply-test")
        let (_, list) = runGit(["branch", "--list", "--format=%(refname:short)"], cwd: gitRoot)
        XCTAssertFalse(list.contains(initialBranch), "initial branch should be gone after rename")
        XCTAssertTrue(list.contains("feat/apply-test"))
    }

    /// 目标 branch 已被占用 → rename 追加 `-2` 后缀。
    func test_applyGeneratedTitleAndBranch_conflict_takesSuffix() throws {
        let gitRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh2-apply-conflict-\(UUID().uuidString.prefix(8))")
            .path
        try initGitRepo(at: gitRoot)
        defer { try? FileManager.default.removeItem(atPath: gitRoot) }

        // 预先占掉目标 branch
        _ = runGit(["branch", "feat/clash"], cwd: gitRoot)

        let sessionRepo = makeRepo()
        let handle = SessionHandle2(sessionId: "apply-clash", repository: sessionRepo)
        handle.skipBootstrapForTesting = true
        handle.skipTitleGenForTesting = true
        handle.isWorktree = true
        handle.originPath = gitRoot

        handle.start()

        handle.applyGeneratedTitleAndBranch(
            .init(title: "X", titleI18n: "X", branch: "feat/clash")
        )

        XCTAssertEqual(handle.worktreeBranch, "feat/clash-2")
        XCTAssertEqual(sessionRepo.find("apply-clash")?.worktreeBranch, "feat/clash-2")
    }

    /// 10 个候选全占 → rename 耗尽，worktreeBranch 保留 initial。
    func test_applyGeneratedTitleAndBranch_rename_exhausted_keepsInitial() throws {
        let gitRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh2-apply-exhaust-\(UUID().uuidString.prefix(8))")
            .path
        try initGitRepo(at: gitRoot)
        defer { try? FileManager.default.removeItem(atPath: gitRoot) }

        _ = runGit(["branch", "feat/taken"], cwd: gitRoot)
        for n in 2...10 {
            _ = runGit(["branch", "feat/taken-\(n)"], cwd: gitRoot)
        }

        let sessionRepo = makeRepo()
        let handle = SessionHandle2(sessionId: "apply-exhaust", repository: sessionRepo)
        handle.skipBootstrapForTesting = true
        handle.skipTitleGenForTesting = true
        handle.isWorktree = true
        handle.originPath = gitRoot

        handle.start()
        let initial = try XCTUnwrap(handle.worktreeBranch)

        handle.applyGeneratedTitleAndBranch(
            .init(title: "X", titleI18n: "X", branch: "feat/taken")
        )

        XCTAssertEqual(handle.worktreeBranch, initial, "rename 耗尽 → 保留初始 branch")
        XCTAssertEqual(sessionRepo.find("apply-exhaust")?.worktreeBranch, initial)
    }

    /// 非 worktree 会话：apply 只更新 title，不触碰 branch。
    func test_applyGeneratedTitleAndBranch_nonWorktree_onlyUpdatesTitle() {
        let sessionRepo = makeRepo()
        let handle = SessionHandle2(sessionId: "apply-plain", repository: sessionRepo)
        handle.skipBootstrapForTesting = true
        handle.skipTitleGenForTesting = true
        handle.cwd = FileManager.default.temporaryDirectory.path
        handle.start()

        handle.applyGeneratedTitleAndBranch(
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

    func test_integration_firstSend_withWorktree_attachesBranch() async throws {
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
        XCTAssertTrue(handle.needsTitleGen)

        handle.send(.text("Add dark mode toggle to settings page"))

        try await waitForFlag(handle, targetFalse: \.isGeneratingTitle, timeout: 30)

        XCTAssertFalse(handle.title.isEmpty)
        // LLM 可能给英文 title → branch 非空；若给非 ASCII title → branch 空
        if let branch = handle.worktreeBranch {
            XCTAssertTrue(branch.hasPrefix("claude/"), "branch 必须是 claude/... 格式")
            let record = sessionRepo.find("title-int-wt")
            XCTAssertEqual(record?.worktreeBranch, branch)

            // 验证 worktree 真的在该 branch 上
            let (status, output) = runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: handle.cwd!)
            XCTAssertEqual(status, 0)
            XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), branch)
        } else {
            // LLM 给了非 ASCII title，branch 空（JMr 语义）——可接受
            NSLog("[TitleGenTest] LLM produced non-ASCII title, branch stayed nil (acceptable)")
        }
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

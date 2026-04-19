import XCTest
import AgentSDK
@testable import ccterm

/// Covers `SessionHandle2.start()` / `stop()` / `send(_:)` lifecycle.
///
/// 同步类：用 `skipBootstrapForTesting = true` 跳过真实 CLI，只断言
/// guard 逻辑、DB 写入路径、send queue 行为。
///
/// 集成类：真起 claude 子进程。由 `SKIP_CLI_TESTS=1` 环境变量关掉。
@MainActor
final class SessionHandle2StartTests: XCTestCase {

    // MARK: - Helpers

    private func makeRepo() -> SessionRepository {
        SessionRepository(coreDataStack: CoreDataStack(inMemory: true))
    }

    private func makeSyncHandle(id: String, in repo: SessionRepository) -> SessionHandle2 {
        let h = SessionHandle2(sessionId: id, repository: repo)
        h.skipBootstrapForTesting = true
        return h
    }

    // MARK: - start(): guard

    func test_start_ignored_whenAlreadyIdle() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "already-idle", in: repo)
        handle.status = .idle  // 模拟已启动

        handle.start()

        // 既未转 .starting 也未写 db
        XCTAssertEqual(handle.status, .idle)
        XCTAssertNil(repo.find("already-idle"))
    }

    func test_start_ignored_whenResponding() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "responding", in: repo)
        handle.status = .responding

        handle.start()

        XCTAssertEqual(handle.status, .responding)
        XCTAssertNil(repo.find("responding"))
    }

    func test_start_ignored_whenStarting() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "starting", in: repo)
        handle.status = .starting

        handle.start()

        XCTAssertEqual(handle.status, .starting)
        XCTAssertNil(repo.find("starting"))
    }

    // MARK: - start(): fresh path

    func test_start_fresh_transitionsToStarting() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "fresh-trans", in: repo)

        handle.start()

        XCTAssertEqual(handle.status, .starting)
        XCTAssertNil(handle.termination, "termination should be cleared on start()")
    }

    func test_start_fresh_savesCompleteRecord() {
        // 非 worktree 路径，避免触发 stage 2 的 git provision。worktree 的集成断言
        // 见 `test_start_isWorktree_provisionsWorktreeAndUpdatesCwd`。
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "fresh-save", in: repo)
        handle.title = "my chat"
        handle.cwd = "/tmp/work"
        handle.isWorktree = false
        handle.originPath = "/origin/repo"
        handle.model = "claude-opus-4-7"
        handle.effort = .high
        handle.permissionMode = .acceptEdits
        handle.additionalDirectories = ["/extra/a"]
        handle.pluginDirectories = ["/plug/a"]

        XCTAssertNil(repo.find("fresh-save"))

        handle.start()

        let rec = repo.find("fresh-save")
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.title, "my chat")
        XCTAssertEqual(rec?.cwd, "/tmp/work")
        XCTAssertFalse(rec?.isWorktree ?? true)
        XCTAssertEqual(rec?.originPath, "/origin/repo")
        XCTAssertEqual(rec?.extra.model, "claude-opus-4-7")
        XCTAssertEqual(rec?.extra.effort, "high")
        XCTAssertEqual(rec?.extra.permissionMode, "acceptEdits")
        XCTAssertEqual(rec?.extra.addDirs, ["/extra/a"])
        XCTAssertEqual(rec?.extra.pluginDirs, ["/plug/a"])
        XCTAssertEqual(rec?.status, .pending, "pending 直到 bootstrap 成功后改 .created")
    }

    func test_start_fresh_needsTitleGenFlagSet_whenTitleEmpty() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "fresh-needs-title", in: repo)
        // title 留空

        handle.start()

        XCTAssertTrue(handle.needsTitleGen, "fresh + 空 title 应触发 LLM 生成")
    }

    func test_start_fresh_needsTitleGenNotSet_whenTitleProvided() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "fresh-has-title", in: repo)
        handle.title = "already set"

        handle.start()

        XCTAssertFalse(handle.needsTitleGen, "调用方已给 title 就不重复生成")
    }

    // MARK: - start(): resume path

    func test_start_resume_overwritesCwdAndExtra() {
        let repo = makeRepo()
        let oldExtra = SessionExtra(
            pluginDirs: ["/old/plug"],
            permissionMode: ccterm.PermissionMode.default.rawValue,
            addDirs: ["/old/add"],
            model: "claude-old",
            effort: Effort.low.rawValue
        )
        repo.save(SessionRecord(
            sessionId: "resume",
            title: "old",
            cwd: "/old/cwd",
            extra: oldExtra
        ))

        let handle = SessionHandle2(sessionId: "resume", repository: repo)
        handle.skipBootstrapForTesting = true
        // 用户在 UI 改了这些字段
        handle.title = "new title"
        handle.cwd = "/new/cwd"
        handle.model = "claude-opus-4-7"
        handle.effort = .high
        handle.permissionMode = .acceptEdits
        handle.additionalDirectories = ["/new/add"]
        handle.pluginDirectories = ["/new/plug"]

        handle.start()

        let rec = repo.find("resume")
        XCTAssertEqual(rec?.cwd, "/new/cwd")
        XCTAssertEqual(rec?.title, "new title")
        XCTAssertEqual(rec?.extra.model, "claude-opus-4-7")
        XCTAssertEqual(rec?.extra.effort, "high")
        XCTAssertEqual(rec?.extra.permissionMode, "acceptEdits")
        XCTAssertEqual(rec?.extra.addDirs, ["/new/add"])
        XCTAssertEqual(rec?.extra.pluginDirs, ["/new/plug"])
    }

    func test_start_resume_doesNotSetNeedsTitleGen() {
        let repo = makeRepo()
        repo.save(SessionRecord(sessionId: "resume-title", title: "已有", cwd: "/tmp"))

        let handle = SessionHandle2(sessionId: "resume-title", repository: repo)
        handle.skipBootstrapForTesting = true

        handle.start()

        XCTAssertFalse(handle.needsTitleGen, "resume 不再生成 title")
    }

    // MARK: - send(): queue behaviors

    func test_send_whenNotStarted_queuesEntry() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "not-started-send", in: repo)

        handle.send(.text("hello world"))

        XCTAssertEqual(handle.messages.count, 1)
        XCTAssertEqual(handle.messages.first?.delivery, .queued)
        if case .user(let u) = handle.messages.first?.message,
           case .string(let s)? = u.message?.content {
            XCTAssertEqual(s, "hello world")
        } else {
            XCTFail("expected .user message with string content")
        }
    }

    func test_send_multiple_allQueued_whenNotStarted() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "multi-queued", in: repo)

        handle.send(.text("a"))
        handle.send(.text("b"))
        handle.send(.text("c"))

        XCTAssertEqual(handle.messages.count, 3)
        XCTAssertTrue(handle.messages.allSatisfy { $0.delivery == .queued })
    }

    func test_send_whenStopped_queuesEntry() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "stopped-send", in: repo)
        handle.status = .stopped

        handle.send(.text("during stopped"))

        XCTAssertEqual(handle.messages.count, 1)
        XCTAssertEqual(handle.messages.first?.delivery, .queued)
    }

    func test_send_whenIdleButNoAgentSession_doesNotFlush() {
        // 罕见边界：skipBootstrap 下 status 手动改 .idle，但 agentSession 仍 nil。
        // flushQueueIfNeeded 必须 guard 住，delivery 保持 .queued，不崩。
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "idle-no-session", in: repo)
        handle.status = .idle

        handle.send(.text("nowhere to go"))

        XCTAssertEqual(handle.messages.count, 1)
        XCTAssertEqual(handle.messages.first?.delivery, .queued)
        XCTAssertEqual(handle.status, .idle, "没 flush 就别改 .responding")
    }

    // MARK: - stop(): guard

    func test_stop_whenNotStarted_noOp() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "stop-notstarted", in: repo)
        handle.stop()
        XCTAssertEqual(handle.status, .notStarted)
    }

    func test_stop_whenStopped_noOp() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "stop-already", in: repo)
        handle.status = .stopped
        handle.stop()
        XCTAssertEqual(handle.status, .stopped)
    }

    // MARK: - Worktree integration (real git, no CLI)

    func test_start_isWorktree_provisionsWorktreeAndUpdatesCwd() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh2-wt-\(UUID().uuidString.prefix(8))")
            .path
        try initGitRepo(at: repo)
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let sessionRepo = makeRepo()
        let handle = SessionHandle2(sessionId: "wt-int", repository: sessionRepo)
        handle.skipBootstrapForTesting = true
        handle.isWorktree = true
        handle.originPath = repo

        handle.start()

        XCTAssertEqual(handle.status, .starting, "skipBootstrap 下只完成同步部分")
        XCTAssertNotNil(handle.cwd)
        // 新形状：<repo>/.claude/worktrees/<name>/ 单层
        XCTAssertTrue(handle.cwd?.hasPrefix(repo + "/.claude/worktrees/") ?? false,
                      "cwd should be under <repo>/.claude/worktrees/, got: \(handle.cwd ?? "nil")")
        let suffix = handle.cwd?.dropFirst(repo.count + "/.claude/worktrees/".count)
        XCTAssertFalse(suffix?.contains("/") ?? true, "worktree dir should be single-level, got: \(handle.cwd ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(atPath: handle.cwd ?? ""))

        // worktreeBranch 立即落上初始随机名（adj-sci-hex6）
        XCTAssertNotNil(handle.worktreeBranch)
        let adjSciHex = try! NSRegularExpression(pattern: "^[a-z]+-[a-z]+-[0-9a-f]{6}$")
        if let b = handle.worktreeBranch {
            let range = NSRange(b.startIndex..., in: b)
            XCTAssertNotNil(adjSciHex.firstMatch(in: b, range: range),
                            "worktreeBranch should match adj-sci-hex6, got: \(b)")
        }

        let record = sessionRepo.find("wt-int")
        XCTAssertEqual(record?.cwd, handle.cwd)
        XCTAssertTrue(record?.isWorktree ?? false)
        XCTAssertEqual(record?.originPath, repo)
        XCTAssertEqual(record?.worktreeBranch, handle.worktreeBranch,
                       "db worktreeBranch must match handle's initial name")
    }

    func test_start_isWorktree_errorsWhenOriginPathNotGitRepo() throws {
        let notRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh2-plain-\(UUID().uuidString.prefix(8))")
            .path
        try FileManager.default.createDirectory(atPath: notRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: notRepo) }

        let sessionRepo = makeRepo()
        let handle = SessionHandle2(sessionId: "wt-bad", repository: sessionRepo)
        handle.skipBootstrapForTesting = true
        handle.isWorktree = true
        handle.originPath = notRepo

        handle.start()

        XCTAssertEqual(handle.status, .stopped, "worktree provision 失败 → 直接 stopped")
        XCTAssertNotNil(handle.termination)
        XCTAssertNil(sessionRepo.find("wt-bad"), "worktree 失败路径不写 db")
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

    // MARK: - Integration (real claude CLI)

    func test_integration_freshStart_reachesIdle_andSetsCreatedStatus() async throws {
        if ProcessInfo.processInfo.environment["SKIP_CLI_TESTS"] != nil {
            throw XCTSkip("SKIP_CLI_TESTS set")
        }

        let repo = makeRepo()
        let sessionId = UUID().uuidString
        let handle = SessionHandle2(sessionId: sessionId, repository: repo)
        handle.cwd = FileManager.default.temporaryDirectory.path

        handle.start()
        XCTAssertEqual(handle.status, .starting)

        try await waitForStatus(handle, equal: .idle, timeout: 20)

        let rec = repo.find(sessionId)
        XCTAssertEqual(rec?.status, .created, "bootstrap 后应该 updateStatus(.created)")

        handle.stop()
    }

    func test_integration_sendBeforeStart_flushesAfterIdle() async throws {
        if ProcessInfo.processInfo.environment["SKIP_CLI_TESTS"] != nil {
            throw XCTSkip("SKIP_CLI_TESTS set")
        }

        let repo = makeRepo()
        let sessionId = UUID().uuidString
        let handle = SessionHandle2(sessionId: sessionId, repository: repo)
        handle.cwd = FileManager.default.temporaryDirectory.path

        // 先 send，后 start —— "先 send 后 start" 合法
        handle.send(.text("Reply with exactly: PONG"))
        XCTAssertEqual(handle.messages.count, 1)
        XCTAssertEqual(handle.messages.first?.delivery, .queued)

        handle.start()

        // 等 bootstrap 完成 + flush 完成 + turn 结束回到 idle
        try await waitForInFlightOrDelivered(handle, timeout: 25)

        // queued 的那条应已被 flush（delivery 变化）
        let entry = handle.messages.first
        XCTAssertNotNil(entry)
        XCTAssertNotEqual(entry?.delivery, .queued, "queued 应被 flush")

        handle.stop()
    }

    // MARK: - Wait helpers

    private func waitForStatus(
        _ handle: SessionHandle2,
        equal target: SessionHandle2.Status,
        timeout: TimeInterval
    ) async throws {
        let start = Date()
        while handle.status != target {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("timed out waiting for status=\(target), last=\(handle.status)")
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Wait until the first message transitions out of `.queued`.
    private func waitForInFlightOrDelivered(
        _ handle: SessionHandle2,
        timeout: TimeInterval
    ) async throws {
        let start = Date()
        while handle.messages.first?.delivery == .queued {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("timed out waiting for first message to leave .queued")
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

// MARK: - Status Equatable shim for test assertions

extension SessionHandle2.Status: Equatable {
    public static func == (lhs: SessionHandle2.Status, rhs: SessionHandle2.Status) -> Bool {
        switch (lhs, rhs) {
        case (.notStarted, .notStarted),
             (.starting, .starting),
             (.idle, .idle),
             (.responding, .responding),
             (.interrupting, .interrupting),
             (.stopped, .stopped):
            return true
        default:
            return false
        }
    }
}

import XCTest
import AgentSDK
@testable import ccterm

/// Covers `SessionHandle2.activate()` / `stop()` / `send(_:)` lifecycle.
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

    // MARK: - activate(): guard

    func test_activate_ignored_whenAlreadyIdle() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "already-idle", in: repo)
        handle.status = .idle  // 模拟已启动

        handle.activate()

        // 既未转 .starting 也未写 db
        XCTAssertEqual(handle.status, .idle)
        XCTAssertNil(repo.find("already-idle"))
    }

    func test_activate_ignored_whenResponding() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "responding", in: repo)
        handle.status = .responding

        handle.activate()

        XCTAssertEqual(handle.status, .responding)
        XCTAssertNil(repo.find("responding"))
    }

    func test_activate_ignored_whenStarting() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "starting", in: repo)
        handle.status = .starting

        handle.activate()

        XCTAssertEqual(handle.status, .starting)
        XCTAssertNil(repo.find("starting"))
    }

    // MARK: - activate(): fresh path

    func test_activate_fresh_transitionsToStarting() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "fresh-trans", in: repo)

        handle.activate()

        XCTAssertEqual(handle.status, .starting)
        XCTAssertNil(handle.termination, "termination should be cleared on activate()")
    }

    func test_activate_fresh_savesCompleteRecord() {
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

        handle.activate()

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

    // MARK: - activate(): resume path

    func test_activate_resume_overwritesCwdAndExtra() {
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

        handle.activate()

        let rec = repo.find("resume")
        XCTAssertEqual(rec?.cwd, "/new/cwd")
        XCTAssertEqual(rec?.title, "new title")
        XCTAssertEqual(rec?.extra.model, "claude-opus-4-7")
        XCTAssertEqual(rec?.extra.effort, "high")
        XCTAssertEqual(rec?.extra.permissionMode, "acceptEdits")
        XCTAssertEqual(rec?.extra.addDirs, ["/new/add"])
        XCTAssertEqual(rec?.extra.pluginDirs, ["/new/plug"])
    }

    // MARK: - send(): queue behaviors

    func test_send_whenNotStarted_queuesEntry() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "not-started-send", in: repo)

        handle.send(text: "hello world")

        XCTAssertEqual(handle.messages.count, 1)
        XCTAssertEqual(handle.messages.first?.delivery, .queued)
        if case .single(let s) = handle.messages.first,
           case .localUser(let input) = s.payload {
            XCTAssertEqual(input.text, "hello world")
            XCTAssertNil(input.image)
        } else {
            XCTFail("expected .localUser payload")
        }
    }

    func test_send_image_queuesLocalUserWithImagePayload() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "image-queue", in: repo)

        let data = Data([0x89, 0x50, 0x4E, 0x47])
        handle.send(image: data, mediaType: "image/png", caption: "look")

        XCTAssertEqual(handle.messages.count, 1)
        XCTAssertEqual(handle.messages.first?.delivery, .queued)
        guard case .single(let s) = handle.messages.first,
              case .localUser(let input) = s.payload else {
            XCTFail("expected .localUser payload"); return
        }
        XCTAssertEqual(input.text, "look")
        XCTAssertEqual(input.image?.data, data)
        XCTAssertEqual(input.image?.mediaType, "image/png")
        XCTAssertNil(input.planContent)
    }

    func test_send_multiple_allQueued_whenNotStarted() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "multi-queued", in: repo)

        handle.send(text: "a")
        handle.send(text: "b")
        handle.send(text: "c")

        XCTAssertEqual(handle.messages.count, 3)
        XCTAssertTrue(handle.messages.allSatisfy { $0.delivery == .queued })
    }

    func test_send_whenStopped_queuesEntry() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "stopped-send", in: repo)
        handle.status = .stopped

        handle.send(text: "during stopped")

        XCTAssertEqual(handle.messages.count, 1)
        XCTAssertEqual(handle.messages.first?.delivery, .queued)
    }

    func test_send_whenIdleButNoAgentSession_staysQueuedAndIdle() {
        // 罕见边界：skipBootstrap 下 status 手动改 .idle，但 agentSession 仍 nil。
        // send 走 ensureStarted（guard 掉 .idle，no-op），agentSession 为 nil → 不写 CLI，
        // entry 保持 .queued，status 不动。真正的 .responding 必须等 CLI echo 命中
        // matchQueuedEntry 才触发。
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "idle-no-session", in: repo)
        handle.status = .idle

        handle.send(text: "nowhere to go")

        XCTAssertEqual(handle.messages.count, 1)
        XCTAssertEqual(handle.messages.first?.delivery, .queued)
        XCTAssertEqual(handle.status, .idle, "没 CLI echo 就别改 .responding")
    }

    func test_send_whenNotStarted_autoActivates() {
        // send 自动调用 ensureStarted：fresh 下写 db + status .starting。
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "auto-activate", in: repo)
        handle.cwd = "/tmp/auto"

        handle.send(text: "auto start me")

        XCTAssertEqual(handle.status, .starting)
        XCTAssertEqual(handle.messages.count, 1)
        XCTAssertEqual(handle.messages.first?.delivery, .queued)
        XCTAssertNotNil(repo.find("auto-activate"), "ensureStarted 会 persistConfiguration")
    }

    // MARK: - CLI echo → .confirmed (feed fake Message2)

    /// 核心新逻辑：receive 收到同 uuid 的 user echo 时，本地 .queued entry 切 .confirmed，
    /// 且 status .idle → .responding（仅 live）。用 fake Message2 直接喂 receive，
    /// 不起 CLI，毫秒级验证。
    func test_receive_echoMatchesQueuedEntry_flipsToConfirmedAndResponding() {
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "echo-match", in: repo)
        handle.cwd = "/tmp/echo"
        handle.status = .idle  // 模拟 bootstrap 已完成

        handle.send(text: "hello")
        let entryId = handle.messages[0].id
        XCTAssertEqual(handle.messages[0].delivery, .queued)

        let echo = userEchoMessage(uuidString: entryId.uuidString.lowercased(), text: "hello")
        handle.receive(echo, mode: .live)

        XCTAssertEqual(handle.messages.count, 1, "不应 append 新 entry，本地原位更新")
        XCTAssertEqual(handle.messages[0].delivery, .confirmed)
        XCTAssertEqual(handle.status, .responding, "echo 到达应推进到 .responding")
        // payload 应从 .localUser 切换到 .remote(echo)
        guard case .single(let s) = handle.messages[0],
              case .remote(.user(_)) = s.payload else {
            XCTFail("expected payload swapped to .remote(.user(echo))"); return
        }
    }

    func test_receive_echoWithUnknownUuid_appendsNewEntry() {
        // CLI emit 一条本地找不到 .queued 匹配的 user echo（比如 interrupt 后 CLI
        // 仍处理队列里的消息，但本地 entry 已被 cancelMessage 移除）——走 append。
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "echo-orphan", in: repo)
        handle.status = .idle

        let orphan = userEchoMessage(uuidString: UUID().uuidString.lowercased(), text: "orphan")
        handle.receive(orphan, mode: .live)

        XCTAssertEqual(handle.messages.count, 1, "无匹配 queued → append")
        XCTAssertNil(handle.messages[0].delivery, "append 的 entry delivery 为 nil")
    }

    func test_receive_replayMode_doesNotAdvanceStatus() {
        // replay 路径（加载历史）不应改 status。
        let repo = makeRepo()
        let handle = makeSyncHandle(id: "echo-replay", in: repo)
        handle.status = .idle

        handle.send(text: "hi")
        let entryId = handle.messages[0].id

        let echo = userEchoMessage(uuidString: entryId.uuidString.lowercased(), text: "hi")
        handle.receive(echo, mode: .replay)

        XCTAssertEqual(handle.messages[0].delivery, .confirmed, "replay 也切 confirmed")
        XCTAssertEqual(handle.status, .idle, "replay 不推进 status")
    }

    // MARK: - Failure paths: .queued → .failed

    func test_activate_worktreeProvisionFailed_failsQueuedEntries() {
        // send 先入队，再 activate 触发 worktree provision（originPath 不是 git repo）
        // → status .stopped，entry delivery .failed。
        let notRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh2-failq-\(UUID().uuidString.prefix(8))")
            .path
        try? FileManager.default.createDirectory(atPath: notRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: notRepo) }

        let repo = makeRepo()
        let handle = SessionHandle2(sessionId: "wt-failq", repository: repo)
        handle.skipBootstrapForTesting = true
        handle.isWorktree = true
        handle.originPath = notRepo

        handle.send(text: "will fail")

        XCTAssertEqual(handle.status, .stopped)
        XCTAssertEqual(handle.messages.count, 1)
        if case .failed(let reason) = handle.messages[0].delivery {
            XCTAssertTrue(reason.contains("worktree provision"), "failure reason: \(reason)")
        } else {
            XCTFail("expected .failed, got \(String(describing: handle.messages[0].delivery))")
        }
    }

    // MARK: - Test fixtures

    /// 构造一条 CLI replay-user-messages 风格的 user echo（带 uuid 字段）。
    private func userEchoMessage(uuidString: String, text: String) -> Message2 {
        let raw: [String: Any] = [
            "type": "user",
            "uuid": uuidString,
            "message": [
                "role": "user",
                "content": text,
            ],
        ]
        return (try? Message2(json: raw)) ?? Message2.unknown(name: "user", raw: raw)
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

    func test_activate_isWorktree_provisionsWorktreeAndUpdatesCwd() throws {
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

        handle.activate()

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

    func test_activate_isWorktree_errorsWhenOriginPathNotGitRepo() throws {
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

        handle.activate()

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

    func test_integration_freshActivate_reachesIdle_andSetsCreatedStatus() async throws {
        if ProcessInfo.processInfo.environment["SKIP_CLI_TESTS"] != nil {
            throw XCTSkip("SKIP_CLI_TESTS set")
        }

        let repo = makeRepo()
        let sessionId = UUID().uuidString
        let handle = SessionHandle2(sessionId: sessionId, repository: repo)
        handle.cwd = FileManager.default.temporaryDirectory.path

        handle.activate()
        XCTAssertEqual(handle.status, .starting)

        try await waitForStatus(handle, equal: .idle, timeout: 20)

        let rec = repo.find(sessionId)
        XCTAssertEqual(rec?.status, .created, "bootstrap 后应该 updateStatus(.created)")

        handle.stop()
    }

    func test_integration_sendAutoActivates_andConfirmsViaEcho() async throws {
        if ProcessInfo.processInfo.environment["SKIP_CLI_TESTS"] != nil {
            throw XCTSkip("SKIP_CLI_TESTS set")
        }

        let repo = makeRepo()
        let sessionId = UUID().uuidString
        let handle = SessionHandle2(sessionId: sessionId, repository: repo)
        handle.cwd = FileManager.default.temporaryDirectory.path

        // send 自动触发 ensureStarted，CLI bootstrap 后 flushBootstrapBacklog 写 stdin，
        // CLI echo user 消息带同 uuid → entry.delivery 切 .confirmed。
        handle.send(text: "Reply with exactly: PONG")
        XCTAssertEqual(handle.messages.count, 1)
        XCTAssertEqual(handle.messages.first?.delivery, .queued)
        XCTAssertEqual(handle.status, .starting, "send 应自动 ensureStarted")

        try await waitForEntryLeavesQueued(handle, timeout: 25)

        let entry = handle.messages.first
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.delivery, .confirmed, "收到 CLI echo 后应 .confirmed")

        handle.stop()
    }

    /// 端到端：image send → CLI 走 contentBlocks 重载 → echo 回来 payload 切 .remote 且
    /// content 里保留 image block。覆盖 `send(image:)` + `writeUserEntryToCLI` 的 array
    /// 分支 + `confirmQueuedEntry` 的 payload 替换。
    func test_integration_sendImage_viaContentBlocks_confirmsViaEcho() async throws {
        if ProcessInfo.processInfo.environment["SKIP_CLI_TESTS"] != nil {
            throw XCTSkip("SKIP_CLI_TESTS set")
        }

        // 1x1 红色 PNG，足以走通 CLI replay；是否调模型成功不影响本测试关注的 wire 路径。
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNi+P//PwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
        guard let pngData = Data(base64Encoded: pngBase64) else {
            XCTFail("failed to decode test PNG"); return
        }

        let repo = makeRepo()
        let sessionId = UUID().uuidString
        let handle = SessionHandle2(sessionId: sessionId, repository: repo)
        handle.cwd = FileManager.default.temporaryDirectory.path

        handle.send(image: pngData, mediaType: "image/png", caption: "desc")
        let entryId = handle.messages.first?.id
        XCTAssertNotNil(entryId)
        XCTAssertEqual(handle.messages.first?.delivery, .queued)

        try await waitForEntryLeavesQueued(handle, timeout: 25)

        guard case .single(let single) = handle.messages.first else {
            XCTFail("expected single entry"); return
        }
        XCTAssertEqual(single.delivery, .confirmed, "echo 到达后应 .confirmed")
        guard case .remote(.user(let u)) = single.payload else {
            XCTFail("payload should be .remote(.user(echo)) after confirm"); return
        }
        // echo 保留 array content，且有一个 image block。
        guard case .array(let items)? = u.message?.content else {
            XCTFail("echo content should be array, got: \(String(describing: u.message?.content))"); return
        }
        let hasImage = items.contains { if case .image = $0 { return true } else { return false } }
        XCTAssertTrue(hasImage, "echo content array 应含 image block")

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
    private func waitForEntryLeavesQueued(
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

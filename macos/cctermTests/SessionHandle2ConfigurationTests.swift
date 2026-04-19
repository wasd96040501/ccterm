import XCTest
import AgentSDK
@testable import ccterm

/// Covers `SessionHandle2` set* / respond / setFocused.
///
/// 同步测试只覆盖 "改内存 + 写 db"；attached 下的 RPC 路径需要真 agentSession，
/// 由集成测试或 SessionService 层面的测试覆盖。
@MainActor
final class SessionHandle2ConfigurationTests: XCTestCase {

    // MARK: - Helpers

    private func makeRepo() -> SessionRepository {
        SessionRepository(coreDataStack: CoreDataStack(inMemory: true))
    }

    private func makeHandle(id: String, in repo: SessionRepository) -> SessionHandle2 {
        let h = SessionHandle2(sessionId: id, repository: repo)
        h.skipBootstrapForTesting = true
        return h
    }

    /// 先 start() 一次把 record 落 db，再手动把 status 改回 .stopped，
    /// 模拟 "已 start 过、当前非 active" 的状态。
    private func startThenStop(_ handle: SessionHandle2) {
        handle.start()
        handle.status = .stopped
    }

    // MARK: - setModel

    func test_setModel_fresh_memoryOnly_noDB() {
        let repo = makeRepo()
        let h = makeHandle(id: "set-model-fresh", in: repo)

        h.setModel("claude-opus-4-7")

        XCTAssertEqual(h.model, "claude-opus-4-7")
        XCTAssertNil(repo.find("set-model-fresh"), "fresh .notStarted 不创建 record")
    }

    func test_setModel_afterStart_updatesDB() {
        let repo = makeRepo()
        let h = makeHandle(id: "set-model-started", in: repo)
        h.cwd = "/tmp/m"
        startThenStop(h)

        h.setModel("claude-sonnet-4-6")

        XCTAssertEqual(h.model, "claude-sonnet-4-6")
        XCTAssertEqual(repo.find("set-model-started")?.extra.model, "claude-sonnet-4-6")
    }

    func test_setModel_resume_updatesDB() {
        let repo = makeRepo()
        repo.save(SessionRecord(
            sessionId: "resume-model",
            title: "r",
            cwd: "/r",
            extra: SessionExtra(model: "old")
        ))
        let h = makeHandle(id: "resume-model", in: repo)

        h.setModel("new")

        XCTAssertEqual(h.model, "new")
        XCTAssertEqual(repo.find("resume-model")?.extra.model, "new")
    }

    // MARK: - setEffort

    func test_setEffort_fresh_memoryOnly() {
        let repo = makeRepo()
        let h = makeHandle(id: "e-fresh", in: repo)

        h.setEffort(.high)

        XCTAssertEqual(h.effort, .high)
        XCTAssertNil(repo.find("e-fresh"))
    }

    func test_setEffort_afterStart_updatesDB() {
        let repo = makeRepo()
        let h = makeHandle(id: "e-started", in: repo)
        h.cwd = "/tmp/e"
        startThenStop(h)

        h.setEffort(.low)

        XCTAssertEqual(h.effort, .low)
        XCTAssertEqual(repo.find("e-started")?.extra.effort, "low")
    }

    // MARK: - setPermissionMode

    func test_setPermissionMode_fresh_memoryOnly() {
        let repo = makeRepo()
        let h = makeHandle(id: "pm-fresh", in: repo)

        h.setPermissionMode(.acceptEdits)

        XCTAssertEqual(h.permissionMode, .acceptEdits)
        XCTAssertNil(repo.find("pm-fresh"))
    }

    func test_setPermissionMode_afterStart_updatesDB() {
        let repo = makeRepo()
        let h = makeHandle(id: "pm-started", in: repo)
        h.cwd = "/tmp/p"
        startThenStop(h)

        h.setPermissionMode(.plan)

        XCTAssertEqual(h.permissionMode, .plan)
        XCTAssertEqual(repo.find("pm-started")?.extra.permissionMode, "plan")
    }

    // MARK: - setCwd / setWorktree — non-active only

    func test_setCwd_notStarted_writesMemory() {
        let repo = makeRepo()
        let h = makeHandle(id: "cwd", in: repo)

        h.setCwd("/new/cwd")

        XCTAssertEqual(h.cwd, "/new/cwd")
    }

    func test_setCwd_stopped_writesMemoryAndDB() {
        let repo = makeRepo()
        let h = makeHandle(id: "cwd-stopped", in: repo)
        h.cwd = "/tmp/x"
        startThenStop(h)

        h.setCwd("/changed")

        XCTAssertEqual(h.cwd, "/changed")
        XCTAssertEqual(repo.find("cwd-stopped")?.cwd, "/changed")
    }

    func test_setCwd_ignoredWhenAttached() {
        let repo = makeRepo()
        let h = makeHandle(id: "cwd-attached", in: repo)
        h.cwd = "/before"
        h.status = .idle  // 模拟 attached

        h.setCwd("/ignored")

        XCTAssertEqual(h.cwd, "/before")
    }

    func test_setWorktree_notStarted_writesMemory() {
        let repo = makeRepo()
        let h = makeHandle(id: "wt-fresh", in: repo)

        h.setWorktree(true)

        XCTAssertTrue(h.isWorktree)
    }

    func test_setWorktree_stopped_writesDB() {
        let repo = makeRepo()
        let h = makeHandle(id: "wt-stopped", in: repo)
        h.cwd = "/tmp/w"
        startThenStop(h)

        h.setWorktree(true)

        XCTAssertTrue(h.isWorktree)
        XCTAssertEqual(repo.find("wt-stopped")?.isWorktree, true)
    }

    func test_setWorktree_ignoredWhenAttached() {
        let repo = makeRepo()
        let h = makeHandle(id: "wt-attached", in: repo)
        h.status = .responding

        h.setWorktree(true)

        XCTAssertFalse(h.isWorktree)
    }

    // MARK: - setAdditionalDirectories / setPluginDirectories

    func test_setAdditionalDirectories_stopped_writesDB() {
        let repo = makeRepo()
        let h = makeHandle(id: "adddirs", in: repo)
        h.cwd = "/tmp/a"
        startThenStop(h)

        h.setAdditionalDirectories(["/a", "/b"])

        XCTAssertEqual(h.additionalDirectories, ["/a", "/b"])
        XCTAssertEqual(repo.find("adddirs")?.extra.addDirs, ["/a", "/b"])
    }

    func test_setAdditionalDirectories_ignoredWhenAttached() {
        let repo = makeRepo()
        let h = makeHandle(id: "adddirs-attached", in: repo)
        h.additionalDirectories = ["/kept"]
        h.status = .idle

        h.setAdditionalDirectories(["/nope"])

        XCTAssertEqual(h.additionalDirectories, ["/kept"])
    }

    func test_setPluginDirectories_stopped_writesDB() {
        let repo = makeRepo()
        let h = makeHandle(id: "plugs", in: repo)
        h.cwd = "/tmp/p"
        startThenStop(h)

        h.setPluginDirectories(["/plug1"])

        XCTAssertEqual(h.pluginDirectories, ["/plug1"])
        XCTAssertEqual(repo.find("plugs")?.extra.pluginDirs, ["/plug1"])
    }

    // MARK: - respond(to:decision:)

    func test_respond_removesMatchingPermission() {
        let repo = makeRepo()
        let h = makeHandle(id: "resp", in: repo)

        var lastDecision: PermissionDecision?
        let pending = PendingPermission(
            id: "req-1",
            request: PermissionRequest.makePreview(requestId: "req-1", toolName: "Bash", input: [:]),
            respond: { decision in
                lastDecision = decision
                // handle 侧应从 pendingPermissions 移除
                h.pendingPermissions.removeAll { $0.id == "req-1" }
            }
        )
        h.pendingPermissions.append(pending)

        h.respond(to: "req-1", decision: .allow())

        if case .allow = lastDecision {
            // ok
        } else {
            XCTFail("expected .allow, got \(String(describing: lastDecision))")
        }
        XCTAssertTrue(h.pendingPermissions.isEmpty)
    }

    func test_respond_noOpForUnknownId() {
        let repo = makeRepo()
        let h = makeHandle(id: "resp-nop", in: repo)
        var called = false
        h.pendingPermissions.append(PendingPermission(
            id: "keep",
            request: PermissionRequest.makePreview(requestId: "keep", toolName: "Bash", input: [:]),
            respond: { _ in called = true }
        ))

        h.respond(to: "missing", decision: .deny(reason: "no"))

        XCTAssertFalse(called)
        XCTAssertEqual(h.pendingPermissions.count, 1)
    }

    // MARK: - setFocused

    func test_setFocused_true_clearsUnread() {
        let repo = makeRepo()
        let h = makeHandle(id: "focus", in: repo)
        h.hasUnread = true
        h.isFocused = false

        h.setFocused(true)

        XCTAssertTrue(h.isFocused)
        XCTAssertFalse(h.hasUnread)
    }

    func test_setFocused_false_keepsUnread() {
        let repo = makeRepo()
        let h = makeHandle(id: "blur", in: repo)
        h.hasUnread = true
        h.isFocused = true

        h.setFocused(false)

        XCTAssertFalse(h.isFocused)
        XCTAssertTrue(h.hasUnread, "setFocused(false) 不动 hasUnread")
    }
}

import XCTest
import AgentSDK
@testable import ccterm

/// SessionHandle2 单元测试。
///
/// 不启真子进程：用 FakeSessionBackend / FakeSessionBridge 注入，
/// 通过调用 backend 上的回调闭包模拟 CLI 推送。
///
/// 所有测试为 async：SessionHandle2 的回调用 `Task { @MainActor }` 包裹，
/// 测试需要 `await Task.yield()` 让这些 pending Task 执行后再断言。
@MainActor
final class SessionHandle2Tests: XCTestCase {

    // MARK: - #1 Initial State

    func test_initialState() async {
        let (handle, _, _) = makeHandle()

        XCTAssertEqual(handle.sessionId, "s1")
        XCTAssertEqual(handle.workspace.cwd, "/init")
        XCTAssertEqual(handle.workspace.isWorktree, false)
        XCTAssertEqual(handle.permissionMode, .default)
        XCTAssertEqual(handle.model, "sonnet")
        XCTAssertEqual(handle.effort, .medium)

        XCTAssertEqual(handle.status, .inactive)
        XCTAssertTrue(handle.slashCommands.isEmpty)
        XCTAssertTrue(handle.pendingPermissions.isEmpty)
        XCTAssertTrue(handle.queuedMessages.isEmpty)
        XCTAssertFalse(handle.branchGenerating)
        XCTAssertEqual(handle.historyLoadState, .notLoaded)

        XCTAssertFalse(handle.isFocused)
        XCTAssertFalse(handle.hasUnread)
        XCTAssertNil(handle.unshownExitError)
        XCTAssertNil(handle.contextUsage)
    }

    // MARK: - #2 Send (idle / busy / auto-flush)

    func test_send_idleBusyAndAutoFlush() async {
        let (handle, backend, bridge) = await makeAttached()

        // idle → 直发
        handle.send("first")
        XCTAssertEqual(backend.sentMessages.count, 1)
        XCTAssertEqual(backend.sentMessages[0].text, "first")
        XCTAssertEqual(handle.status, .responding)
        XCTAssertEqual(bridge.forwardedMessages.last?.messageJSON["type"] as? String, "user")
        XCTAssertEqual(bridge.turnActiveCalls.last?.isTurnActive, true)

        // busy → 入队
        handle.send("queued-1")
        handle.send("queued-2")
        XCTAssertEqual(handle.queuedMessages, ["queued-1", "queued-2"])
        XCTAssertEqual(backend.sentMessages.count, 1, "busy 时不应再调 backend")

        // 发 result 消息模拟一轮结束 → 自动 flush 合并
        await backend.deliver(makeResultSuccessMessage())
        XCTAssertTrue(handle.queuedMessages.isEmpty)
        XCTAssertEqual(backend.sentMessages.count, 2)
        XCTAssertEqual(backend.sentMessages[1].text, "queued-1\n\nqueued-2")
        XCTAssertEqual(handle.status, .responding, "flush 后重新进入 responding")
    }

    // MARK: - #3 Interrupt

    func test_interrupt_completesAndResumes() async {
        let (handle, backend, bridge) = await makeAttached()

        // 未 responding 时 interrupt 无效
        handle.interrupt()
        XCTAssertEqual(backend.interruptCallCount, 0)

        handle.send("hello")
        XCTAssertEqual(handle.status, .responding)

        handle.interrupt()
        XCTAssertEqual(handle.status, .interrupting)
        XCTAssertEqual(backend.interruptCallCount, 1)

        // backend completion → 回到 idle + 通知 bridge interrupted
        backend.fireInterruptCompletion()
        await yieldSeveral()

        XCTAssertEqual(handle.status, .idle)
        XCTAssertEqual(bridge.turnActiveCalls.last?.interrupted, true)
        XCTAssertEqual(bridge.turnActiveCalls.last?.isTurnActive, false)
    }

    // MARK: - #4 Configure

    func test_configure_all3Cases() async {
        let (handle, backend, _) = await makeAttached()

        handle.configure(.permissionMode(.plan))
        XCTAssertEqual(handle.permissionMode, .plan)
        XCTAssertEqual(backend.permissionModeSet, .plan)

        handle.configure(.model("haiku"))
        XCTAssertEqual(handle.model, "haiku")
        XCTAssertEqual(backend.modelSet, "haiku")

        handle.configure(.effort(.high))
        XCTAssertEqual(handle.effort, .high)
        XCTAssertEqual(backend.effortSet, .high)
    }

    // MARK: - #5 sessionInit

    func test_sessionInit_populatesAndFulfills() async throws {
        let bridge = FakeSessionBridge()
        let backend = FakeSessionBackend()
        let handle = SessionHandle2(
            sessionId: "s1",
            workspace: Workspace(cwd: "/init", isWorktree: false),
            permissionMode: .default,
            model: "sonnet",
            effort: .medium,
            bridge: bridge
        )
        handle.attach(backend: backend, bridge: bridge)
        XCTAssertEqual(handle.status, .starting)

        // 异步等 sessionInit
        let waitTask = Task { @MainActor in
            try await handle.waitForSessionInit()
        }

        await yieldSeveral()

        // 喂 sessionInit 消息
        await backend.deliver(makeInitMessage(
            cwd: "/new-cwd",
            slashCommands: ["help", "clear"],
            permissionMode: "acceptEdits"
        ))

        XCTAssertEqual(handle.workspace.cwd, "/new-cwd")
        XCTAssertEqual(handle.slashCommands.map(\.name), ["help", "clear"])
        XCTAssertEqual(handle.permissionMode, .acceptEdits)
        XCTAssertEqual(handle.status, .idle)

        try await waitTask.value  // 应正常返回
    }

    // MARK: - #6 Context Usage

    func test_contextUsage_fromMessages() async {
        let (handle, backend, _) = await makeAttached()

        // assistant 含 usage → contextUsage.used 有值（window 尚无）
        await backend.deliver(makeAssistantMessage(inputTokens: 1000, model: "claude-sonnet"))
        XCTAssertEqual(handle.contextUsage?.used, 1000)

        // result 含 modelUsage.contextWindow → window 填充
        await backend.deliver(makeResultSuccessMessage(modelUsageContextWindow: ("claude-sonnet", 200_000)))
        XCTAssertEqual(handle.contextUsage?.window, 200_000)

        // 再来一条 assistant → used 更新，window 用缓存保留
        await backend.deliver(makeAssistantMessage(inputTokens: 5000, model: "claude-sonnet"))
        XCTAssertEqual(handle.contextUsage?.used, 5000)
        XCTAssertEqual(handle.contextUsage?.window, 200_000)
    }

    // MARK: - #7 PathChange (enter / exit worktree)

    func test_pathChange_updatesWorkspace() async {
        let (handle, backend, _) = await makeAttached()

        await backend.deliver(makeEnterWorktreeUserMessage(worktreePath: "/wt-branch"))
        XCTAssertEqual(handle.workspace.cwd, "/wt-branch")
        XCTAssertTrue(handle.workspace.isWorktree)

        await backend.deliver(makeExitWorktreeUserMessage(originalCwd: "/init"))
        XCTAssertEqual(handle.workspace.cwd, "/init")
        XCTAssertFalse(handle.workspace.isWorktree)
    }

    // MARK: - #8 Permission Lifecycle

    func test_permission_lifecycle() async {
        let (handle, backend, _) = await makeAttached()

        var decisionReceived: PermissionDecision?
        await backend.firePermissionRequest(
            PermissionRequest.makePreview(requestId: "req-1", toolName: "Bash", input: [:])
        ) { decision in
            decisionReceived = decision
        }

        XCTAssertEqual(handle.pendingPermissions.count, 1)
        XCTAssertEqual(handle.pendingPermissions[0].id, "req-1")

        // 决策 → 回调 CLI + 自动移除
        handle.pendingPermissions[0].respond(.allow(updatedInput: nil))
        await yieldSeveral()

        if case .allow = decisionReceived {} else {
            XCTFail("expected .allow decision")
        }
        XCTAssertTrue(handle.pendingPermissions.isEmpty)

        // 再来一个权限，然后由 CLI 取消
        await backend.firePermissionRequest(
            PermissionRequest.makePreview(requestId: "req-2", toolName: "Edit", input: [:])
        ) { _ in }
        XCTAssertEqual(handle.pendingPermissions.count, 1)

        await backend.firePermissionCancelled("req-2")
        XCTAssertTrue(handle.pendingPermissions.isEmpty)
    }

    // MARK: - #9 Process Exit + Error Dismiss

    func test_processExit_completeFlow() async {
        let (handle, backend, _) = await makeAttached()

        // 先累积一些 stderr 和 pending permission
        await backend.fireStderr("fatal: something broke\n")
        var denialReason: String?
        await backend.firePermissionRequest(
            PermissionRequest.makePreview(requestId: "r", toolName: "Bash", input: [:])
        ) { decision in
            if case .deny(let reason, _) = decision { denialReason = reason }
        }

        // 非零退出
        await backend.fireProcessExit(1)

        XCTAssertEqual(handle.status, .inactive)
        XCTAssertEqual(handle.unshownExitError?.exitCode, 1)
        XCTAssertEqual(handle.unshownExitError?.stderr, "fatal: something broke\n")
        XCTAssertTrue(handle.pendingPermissions.isEmpty)
        XCTAssertEqual(denialReason, "Process exited")

        // dismiss 清零
        handle.dismissExitError()
        XCTAssertNil(handle.unshownExitError)

        // 零退出不设错误
        let (handle2, backend2, _) = await makeAttached()
        await backend2.fireProcessExit(0)
        XCTAssertEqual(handle2.status, .inactive)
        XCTAssertNil(handle2.unshownExitError)
    }

    // MARK: - #10 Unread Closed Loop

    func test_unreadClosedLoop() async {
        let (handle, backend, _) = await makeAttached()

        // unfocused + responding→idle → hasUnread=true
        XCTAssertFalse(handle.isFocused)
        handle.send("msg")
        XCTAssertEqual(handle.status, .responding)
        await backend.deliver(makeResultSuccessMessage())
        XCTAssertTrue(handle.hasUnread)

        // setFocused(true) → 清零 + isFocused=true
        handle.setFocused(true)
        XCTAssertTrue(handle.isFocused)
        XCTAssertFalse(handle.hasUnread)

        // focused 情况下 responding→idle → hasUnread 不被置为 true
        handle.send("msg2")
        await backend.deliver(makeResultSuccessMessage())
        XCTAssertFalse(handle.hasUnread)

        // setFocused(false) → isFocused=false，hasUnread 不被动清零
        handle.setFocused(false)
        XCTAssertFalse(handle.isFocused)
        XCTAssertFalse(handle.hasUnread)
    }

    // MARK: - #11 Detach Cleanup

    func test_detach_cleansUp() async {
        let (handle, backend, _) = await makeAttached()

        await backend.firePermissionRequest(
            PermissionRequest.makePreview(requestId: "p", toolName: "Bash", input: [:])
        ) { _ in }
        await backend.fireStderr("some stderr\n")
        handle.send("hello")
        handle.send("queued")

        XCTAssertFalse(handle.pendingPermissions.isEmpty)
        XCTAssertFalse(handle.queuedMessages.isEmpty)

        handle.detach()

        XCTAssertEqual(handle.status, .inactive)
        XCTAssertTrue(handle.pendingPermissions.isEmpty)
        XCTAssertEqual(backend.closeCallCount, 1)

        // stderrBuffer 是内部状态：通过"detach 后新 session exit 不带旧 stderr"间接验证
        let (handle2, backend2, _) = await makeAttached()
        await backend2.fireProcessExit(1)
        XCTAssertNil(handle2.unshownExitError?.stderr)
    }

    // MARK: - #12 waitForSessionInit Supersede

    func test_waitForSessionInit_superseded() async throws {
        let bridge = FakeSessionBridge()
        let backend = FakeSessionBackend()
        let handle = SessionHandle2(
            sessionId: "s1",
            workspace: Workspace(cwd: "/init", isWorktree: false),
            permissionMode: .default,
            model: "sonnet",
            effort: .medium,
            bridge: bridge
        )
        handle.attach(backend: backend, bridge: bridge)
        XCTAssertEqual(handle.status, .starting)

        let firstTask: Task<Error?, Never> = Task { @MainActor in
            do {
                try await handle.waitForSessionInit()
                return nil
            } catch {
                return error
            }
        }

        await yieldSeveral()

        let secondTask: Task<Error?, Never> = Task { @MainActor in
            do {
                try await handle.waitForSessionInit()
                return nil
            } catch {
                return error
            }
        }

        await yieldSeveral()

        let firstError = await firstTask.value
        XCTAssertTrue((firstError as? SessionHandle2.SessionInitError) == .superseded)

        await backend.deliver(makeInitMessage(cwd: "/x", slashCommands: nil, permissionMode: nil))
        let secondError = await secondTask.value
        XCTAssertNil(secondError, "second wait should resume normally")
    }

    // MARK: - Helpers

    private func makeHandle() -> (SessionHandle2, FakeSessionBackend, FakeSessionBridge) {
        let bridge = FakeSessionBridge()
        let backend = FakeSessionBackend()
        let handle = SessionHandle2(
            sessionId: "s1",
            workspace: Workspace(cwd: "/init", isWorktree: false),
            permissionMode: .default,
            model: "sonnet",
            effort: .medium,
            bridge: bridge
        )
        return (handle, backend, bridge)
    }

    /// 创建 handle + attach + 喂一条 sessionInit 推进到 .idle，便于后续发送/中断路径测试。
    private func makeAttached() async -> (SessionHandle2, FakeSessionBackend, FakeSessionBridge) {
        let (handle, backend, bridge) = makeHandle()
        handle.attach(backend: backend, bridge: bridge)
        await backend.deliver(makeInitMessage(cwd: nil, slashCommands: nil, permissionMode: nil))
        return (handle, backend, bridge)
    }

    /// 多次 yield 让 pending `Task { @MainActor }` 执行完。
    private func yieldSeveral() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

// MARK: - Fakes

@MainActor
final class FakeSessionBackend: SessionBackend {
    struct SentMessage {
        let text: String
        let extra: [String: Any]
    }
    var sentMessages: [SentMessage] = []
    var interruptCallCount = 0
    var pendingInterruptCompletion: (() -> Void)?
    var modelSet: String?
    var effortSet: Effort?
    var permissionModeSet: AgentSDK.PermissionMode?
    var closeCallCount = 0

    var onMessage: ((Message2) -> Void)?
    var onPermissionRequest: ((PermissionRequest, @escaping (PermissionDecision) -> Void) -> Void)?
    var onPermissionCancelled: ((String) -> Void)?
    var onProcessExit: ((Int32) -> Void)?
    var onStderr: ((String) -> Void)?

    func sendMessage(_ text: String, extra: [String: Any]) {
        sentMessages.append(SentMessage(text: text, extra: extra))
    }

    func interrupt(completion: @escaping () -> Void) {
        interruptCallCount += 1
        pendingInterruptCompletion = completion
    }

    func setModel(_ model: String) { modelSet = model }
    func setEffort(_ effort: Effort) { effortSet = effort }
    func setPermissionMode(_ mode: AgentSDK.PermissionMode) { permissionModeSet = mode }
    func close() { closeCallCount += 1 }

    // MARK: - Test triggers

    func deliver(_ message: Message2) async {
        onMessage?(message)
        for _ in 0..<5 { await Task.yield() }
    }

    func firePermissionRequest(
        _ request: PermissionRequest,
        completion: @escaping (PermissionDecision) -> Void
    ) async {
        onPermissionRequest?(request, completion)
        for _ in 0..<5 { await Task.yield() }
    }

    func firePermissionCancelled(_ id: String) async {
        onPermissionCancelled?(id)
        for _ in 0..<5 { await Task.yield() }
    }

    func fireProcessExit(_ code: Int32) async {
        onProcessExit?(code)
        for _ in 0..<5 { await Task.yield() }
    }

    func fireStderr(_ text: String) async {
        onStderr?(text)
        for _ in 0..<5 { await Task.yield() }
    }

    func fireInterruptCompletion() {
        pendingInterruptCompletion?()
        pendingInterruptCompletion = nil
    }
}

@MainActor
final class FakeSessionBridge: SessionBridge {
    struct ForwardedMessage {
        let conversationId: String
        let messageJSON: [String: Any]
    }
    struct TurnActiveCall {
        let conversationId: String
        let isTurnActive: Bool
        let interrupted: Bool
    }

    var forwardedMessages: [ForwardedMessage] = []
    var setRawMessagesCalls: [(String, [[String: Any]])] = []
    var turnActiveCalls: [TurnActiveCall] = []

    func forwardRawMessage(conversationId: String, messageJSON: [String: Any]) {
        forwardedMessages.append(ForwardedMessage(conversationId: conversationId, messageJSON: messageJSON))
    }

    func setRawMessages(conversationId: String, messagesJSON: [[String: Any]]) {
        setRawMessagesCalls.append((conversationId, messagesJSON))
    }

    func setTurnActive(conversationId: String, isTurnActive: Bool, interrupted: Bool) {
        turnActiveCalls.append(TurnActiveCall(
            conversationId: conversationId,
            isTurnActive: isTurnActive,
            interrupted: interrupted
        ))
    }
}

// MARK: - Message Fixtures

private func makeInitMessage(
    cwd: String?,
    slashCommands: [String]?,
    permissionMode: String?
) -> Message2 {
    var dict: [String: Any] = [
        "type": "system",
        "subtype": "init",
    ]
    if let cwd { dict["cwd"] = cwd }
    if let slashCommands { dict["slash_commands"] = slashCommands }
    if let permissionMode { dict["permission_mode"] = permissionMode }
    return try! Message2(json: dict)
}

private func makeAssistantMessage(inputTokens: Int, model: String) -> Message2 {
    let dict: [String: Any] = [
        "type": "assistant",
        "message": [
            "role": "assistant",
            "model": model,
            "content": [
                ["type": "text", "text": "hi"]
            ],
            "usage": [
                "input_tokens": inputTokens,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0,
            ],
        ],
    ]
    return try! Message2(json: dict)
}

private func makeResultSuccessMessage(
    modelUsageContextWindow: (model: String, window: Int)? = nil
) -> Message2 {
    var dict: [String: Any] = [
        "type": "result",
        "subtype": "success",
        "is_error": false,
        "result": "done",
    ]
    if let mu = modelUsageContextWindow {
        dict["model_usage"] = [
            mu.model: ["context_window": mu.window]
        ]
    }
    return try! Message2(json: dict)
}

/// 构造 enter/exit worktree 需要 Resolver 配对：先 assistant 发 tool_use，
/// 再 user 发 tool_result，Resolver 按 tool_use_id 配对将 ToolUseResultObject
/// 从 .unresolved 解析为具体 case。
private func makeWorktreeUserMessage(
    toolName: String,
    toolUseId: String,
    resultFields: [String: Any]
) -> Message2 {
    let resolver = Message2Resolver()
    let assistantJSON: [String: Any] = [
        "type": "assistant",
        "message": [
            "role": "assistant",
            "content": [
                [
                    "type": "tool_use",
                    "id": toolUseId,
                    "name": toolName,
                    "input": [:],
                ]
            ],
        ],
    ]
    _ = try? resolver.resolve(assistantJSON)

    let userJSON: [String: Any] = [
        "type": "user",
        "message": [
            "role": "user",
            "content": [
                [
                    "type": "tool_result",
                    "tool_use_id": toolUseId,
                    "content": "ok",
                ]
            ],
        ],
        "tool_use_result": resultFields,
    ]
    return try! resolver.resolve(userJSON)
}

private func makeEnterWorktreeUserMessage(worktreePath: String) -> Message2 {
    makeWorktreeUserMessage(
        toolName: "EnterWorktree",
        toolUseId: "tu-wt-enter",
        resultFields: ["worktree_path": worktreePath]
    )
}

private func makeExitWorktreeUserMessage(originalCwd: String) -> Message2 {
    makeWorktreeUserMessage(
        toolName: "ExitWorktree",
        toolUseId: "tu-wt-exit",
        resultFields: ["original_cwd": originalCwd]
    )
}

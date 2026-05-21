import AgentSDK
import XCTest

@testable import ccterm

/// Locks in the `TodoEntry` projection driven by `SessionRuntime.receive`:
///
///   - An assistant `TaskCreate` tool_use paired with a `TaskCreate`
///     tool_result materializes a `.pending` entry whose subject is
///     pulled from the result and whose `description` / `activeForm`
///     come from the input.
///   - A subsequent `TaskUpdate` tool_use + tool_result patches the
///     entry's status (and optional `activeForm` / `description`) in
///     place, without changing its `createdAt`.
///   - Multiple TaskCreate calls accumulate independent entries
///     ordered by creation receive order.
///   - Control flow runs in both `.live` and `.replay`, so a JSONL
///     reload rebuilds the same list.
@MainActor
final class SessionRuntimeTodosTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Fixtures

    /// The `ToolUseResultObject` is created `.unknown(name: "unresolved")`
    /// when first parsed, and only resolves to its typed variant
    /// (`.TaskCreate(...)` etc.) once the resolver has previously seen
    /// the matching assistant `tool_use` and stitches the two together.
    /// Production wires a single `Message2Resolver` per session;
    /// reuse one here so the dispatch path inside `applyTodoToolResult`
    /// sees a properly-resolved result envelope.
    private var resolver: Message2Resolver!

    override func setUp() {
        super.setUp()
        resolver = Message2Resolver()
    }

    private func makeRuntime() -> SessionRuntime {
        SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in FakeCLIClient() }
        )
    }

    private func taskCreateToolUse(
        toolUseId: String,
        subject: String,
        description: String? = nil,
        activeForm: String? = nil
    ) -> Message2 {
        var input: [String: Any] = ["subject": subject]
        if let description { input["description"] = description }
        if let activeForm { input["activeForm"] = activeForm }
        return resolve([
            "type": "assistant",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "id": "m",
                "type": "message",
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "id": toolUseId,
                        "name": "TaskCreate",
                        "input": input,
                    ]
                ],
            ],
        ])
    }

    private func taskCreateResult(
        toolUseId: String,
        taskId: String,
        subject: String
    ) -> Message2 {
        resolve([
            "type": "user",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": "Task #\(taskId) created successfully: \(subject)",
                    ]
                ],
            ],
            "tool_use_result": [
                "task": [
                    "id": taskId,
                    "subject": subject,
                ]
            ],
        ])
    }

    private func taskUpdateToolUse(
        toolUseId: String,
        taskId: String,
        status: String? = nil,
        activeForm: String? = nil
    ) -> Message2 {
        var input: [String: Any] = ["taskId": taskId]
        if let status { input["status"] = status }
        if let activeForm { input["activeForm"] = activeForm }
        return resolve([
            "type": "assistant",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "id": "m",
                "type": "message",
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "id": toolUseId,
                        "name": "TaskUpdate",
                        "input": input,
                    ]
                ],
            ],
        ])
    }

    private func taskUpdateResult(
        toolUseId: String,
        taskId: String,
        from: String,
        to: String,
        success: Bool = true
    ) -> Message2 {
        resolve([
            "type": "user",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": "Updated task #\(taskId) status",
                    ]
                ],
            ],
            "tool_use_result": [
                "success": success,
                "taskId": taskId,
                "updatedFields": ["status"],
                "statusChange": [
                    "from": from,
                    "to": to,
                ],
            ],
        ])
    }

    private func resolve(_ dict: [String: Any]) -> Message2 {
        try! resolver.resolve(dict)
    }

    // MARK: - Materialization

    /// Smoke: TaskCreate tool_use → TaskCreate tool_result lands a
    /// single `.pending` entry, picking up description + activeForm
    /// from the input and subject from the result.
    func testTaskCreateMaterializesPendingTodo() {
        let runtime = makeRuntime()
        runtime.receive(
            taskCreateToolUse(
                toolUseId: "toolu_1",
                subject: "Read README",
                description: "Skim the project README",
                activeForm: "Reading README"
            ))
        runtime.receive(
            taskCreateResult(
                toolUseId: "toolu_1",
                taskId: "1",
                subject: "Read README"
            ))

        XCTAssertEqual(runtime.todos.count, 1)
        let todo = try! XCTUnwrap(runtime.todos.first)
        XCTAssertEqual(todo.id, "1")
        XCTAssertEqual(todo.subject, "Read README")
        XCTAssertEqual(todo.description, "Skim the project README")
        XCTAssertEqual(todo.activeForm, "Reading README")
        XCTAssertEqual(todo.status, .pending)
    }

    /// Three sequential TaskCreate pairs accumulate three entries in
    /// receive order. The order matters for the popover (creation
    /// order is the assistant's intent).
    func testThreeTaskCreatesAccumulate() {
        let runtime = makeRuntime()
        for (i, subject) in ["A", "B", "C"].enumerated() {
            let toolUseId = "toolu_\(i)"
            let taskId = "\(i + 1)"
            runtime.receive(taskCreateToolUse(toolUseId: toolUseId, subject: subject))
            runtime.receive(
                taskCreateResult(
                    toolUseId: toolUseId,
                    taskId: taskId,
                    subject: subject
                ))
        }
        XCTAssertEqual(runtime.todos.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(runtime.todos.map(\.subject), ["A", "B", "C"])
        XCTAssertTrue(runtime.todos.allSatisfy { $0.status == .pending })
    }

    // MARK: - Update

    /// TaskUpdate flips the status of an existing todo in place.
    /// `createdAt` is preserved; `updatedAt` advances.
    func testTaskUpdatePatchesStatusInPlace() {
        let runtime = makeRuntime()
        runtime.receive(taskCreateToolUse(toolUseId: "tu_c", subject: "Run tests"))
        runtime.receive(
            taskCreateResult(
                toolUseId: "tu_c",
                taskId: "1",
                subject: "Run tests"
            ))
        let createdAt = runtime.todos.first?.createdAt

        runtime.receive(
            taskUpdateToolUse(
                toolUseId: "tu_u",
                taskId: "1",
                status: "in_progress",
                activeForm: "Running tests"
            ))
        runtime.receive(
            taskUpdateResult(
                toolUseId: "tu_u",
                taskId: "1",
                from: "pending",
                to: "in_progress"
            ))

        XCTAssertEqual(runtime.todos.count, 1)
        let todo = try! XCTUnwrap(runtime.todos.first)
        XCTAssertEqual(todo.id, "1")
        XCTAssertEqual(todo.status, .inProgress)
        XCTAssertEqual(todo.activeForm, "Running tests")
        XCTAssertEqual(todo.createdAt, createdAt)
    }

    /// Two updates to the same task land both patches and the final
    /// status reflects the last update seen.
    func testTwoSequentialUpdatesEndAtCompleted() {
        let runtime = makeRuntime()
        runtime.receive(taskCreateToolUse(toolUseId: "tu_c", subject: "Polish UI"))
        runtime.receive(
            taskCreateResult(
                toolUseId: "tu_c", taskId: "1", subject: "Polish UI"))

        runtime.receive(
            taskUpdateToolUse(
                toolUseId: "tu_u1", taskId: "1", status: "in_progress"))
        runtime.receive(
            taskUpdateResult(
                toolUseId: "tu_u1", taskId: "1", from: "pending", to: "in_progress"))
        XCTAssertEqual(runtime.todos.first?.status, .inProgress)

        runtime.receive(
            taskUpdateToolUse(
                toolUseId: "tu_u2", taskId: "1", status: "completed"))
        runtime.receive(
            taskUpdateResult(
                toolUseId: "tu_u2", taskId: "1", from: "in_progress", to: "completed"))
        XCTAssertEqual(runtime.todos.first?.status, .completed)
    }

    /// A TaskUpdate whose taskId doesn't match any existing entry is
    /// silently ignored — the popover would otherwise grow a phantom
    /// row from a malformed CLI message.
    func testTaskUpdateWithoutMatchingTodoIsIgnored() {
        let runtime = makeRuntime()
        runtime.receive(
            taskUpdateToolUse(
                toolUseId: "tu_u", taskId: "404", status: "completed"))
        runtime.receive(
            taskUpdateResult(
                toolUseId: "tu_u", taskId: "404", from: "pending", to: "completed"))
        XCTAssertTrue(runtime.todos.isEmpty)
    }

    // MARK: - Replay parity

    /// Replay mode walks the same captureTodoToolUses /
    /// applyTodoToolResult path so a JSONL reload rebuilds the same
    /// list as live mode.
    func testReplayBuildsSameList() {
        let runtime = makeRuntime()
        runtime.receive(
            taskCreateToolUse(toolUseId: "tu_c", subject: "Plan a thing"),
            mode: .replay
        )
        runtime.receive(
            taskCreateResult(
                toolUseId: "tu_c", taskId: "7", subject: "Plan a thing"),
            mode: .replay
        )
        runtime.receive(
            taskUpdateToolUse(
                toolUseId: "tu_u", taskId: "7", status: "completed"),
            mode: .replay
        )
        runtime.receive(
            taskUpdateResult(
                toolUseId: "tu_u", taskId: "7", from: "pending", to: "completed"),
            mode: .replay
        )
        XCTAssertEqual(runtime.todos.count, 1)
        XCTAssertEqual(runtime.todos.first?.status, .completed)
    }
}

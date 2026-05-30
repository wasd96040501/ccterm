import AgentSDK
import XCTest

@testable import ccterm

/// Locks in the `BackgroundTask` lifecycle driven by `SessionRuntime.receive`:
///
/// - `system.task_started` creates a `.running` task and back-fills the
///   bash command by scanning the message timeline.
/// - The matching `user.tool_result` text body provides the spool-file
///   path (`Output is being written to: <path>`).
/// - `system.task_updated` (the SDK's `.unknown("task_updated", raw)`
///   arm) patches status and `end_time`.
/// - `system.task_notification` flips the entry to `.completed` / `.failed`
///   and records the summary.
/// - None of these control signals touch `messages` — they are siphoned
///   off into `tasks` and the transcript stays clean.
@MainActor
final class SessionRuntimeTasksTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Fixtures (local to this file)

    private func makeRuntime() -> SessionRuntime {
        SessionRuntime(
            sessionId: UUID().uuidString,
            repository: InMemorySessionRepository(),
            cliClientFactory: { _ in FakeCLIClient() }
        )
    }

    private func assistantBashToolUse(toolUseId: String, command: String) -> Message2 {
        resolve([
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
                        "name": "Bash",
                        "input": [
                            "command": command,
                            "description": "ignored",
                            "run_in_background": true,
                        ],
                    ]
                ],
            ],
        ])
    }

    private func bashToolResult(
        toolUseId: String,
        backgroundTaskId: String,
        outputPath: String,
        sentenceTerminator: String = "."
    ) -> Message2 {
        let body =
            "Command running in background with ID: \(backgroundTaskId). "
            + "Output is being written to: \(outputPath)\(sentenceTerminator) "
            + "You will be notified when it completes."
        return resolve([
            "type": "user",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": body,
                    ]
                ],
            ],
            "tool_use_result": [
                "stdout": "",
                "stderr": "",
                "interrupted": false,
                "isImage": false,
                "noOutputExpected": false,
                "backgroundTaskId": backgroundTaskId,
            ],
        ])
    }

    private func taskStarted(
        taskId: String,
        toolUseId: String,
        description: String = "",
        taskType: String = "local_bash"
    ) -> Message2 {
        resolve([
            "type": "system",
            "subtype": "task_started",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "task_id": taskId,
            "tool_use_id": toolUseId,
            "description": description,
            "task_type": taskType,
        ])
    }

    private func taskNotification(
        taskId: String,
        toolUseId: String,
        status: String,
        outputFile: String,
        summary: String
    ) -> Message2 {
        resolve([
            "type": "system",
            "subtype": "task_notification",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "task_id": taskId,
            "tool_use_id": toolUseId,
            "status": status,
            "output_file": outputFile,
            "summary": summary,
        ])
    }

    private func taskUpdated(
        taskId: String,
        status: String,
        endTimeMillis: Double? = nil
    ) -> Message2 {
        var patch: [String: Any] = ["status": status]
        if let endTimeMillis { patch["end_time"] = endTimeMillis }
        return resolve([
            "type": "system",
            "subtype": "task_updated",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "task_id": taskId,
            "patch": patch,
        ])
    }

    private func resolve(_ dict: [String: Any]) -> Message2 {
        try! Message2Resolver().resolve(dict)
    }

    // MARK: - Lifecycle

    /// Smoke: walk a task from `task_started` through tool_result to
    /// `task_notification` and assert that every intermediate field
    /// (command back-fill, spool path, summary) lands on the entry.
    func testFullHappyPath() {
        let runtime = makeRuntime()
        let toolUseId = "toolu_test_001"
        let taskId = "bxrhxgxqo"
        let outputPath = "/private/tmp/claude-501/x/y/tasks/\(taskId).output"

        // Assistant emits the Bash tool_use first.
        runtime.receive(assistantBashToolUse(toolUseId: toolUseId, command: "sleep 5 && echo done"))

        // CLI accepts the task.
        runtime.receive(taskStarted(taskId: taskId, toolUseId: toolUseId, description: "Wait and echo"))

        XCTAssertEqual(runtime.tasks.count, 1)
        var task = try! XCTUnwrap(runtime.tasks.first)
        XCTAssertEqual(task.id, taskId)
        XCTAssertEqual(task.toolUseId, toolUseId)
        XCTAssertEqual(task.command, "sleep 5 && echo done")
        XCTAssertEqual(task.description, "Wait and echo")
        XCTAssertEqual(task.taskType, "local_bash")
        XCTAssertEqual(task.status, .running)
        XCTAssertNil(task.outputFile)

        // tool_result lands with the spool path embedded.
        runtime.receive(
            bashToolResult(
                toolUseId: toolUseId,
                backgroundTaskId: taskId,
                outputPath: outputPath
            ))
        task = try! XCTUnwrap(runtime.tasks.first)
        XCTAssertEqual(task.outputFile, outputPath)
        XCTAssertEqual(task.status, .running, "tool_result must not flip status off")

        // Terminal notification arrives.
        runtime.receive(
            taskNotification(
                taskId: taskId,
                toolUseId: toolUseId,
                status: "completed",
                outputFile: outputPath,
                summary: "Background command completed (exit code 0)"
            ))
        task = try! XCTUnwrap(runtime.tasks.first)
        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(task.summary, "Background command completed (exit code 0)")
        XCTAssertNotNil(task.endedAt)
    }

    /// `system.task_updated` is a subtype the SDK doesn't model — it
    /// arrives as `.system(.unknown("task_updated", raw))`. The runtime
    /// reads the patch dict and applies it.
    func testTaskUpdatedAppliesStatusAndEndTime() {
        let runtime = makeRuntime()
        let taskId = "tu_unknown_path"

        runtime.receive(taskStarted(taskId: taskId, toolUseId: "toolu_x"))
        XCTAssertEqual(runtime.tasks.first?.status, .running)

        let endMillis: Double = 1_779_265_048_785
        runtime.receive(taskUpdated(taskId: taskId, status: "completed", endTimeMillis: endMillis))
        let task = try! XCTUnwrap(runtime.tasks.first)
        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(
            task.endedAt?.timeIntervalSince1970 ?? 0,
            endMillis / 1000.0,
            accuracy: 0.01
        )
    }

    /// Multiple concurrent background tasks must be tracked independently
    /// and ordered by the receive timeline (oldest first).
    func testTwoConcurrentTasks() {
        let runtime = makeRuntime()
        runtime.receive(taskStarted(taskId: "a", toolUseId: "tu_a", description: "First"))
        runtime.receive(taskStarted(taskId: "b", toolUseId: "tu_b", description: "Second"))
        XCTAssertEqual(runtime.tasks.map(\.id), ["a", "b"])

        runtime.receive(
            taskNotification(
                taskId: "a",
                toolUseId: "tu_a",
                status: "completed",
                outputFile: "/tmp/a.output",
                summary: "ok"
            ))
        let a = try! XCTUnwrap(runtime.tasks.first(where: { $0.id == "a" }))
        let b = try! XCTUnwrap(runtime.tasks.first(where: { $0.id == "b" }))
        XCTAssertEqual(a.status, .completed)
        XCTAssertEqual(b.status, .running)
    }

    /// A `failed` notification status must map to `BackgroundTask.Status.failed`,
    /// not the default `.completed`.
    func testFailedStatusFromNotification() {
        let runtime = makeRuntime()
        let taskId = "task_fail"
        runtime.receive(taskStarted(taskId: taskId, toolUseId: "tu_fail"))
        runtime.receive(
            taskNotification(
                taskId: taskId,
                toolUseId: "tu_fail",
                status: "failed",
                outputFile: "/tmp/fail.output",
                summary: "Background command failed with exit code 2"
            ))
        XCTAssertEqual(runtime.tasks.first?.status, .failed)
    }

    // MARK: - Path extraction edge cases

    /// The CLI's canonical sentence ends in a period right after the
    /// path. The parser must strip the trailing period without lopping
    /// off the actual file extension.
    func testOutputPathStripsTrailingSentencePeriod() {
        let runtime = makeRuntime()
        runtime.receive(taskStarted(taskId: "p", toolUseId: "tu_p"))
        runtime.receive(
            bashToolResult(
                toolUseId: "tu_p",
                backgroundTaskId: "p",
                outputPath: "/private/tmp/claude/p.output",
                sentenceTerminator: "."
            ))
        XCTAssertEqual(runtime.tasks.first?.outputFile, "/private/tmp/claude/p.output")
    }

    /// Same shape but without the trailing period — make sure we don't
    /// strip a real `.output` extension when the sentence happens not
    /// to terminate it.
    func testOutputPathPreservesExtensionWhenNoTerminator() {
        let runtime = makeRuntime()
        runtime.receive(taskStarted(taskId: "q", toolUseId: "tu_q"))
        runtime.receive(
            bashToolResult(
                toolUseId: "tu_q",
                backgroundTaskId: "q",
                outputPath: "/private/tmp/q.output",
                sentenceTerminator: ""
            ))
        XCTAssertEqual(runtime.tasks.first?.outputFile, "/private/tmp/q.output")
    }

    // MARK: - Control signals are suppressed from the transcript

    /// None of the task control signals (started / notification /
    /// updated) may produce a user bubble or any other timeline entry.
    /// The whole point of the `tasks` collection is to siphon them off
    /// the message stream.
    func testControlSignalsDoNotPolluteTimeline() {
        let runtime = makeRuntime()
        let toolUseId = "tu_silent"
        let taskId = "silent_task"

        runtime.receive(assistantBashToolUse(toolUseId: toolUseId, command: "echo silent"))
        let baselineEntryCount = runtime.messages.count

        runtime.receive(taskStarted(taskId: taskId, toolUseId: toolUseId))
        runtime.receive(taskUpdated(taskId: taskId, status: "running"))
        runtime.receive(
            taskNotification(
                taskId: taskId,
                toolUseId: toolUseId,
                status: "completed",
                outputFile: "/tmp/silent.output",
                summary: "done"
            ))

        XCTAssertEqual(
            runtime.messages.count,
            baselineEntryCount,
            "task control signals must not add timeline entries"
        )
    }

    /// New-protocol shape: synthetic `task-notification` user turn
    /// stamped with `origin.kind == "task-notification"`. Must not land
    /// in the transcript — the tasks popover is the only surface for
    /// completion chatter.
    func testTaskNotificationUserMessageWithOriginIsSuppressed() {
        let runtime = makeRuntime()
        let baseline = runtime.messages.count

        runtime.receive(
            taskNotificationUserMessage(
                xml: "<task-notification>\n<task-id>bx1</task-id>\n</task-notification>",
                includeOrigin: true
            ))

        XCTAssertEqual(
            runtime.messages.count,
            baseline,
            "user message with origin.kind=task-notification must not append a bubble"
        )
    }

    /// Legacy-protocol shape: the synthetic user turn carries the
    /// `<task-notification>` XML envelope but no `origin` field at all
    /// (observed in 2026-02 smoke dumps and still occasionally surfaces
    /// on certain CLI paths). The content-prefix fallback in
    /// `Message2User.isVisible` must catch it; without that fallback
    /// the bubble leaks into the transcript.
    func testTaskNotificationUserMessageWithoutOriginIsSuppressed() {
        let runtime = makeRuntime()
        let baseline = runtime.messages.count
        let envelope =
            "<task-notification>\n<task-id>bkw8rhbr3</task-id>\n"
            + "<tool-use-id>toolu_01W41r88y71CQwMYHbk35UHK</tool-use-id>\n"
            + "<status>completed</status>\n"
            + "<summary>Background command completed (exit code 0)</summary>\n"
            + "</task-notification>\n"
            + "Read the output file to retrieve the result: /tmp/x.output"

        runtime.receive(
            taskNotificationUserMessage(xml: envelope, includeOrigin: false))

        XCTAssertEqual(
            runtime.messages.count,
            baseline,
            "legacy task-notification user envelope (no origin field) must still be suppressed"
        )
    }

    /// Negative case: a normal user message whose text happens to start
    /// with something that isn't the task-notification envelope must
    /// still produce a bubble — the prefix check must not over-match.
    func testNormalUserMessageStillAppends() {
        let runtime = makeRuntime()
        let baseline = runtime.messages.count

        runtime.receive(Message2Fixtures.userText("hello there"))

        XCTAssertEqual(
            runtime.messages.count,
            baseline + 1,
            "normal user text must continue to produce a timeline entry"
        )
    }

    private func taskNotificationUserMessage(
        xml: String,
        includeOrigin: Bool
    ) -> Message2 {
        var dict: [String: Any] = [
            "type": "user",
            "uuid": UUID().uuidString,
            "session_id": "s",
            "message": [
                "role": "user",
                "content": xml,
            ],
        ]
        if includeOrigin {
            dict["origin"] = ["kind": "task-notification"]
        }
        return resolve(dict)
    }

    // MARK: - Local stop

    func testMarkTaskStoppedLocally() {
        let runtime = makeRuntime()
        runtime.receive(taskStarted(taskId: "x", toolUseId: "tu_x"))
        XCTAssertTrue(runtime.markTaskStoppedLocally(taskId: "x"))
        XCTAssertEqual(runtime.tasks.first?.status, .stopped)
        XCTAssertNotNil(runtime.tasks.first?.endedAt)
    }
}

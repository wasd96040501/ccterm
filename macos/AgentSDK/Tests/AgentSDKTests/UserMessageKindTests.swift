import XCTest

@testable import AgentSDK

/// Every kind of user message the CLI writes, read from its markup, and the
/// forms that don't read falling back to ``UserMessage/Kind/prompt``.
final class UserMessageKindTests: XCTestCase {
    private func kind(_ text: String, origin: String? = nil, isSynthetic: Bool = false) -> UserMessage.Kind {
        UserMessage(content: [.text(text)], isSynthetic: isSynthetic, origin: origin).kind
    }

    // MARK: - Plain

    func testTypedTextIsAPrompt() {
        XCTAssertEqual(kind("fix the build"), .prompt)
    }

    func testTextWithImagesIsAPrompt() {
        let message = UserMessage(content: [
            .text("look"), .image(.init(source: .base64(mediaType: "image/png", data: "AA=="))),
        ])
        XCTAssertEqual(message.kind, .prompt)
    }

    func testToolResult() {
        let result = ToolResultBlock(toolUseID: "t", content: [.text("ok")], isError: false)
        XCTAssertEqual(UserMessage(content: [.toolResult(result)]).kind, .toolResult(result))
    }

    func testCompactionSummary() {
        XCTAssertEqual(
            UserMessage(content: [.text("This session is being continued…")], isSynthetic: true, isCompactSummary: true)
                .kind,
            .compactionSummary)
    }

    func testSyntheticText() {
        XCTAssertEqual(kind("<system-reminder>be brief</system-reminder>", isSynthetic: true), .synthetic)
        XCTAssertEqual(kind("   ", origin: "auto-continuation"), .synthetic)
    }

    func testInterruptions() {
        XCTAssertEqual(kind("[Request interrupted by user]"), .interruption(duringToolUse: false))
        XCTAssertEqual(kind("[Request interrupted by user for tool use]"), .interruption(duringToolUse: true))
        XCTAssertEqual(kind("[Request interrupted by user] and more"), .prompt)
    }

    // MARK: - Local commands

    func testSlashCommandWithArguments() {
        let text = """
            <command-message>model</command-message>
            <command-name>/model</command-name>
            <command-args>opus</command-args>
            """
        XCTAssertEqual(kind(text), .slashCommand(name: "/model", arguments: "opus"))
    }

    func testSlashCommandWithoutArguments() {
        XCTAssertEqual(kind("<command-name>/compact</command-name>"), .slashCommand(name: "/compact", arguments: ""))
    }

    func testShellCommand() {
        XCTAssertEqual(kind("<bash-input>ls -la</bash-input>"), .shellCommand("ls -la"))
    }

    func testTagNamesMatchInAnyCase() {
        XCTAssertEqual(kind("<Command-Name>/compact</COMMAND-NAME>"), .slashCommand(name: "/compact", arguments: ""))
    }

    func testCommandOutput() {
        XCTAssertEqual(
            kind("<local-command-stdout>Set model to opus</local-command-stdout>"),
            .commandOutput(standardOutput: "Set model to opus", standardError: ""))
        XCTAssertEqual(
            kind("<bash-stdout></bash-stdout><bash-stderr>ls: nope: No such file</bash-stderr>"),
            .commandOutput(standardOutput: "", standardError: "ls: nope: No such file"))
    }

    func testOutputKeepsElementsNestedUnderTheSameName() {
        let text = "<local-command-stdout>a <local-command-stdout>b</local-command-stdout> c</local-command-stdout>"
        XCTAssertEqual(
            kind(text),
            .commandOutput(standardOutput: "a <local-command-stdout>b</local-command-stdout> c", standardError: ""))
    }

    // MARK: - Task notifications

    func testTaskNotificationWithEveryField() {
        let text = """
            <task-notification>
            <task-id>a1</task-id>
            <task-type>remote_agent</task-type>
            <tool-use-id>toolu_1</tool-use-id>
            <output-file>/tmp/a1.output</output-file>
            <status>completed</status>
            <summary>Agent "Review" finished</summary>
            <result>Looks good &amp; ships: a &lt; b</result>
            <usage><subagent_tokens>1200</subagent_tokens><tool_uses>3</tool_uses><duration_ms>4500</duration_ms></usage>
            <worktree><worktreePath>/w/review</worktreePath><worktreeBranch>review</worktreeBranch></worktree>
            <note>A task-notification fires each time this agent stops.</note>
            </task-notification>
            """
        let expected = TaskReport(
            summary: #"Agent "Review" finished"#, status: .completed, taskIDs: ["a1"], taskType: "remote_agent",
            toolUseID: "toolu_1", outputFile: "/tmp/a1.output", result: "Looks good & ships: a < b",
            note: "A task-notification fires each time this agent stops.",
            usage: .init(totalTokens: 1200, totalToolUseCount: 3, totalDurationMS: 4500), worktreePath: "/w/review",
            worktreeBranch: "review")
        XCTAssertEqual(kind(text, origin: "task-notification"), .taskNotification(expected))
        XCTAssertEqual(kind(text), .taskNotification(expected))
    }

    func testWorkflowNotification() {
        let text = """
            <task-notification>
            <task-id>w1</task-id>
            <status>failed</status>
            <summary>Workflow "audit" failed</summary>
            <usage><agent_count>4</agent_count><agents_done>2</agents_done><agents_error>1</agents_error><agents_skipped>1</agents_skipped><agents_empty_result>0</agents_empty_result></usage>
            <diagnostics>/tmp/w1/agents</diagnostics>
            <failures>step 3: timed out</failures>
            <recovery>Resume with the run id</recovery>
            </task-notification>
            """
        let expected = TaskReport(
            summary: #"Workflow "audit" failed"#, status: .failed, taskIDs: ["w1"],
            usage: .init(agentCount: 4, agentsDone: 2, agentsFailed: 1, agentsSkipped: 1, agentsWithEmptyResult: 0),
            diagnostics: "/tmp/w1/agents", failures: "step 3: timed out", recovery: "Resume with the run id")
        XCTAssertEqual(kind(text, origin: "task-notification"), .taskNotification(expected))
    }

    func testNotificationAboutSeveralTasks() {
        let text = """
            <task-notification><task-id>b1</task-id><task-id>b2</task-id><status>stopped</status>\
            <summary>2 tasks were stopped</summary></task-notification>
            """
        XCTAssertEqual(
            kind(text, origin: "task-notification"),
            .taskNotification(.init(summary: "2 tasks were stopped", status: .stopped, taskIDs: ["b1", "b2"])))
    }

    func testMonitorEventHasNoStatus() {
        let text = """
            <task-notification><task-id>m1</task-id><summary>Monitor event: "deploy"</summary>\
            <event>rollout 3/5</event></task-notification>
            """
        XCTAssertEqual(
            kind(text, origin: "task-notification"),
            .taskNotification(.init(summary: #"Monitor event: "deploy""#, taskIDs: ["m1"], event: "rollout 3/5")))
    }

    func testUnknownStatusIsKept() {
        let text = "<task-notification><status>paused</status><summary>Paused</summary></task-notification>"
        XCTAssertEqual(
            kind(text, origin: "task-notification"),
            .taskNotification(.init(summary: "Paused", status: .unknown("paused"))))
    }

    func testFieldsInsideTheResultAreTheResults() {
        let text = """
            <task-notification><summary>Done</summary>\
            <result>quoted: <summary>not this</summary><status>failed</status></result></task-notification>
            """
        guard case .taskNotification(let notification) = kind(text, origin: "task-notification") else {
            return XCTFail()
        }
        XCTAssertEqual(notification.summary, "Done")
        XCTAssertNil(notification.status)
    }

    func testNotificationAfterTextReadsFromItsOrigin() {
        let text = "A background task changed:\n<task-notification><summary>Done</summary></task-notification>"
        XCTAssertEqual(kind(text, origin: "task-notification"), .taskNotification(.init(summary: "Done")))
        XCTAssertEqual(kind(text), .prompt)
    }

    // MARK: - Relayed messages

    func testSubagentReportWithoutItsFrame() {
        let text = """
            <agent-message from="a42">
            [Subagent hand-back] The text below is the final report of a subagent. The report follows:
              ## Findings

              - one
            </agent-message>
            """
        XCTAssertEqual(kind(text), .message(from: .agent(id: "a42"), text: "## Findings\n\n- one"))
    }

    func testNotesAboveTheFrameStayAheadOfTheReport() {
        let text = """
            <agent-message from="a42">
            Note: the safety classifier was unavailable.
            [Subagent hand-back] The report follows:
              Done.
              [Subagent hand-back] quoted by the report
            </agent-message>
            """
        XCTAssertEqual(
            kind(text),
            .message(
                from: .agent(id: "a42"),
                text: "Note: the safety classifier was unavailable.\n\nDone.\n[Subagent hand-back] quoted by the report"
            ))
    }

    func testReportWithoutAFrameIsTheBody() {
        XCTAssertEqual(
            kind(#"<agent-message from="a42">  plain report  </agent-message>"#),
            .message(from: .agent(id: "a42"), text: "plain report"))
    }

    func testMessageFromAnotherSession() {
        let text = """
            Another Claude session sent a message while you were working:
            <cross-session-message from="uds:/tmp/s.sock" from-name="lamport" from-mode="prompting">
            Which files are you editing?
            </cross-session-message>
            """
        XCTAssertEqual(
            kind(text, origin: "peer"),
            .message(
                from: .session(address: "uds:/tmp/s.sock", name: "lamport", mode: "prompting"),
                text: "Which files are you editing?"))
    }

    func testSessionWithoutANameOrMode() {
        let text = """
            Another Claude session sent a message:
            <cross-session-message from="uds:/tmp/s.sock">hi</cross-session-message>
            """
        XCTAssertEqual(
            kind(text, origin: "peer"),
            .message(from: .session(address: "uds:/tmp/s.sock", name: nil, mode: nil), text: "hi"))
    }

    func testMessageFromTheCoordinator() {
        let text = """
            The coordinator sent a message while you were working:
            Redo the hair.

            Address this before completing your current task.
            """
        XCTAssertEqual(kind(text, origin: "coordinator"), .message(from: .coordinator, text: "Redo the hair."))
    }

    func testMessageFromAPlugin() {
        let text = """
            The taskcut plugin sent a message:
            Continue.

            This is how Claude Code surfaces a prompt a plugin submits between turns — it starts this turn in the user's place. Address the message above.
            """
        XCTAssertEqual(
            kind(text, origin: "plugin"), .message(from: .plugin(name: "taskcut", duringTurn: false), text: "Continue.")
        )
    }

    func testMessageFromAPluginWhileClaudeWorked() {
        let text = """
            The taskcut plugin sent a message while you were working:
            Also run the linter.

            This is how Claude Code surfaces prompts a plugin submits mid-turn — within the running turn, often alongside the next tool result. Address the message above as you continue this turn.
            """
        XCTAssertEqual(
            kind(text, origin: "plugin"),
            .message(from: .plugin(name: "taskcut", duringTurn: true), text: "Also run the linter."))
    }

    func testPluginMessageKeepsTheOtherHeadersNote() {
        // Each header strips only its own note: text that merely ends like the other one stays.
        let between =
            "The a plugin sent a message:\nGo.\n\nThis is how Claude Code surfaces prompts a plugin submits mid-turn — within the running turn, often alongside the next tool result. Address the message above as you continue this turn."
        guard case .message(.plugin(_, let duringTurn), let text) = kind(between, origin: "plugin") else {
            return XCTFail("not a plugin message")
        }
        XCTAssertFalse(duringTurn)
        XCTAssertTrue(text.hasPrefix("Go."))
        XCTAssertTrue(text.contains("mid-turn"))
    }

    func testAutoContinuation() {
        let words =
            "Your claude.ai usage limit has reset. Continue the task you were working on when the limit was reached; do not repeat work that is already complete."
        XCTAssertEqual(kind(words, origin: "auto-continuation"), .autoContinuation(text: words))
        XCTAssertEqual(
            kind("\(words)\n", origin: "auto-continuation", isSynthetic: true), .autoContinuation(text: words),
            "isMeta (isSynthetic) doesn't hide it")
        XCTAssertEqual(
            kind("Goal set: ship it", origin: "auto-continuation"), .autoContinuation(text: "Goal set: ship it"))
    }

    // MARK: - Falling back

    func testTextThatIsNotOnlyElementsIsAPrompt() {
        XCTAssertEqual(kind("<command-name>/compact</command-name> and then some"), .prompt)
        XCTAssertEqual(kind("Run <bash-input>ls</bash-input>"), .prompt)
    }

    func testMalformedMarkupIsAPrompt() {
        XCTAssertEqual(kind("<command-name>/compact"), .prompt)
        XCTAssertEqual(kind("<command-name/>"), .prompt)
        XCTAssertEqual(kind("<agent-message from=a42>hi</agent-message>"), .prompt)
        XCTAssertEqual(
            kind("<task-notification><summary>Done</task-notification>", origin: "task-notification"), .prompt)
    }

    func testElementsOfAnotherFormAreAPrompt() {
        XCTAssertEqual(kind(#"<pasted_content id="4075">notes</pasted_content id="4075">"#), .prompt)
        XCTAssertEqual(kind("<command-name>/model</command-name><bash-input>ls</bash-input>"), .prompt)
        XCTAssertEqual(kind("<bash-input>ls</bash-input><bash-input>pwd</bash-input>"), .prompt)
        XCTAssertEqual(kind("<command-args>opus</command-args>"), .prompt)
        XCTAssertEqual(kind("<something-new>x</something-new>"), .prompt)
    }

    func testMissingRequiredFieldsAreAPrompt() {
        XCTAssertEqual(kind("<task-notification><status>completed</status></task-notification>"), .prompt)
        XCTAssertEqual(kind("<agent-message>no sender</agent-message>"), .prompt)
        XCTAssertEqual(
            kind(
                "Another Claude session sent a message:\n<cross-session-message>hi</cross-session-message>",
                origin: "peer"), .prompt)
    }

    func testRelayWithoutItsHeaderIsAPrompt() {
        XCTAssertEqual(kind("Redo the hair.", origin: "coordinator"), .prompt)
        XCTAssertEqual(kind("Somebody sent a message:\nhi", origin: "peer"), .prompt)
        XCTAssertEqual(kind("Another Claude session sent a message:\nno element", origin: "peer"), .prompt)
    }
}

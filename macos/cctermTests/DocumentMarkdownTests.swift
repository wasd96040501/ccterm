import AgentSDK
import XCTest

@testable import ccterm

/// The words of a document that is words (design/transcript/preview.js
/// `markdownDoc`): a heading, a status line, then the body — worded from the
/// content a page hands over, no AppKit.
final class DocumentMarkdownTests: XCTestCase {
    private func markdown(_ script: MessageScript, _ id: String? = nil) -> String {
        let page = script.page
        let content = page.document(for: id ?? page.entries.last!.id)
        return DocumentMarkdown.markdown(for: content!)
    }

    private let taskList = String(localized: "Task list")
    private let summary = String(localized: "Summary")
    private let continuedFrom = String(localized: "What the model continued from")
    private let commandOutput = String(localized: "Local command output")
    private let monitorEvent = String(localized: "Monitor event")
    private let failures = String(localized: "Failures")
    private let result = String(localized: "Result")
    private let input = String(localized: "Input")
    private let stillWorking = String(localized: "The agent is still working.")

    private let oneFile = String(localized: "1 file")
    private func files(_ count: Int) -> String { String(localized: "\(count) files") }
    private func tools(_ count: Int, _ time: String) -> String { String(localized: "\(count) tools · \(time)") }
    private let inTheProject = String(localized: "in the project")

    func testAGrepIsItsFilesWithTheirFolders() {
        var s = MessageScript()
        s.call("g", "Grep", #"{"pattern":"rowSpacing","path":"/r/Sources"}"#)
        s.result(
            "g", output: #"{"mode":"files_with_matches","numFiles":2,"filenames":["/r/Sources/A.swift","/r/B.swift"]}"#)
        XCTAssertEqual(
            markdown(s),
            """
            ### “rowSpacing”

            *\(String(localized: "in \("/r/Sources")")) · \(files(2))*

            - **A.swift** `/r/Sources`
            - **B.swift** `/r`
            """)
    }

    func testAGrepThatPrintedLinesIsThoseLines() {
        var s = MessageScript()
        s.call("g", "Grep", #"{"pattern":"a"}"#)
        s.result("g", output: #"{"mode":"content","numFiles":1,"filenames":["/r/A"],"content":"A:1:a","numLines":1}"#)
        XCTAssertEqual(
            markdown(s), "### “a”\n\n*\(inTheProject) · \(oneFile)*\n\n```\nA:1:a\n```")
    }

    func testAGlobIsItsFiles() {
        var s = MessageScript()
        s.call("g", "Glob", #"{"pattern":"**/*.md"}"#)
        s.result("g", output: #"{"filenames":["/r/README.md"],"numFiles":1,"truncated":false,"durationMs":3}"#)
        XCTAssertEqual(markdown(s), "### “\\*\\*/\\*.md”\n\n*\(inTheProject) · \(oneFile)*\n\n- **README.md** `/r`")
    }

    func testASearchWithoutStructuredOutputFallsBackToWhatTheModelSaw() {
        var s = MessageScript()
        s.call("t", "ToolSearch", #"{"query":"select:Read"}"#)
        s.result("t", "Found Read")
        XCTAssertEqual(markdown(s), "### “select:Read”\n\n*\(inTheProject)*\n\n```\nFound Read\n```")
    }

    func testAFetchedPageIsTheAnswerToItsPrompt() {
        var s = MessageScript()
        s.call("w", "WebFetch", #"{"url":"https://example.com/a","prompt":"Summarise"}"#)
        s.result(
            "w",
            output:
                #"{"url":"https://example.com/a","code":200,"codeText":"OK","bytes":10,"result":"It is **short**.","durationMs":5}"#
        )
        XCTAssertEqual(markdown(s), "### example.com\n\n*https://example.com/a · 200 OK*\n\nIt is **short**.")
    }

    func testAWebSearchIsItsLinksThenTheCommentary() {
        var s = MessageScript()
        s.call("w", "WebSearch", #"{"query":"nstableview"}"#)
        s.result(
            "w",
            output:
                #"{"query":"nstableview","results":[{"tool_use_id":"x","content":[{"title":"Docs","url":"https://a.dev"}]},"Apple documents it."],"durationSeconds":1}"#
        )
        XCTAssertEqual(
            markdown(s),
            "### “nstableview”\n\n*\(String(localized: "1 result"))*\n\n- [Docs](https://a.dev)\n\nApple documents it.")
    }

    func testAnAgentIsItsReportUnderItsUsage() {
        var s = MessageScript()
        s.call("a", "Agent", #"{"description":"Find gaps","prompt":"p","subagent_type":"Explore"}"#)
        s.result(
            "a",
            output:
                #"{"status":"completed","agentId":"a1","content":[{"type":"text","text":"Found **three**."}],"totalToolUseCount":9,"totalDurationMs":71000,"totalTokens":5}"#
        )
        XCTAssertEqual(
            markdown(s), "### Find gaps\n\n*Explore · \(tools(9, WorkLineWriter.format(71)))*\n\nFound **three**.")
    }

    func testAnAgentStillWorkingSaysSo() {
        var s = MessageScript()
        s.call("a", "Agent", #"{"description":"Find gaps","prompt":"p"}"#)
        XCTAssertEqual(markdown(s), "### Find gaps\n\n\(stillWorking)")
    }

    func testTheTaskListIsAChecklistAsItStood() {
        var s = MessageScript()
        s.call(
            "t", "TodoWrite",
            #"{"todos":[{"content":"Read","status":"completed","activeForm":"Reading"},{"content":"Edit","status":"in_progress","activeForm":"Editing"},{"content":"Build","status":"pending","activeForm":"Building"}]}"#
        )
        s.result("t")
        XCTAssertEqual(
            markdown(s), "### \(taskList)\n\n- [x] ~~Read~~\n- [ ] **Edit**\n- [ ] Build")
    }

    func testAnAgentsNewsIsItsFailuresThenItsResult() {
        var s = MessageScript()
        s.user(
            "<task-notification><task-id>t1</task-id><status>completed</status><summary>Agent “Review the diff” finished</summary><result>Looks right.</result><failures>review:perf timed out</failures><usage><tool_uses>14</tool_uses><duration_ms>130000</duration_ms></usage><worktree><worktreePath>.claude/worktrees/review</worktreePath><worktreeBranch>review-diff</worktreeBranch></worktree></task-notification>",
            origin: "task-notification")
        XCTAssertEqual(
            markdown(s),
            """
            ### Review the diff

            *\(tools(14, WorkLineWriter.format(130))) · .claude/worktrees/review · review-diff*

            **\(failures)**

            review:perf timed out

            **\(result)**

            Looks right.
            """)
    }

    func testAMonitorsNewsIsItsEvent() {
        var s = MessageScript()
        s.user(
            "<task-notification><task-id>t1</task-id><summary>Monitor “CI” saw: passed</summary><event>test-kit passed</event></task-notification>",
            origin: "task-notification")
        XCTAssertEqual(markdown(s), "### CI\n\n*\(monitorEvent)*\n\ntest-kit passed")
    }

    func testACommandsOutputIsAFencedBlock() {
        let command = LocalCommand(
            id: "l", command: .slash(name: "/context", arguments: ""), output: "Usage: 31%\n- Tools: 14k\n",
            errorOutput: "")
        XCTAssertEqual(
            DocumentMarkdown.markdown(for: .commandOutput(command)),
            "### /context\n\n*\(commandOutput)*\n\n```\nUsage: 31%\n- Tools: 14k\n```")
    }

    func testAFenceIsLongerThanAnyBackticksInsideIt() {
        let command = LocalCommand(
            id: "l", command: .slash(name: "/x", arguments: ""), output: "```swift\nlet a\n```", errorOutput: "")
        XCTAssertTrue(DocumentMarkdown.markdown(for: .commandOutput(command)).contains("````\n```swift"))
    }

    func testACompactionSummaryIsItsMarkdown() {
        XCTAssertEqual(
            DocumentMarkdown.markdown(for: .compactionSummary("**Done.** Built it.")),
            "### \(summary)\n\n*\(continuedFrom)*\n\n**Done.** Built it.")
    }

    func testAnyOtherCallIsItsInputThenItsResult() {
        var s = MessageScript()
        s.call("m", "mcp__computer-use__screenshot", #"{"display":1}"#)
        s.result("m", "Took it")
        XCTAssertEqual(
            markdown(s),
            "### screenshot\n\n*computer-use*\n\n**\(input)**\n\n```json\n{\n  \"display\" : 1\n}\n```\n\n**\(result)**\n\n```\nTook it\n```"
        )
    }
}

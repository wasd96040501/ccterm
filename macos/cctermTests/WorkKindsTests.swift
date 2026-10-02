import AgentSDK
import XCTest

@testable import ccterm

/// The kinds the design adds to the run vocabulary — advisor, skill, worktree,
/// message, notify — and what the other parties' messages say about when they
/// spoke (design/transcript/01-run.md, 06-agent-messages.md).
final class WorkKindsTests: XCTestCase {
    private func run(_ s: MessageScript) -> ToolRun {
        guard case .run(let run)? = s.page.entries.first(where: { if case .run = $0 { true } else { false } }) else {
            XCTFail("no run in \(s.page.entries)")
            return ToolRun(
                id: "", items: [],
                line: WorkLine(
                    tile: Tile(glyph: .tool(.other), state: .done), text: StyledText(), detail: nil,
                    exceptions: StyledText(), meta: StyledText()))
        }
        return run
    }

    // MARK: - Mapping

    func testToolNamesMapToTheirKinds() {
        func kind(_ name: String) -> ToolKind {
            ToolKind(ToolUseBlock(id: "x", name: name, input: .object([:])), result: nil)
        }
        XCTAssertEqual(kind("PowerShell"), .command)
        XCTAssertEqual(kind("TaskStop"), .command)
        XCTAssertEqual(kind("ReadMcpResource"), .read)
        XCTAssertEqual(kind("LSP"), .search)
        XCTAssertEqual(kind("ListAgents"), .agent)
        XCTAssertEqual(kind("RemoteTrigger"), .schedule)
        XCTAssertEqual(kind("Skill"), .skill)
        XCTAssertEqual(kind("EnterWorktree"), .worktree)
        XCTAssertEqual(kind("ExitWorktree"), .worktree)
        XCTAssertEqual(kind("SendMessage"), .message)
        for name in ["PushNotification", "SendUserMessage", "SendUserFile"] { XCTAssertEqual(kind(name), .notify) }
        XCTAssertEqual(kind("mcp__x__y"), .other)
    }

    func testTheKindsAreInTheSentencesOrder() {
        XCTAssertEqual(
            ToolKind.allCases,
            [
                .change, .create, .command, .agent, .web, .search, .read, .tasks, .schedule, .advisor, .skill,
                .worktree, .message, .notify, .other,
            ])
    }

    // MARK: - The advisor

    func testAnEncryptedAnswerSaysWhatTheCLISays() {
        var s = MessageScript()
        s.advisor("adv", .redacted)
        let run = run(s)
        XCTAssertEqual(run.line.text.string, String(localized: "Asked the advisor"))
        XCTAssertEqual(run.line.detail, String(localized: "Reviewed the conversation"))
        XCTAssertEqual(run.line.tile, Tile(glyph: .tool(.advisor), state: .done))
        XCTAssertFalse(run.items[0].opensBeside)
        XCTAssertEqual(PageRow.rows(for: s.page)[0].opens, nil)
    }

    func testAdviceInTheClearOpensBesideWithTheModelAsStatus() throws {
        var s = MessageScript()
        s.advisor("adv", .result(text: "Split the tab bar first.\nThen the rest.", stopReason: nil))
        let run = run(s)
        XCTAssertEqual(run.line.detail, "Split the tab bar first.")
        XCTAssertTrue(run.items[0].opensBeside)
        guard case .advice(let call)? = s.page.document(for: "adv") else { return XCTFail() }
        XCTAssertEqual(call.advisor?.model, "claude-opus-4-5")
        let markdown = DocumentMarkdown.markdown(for: .advice(call))
        XCTAssertTrue(markdown.contains("claude-opus-4-5"))
        XCTAssertTrue(markdown.contains("Split the tab bar first."))
    }

    func testARefusalIsDeclinedToAdvise() {
        var s = MessageScript()
        s.advisor("adv", .result(text: "No.", stopReason: "refusal"))
        XCTAssertEqual(run(s).line.detail, String(localized: "Declined to advise"))
        XCTAssertFalse(run(s).items[0].opensBeside)
    }

    func testAnErrorIsARedTileWithTheCodeInWords() {
        var s = MessageScript()
        s.advisor("adv", .error(code: "overloaded"))
        let run = run(s)
        XCTAssertEqual(run.line.tile.state, .failed)
        XCTAssertEqual(run.line.detail, String(localized: "Overloaded — try again shortly"))
        XCTAssertEqual(
            AdvisorOutcome.words(forError: "max_uses_exceeded"),
            String(localized: "Asked as often as this session allows"))
        XCTAssertEqual(
            AdvisorOutcome.words(forError: "prompt_too_long"),
            String(localized: "The conversation is too long for the advisor"))
    }

    func testAnAdvisorCallWithNoAnswerWasInterrupted() {
        var s = MessageScript()
        s.advisor("adv", nil)
        s.reply("Moving on.")
        XCTAssertEqual(run(s).line.tile.state, .stopped)
    }

    func testTwoAdvisorCallsAreCounted() {
        var s = MessageScript()
        s.advisor("a1", .redacted)
        s.advisor("a2", .redacted)
        XCTAssertEqual(run(s).line.text.string, String(localized: "Asked the advisor \(2) times"))
    }

    // MARK: - Skill, worktree, notify

    func testASkillNamesItself() {
        var s = MessageScript()
        s.call("s1", "Skill", #"{"skill":"dataviz","args":"a chart"}"#)
        s.result("s1")
        let line = run(s).line
        XCTAssertEqual(line.text.string, String(localized: "Used the \("dataviz") skill"))
        XCTAssertEqual(line.tile.glyph, .tool(.skill))
    }

    func testWorktreesAreMovedIntoAndLeft() {
        var s = MessageScript()
        s.call("w1", "EnterWorktree", #"{"name":"fix"}"#)
        s.result("w1")
        XCTAssertEqual(run(s).line.text.string, String(localized: "Moved into a worktree"))
        XCTAssertEqual(run(s).line.detail, "fix")
        var t = MessageScript()
        t.call("w2", "ExitWorktree", #"{"action":"keep"}"#)
        t.result("w2")
        XCTAssertEqual(run(t).line.text.string, String(localized: "Left the worktree"))
    }

    func testANotificationIsSentToYou() {
        var s = MessageScript()
        s.call("n1", "PushNotification", #"{"message":"Build done\nall green"}"#)
        s.result("n1")
        let line = run(s).line
        XCTAssertEqual(line.text.string, String(localized: "Sent you a notification"))
        XCTAssertEqual(line.detail, "Build done")
    }

    // MARK: - SendMessage

    func testAMessageNamesItsParty() {
        var s = MessageScript()
        s.call("m1", "SendMessage", #"{"to":"team-lead","summary":"Status","message":"All done."}"#)
        s.result("m1")
        let line = run(s).line
        XCTAssertEqual(line.text.string, String(localized: "Messaged \("team-lead")"))
        XCTAssertEqual(line.detail, "Status")
        XCTAssertEqual(line.tile.glyph, .tool(.message))
    }

    func testAMessageToEveryoneIsToTheTeam() {
        var s = MessageScript()
        s.call("m1", "SendMessage", #"{"to":"*","summary":"Hi","message":"Hi all"}"#)
        s.result("m1")
        XCTAssertEqual(run(s).line.text.string, String(localized: "Messaged the team"))
    }

    func testSeveralPartiesAreCounted() {
        var s = MessageScript()
        s.call("m1", "SendMessage", #"{"to":"a","summary":"x","message":"x"}"#)
        s.result("m1")
        s.call("m2", "SendMessage", #"{"to":"b","summary":"x","message":"x"}"#)
        s.result("m2")
        s.call("m3", "SendMessage", #"{"to":"a","summary":"x","message":"x"}"#)
        s.result("m3")
        XCTAssertEqual(run(s).line.text.string, String(localized: "Sent \(3) messages"))
    }

    func testAStructuredMessageIsNamedByWhatItDoes() {
        var s = MessageScript()
        s.call("m1", "SendMessage", #"{"to":"qa","message":{"type":"shutdown_request"}}"#)
        s.result("m1")
        XCTAssertEqual(run(s).line.text.string, String(localized: "Asked \("qa") to shut down"))
        var t = MessageScript()
        t.call("m2", "SendMessage", #"{"to":"qa","message":{"type":"plan_approval_response","approve":true}}"#)
        t.result("m2")
        XCTAssertEqual(run(t).line.text.string, String(localized: "Approved \("qa")’s plan"))
    }

    func testAMessageOpensBesideWithItsBody() {
        var s = MessageScript()
        s.call("m1", "SendMessage", #"{"to":"team-lead","summary":"Status","message":"All done."}"#)
        s.result("m1")
        guard case .sentMessage(let call)? = s.page.document(for: "m1") else { return XCTFail() }
        let header = DocumentHeader.markdown(.sentMessage(call))
        XCTAssertEqual(header.title, String(localized: "To \("team-lead")"))
        let markdown = DocumentMarkdown.markdown(for: .sentMessage(call))
        XCTAssertTrue(markdown.contains("Status"))
        XCTAssertTrue(markdown.contains("All done."))
    }

    func testTheOlderMessageShapeIsRead() {
        let message = SentMessage(MessageScript.json(#"{"type":"message","recipient":"qa","content":"Hello"}"#))
        XCTAssertEqual(message?.to, "qa")
        XCTAssertEqual(message?.body, "Hello")
    }

    // MARK: - Who spoke, and when

    func testAPluginSaysWhenItSpoke() {
        let between = AgentMessage(
            id: "p", sender: .plugin(name: "ralph", duringTurn: false), name: "ralph", text: "go",
            line: WorkLine(
                tile: Tile(glyph: .tool(.other), state: .done), text: StyledText(), detail: nil,
                exceptions: StyledText(), meta: StyledText()))
        XCTAssertEqual(between.caption.text, String(localized: "Plugin “\("ralph")”"))
        XCTAssertEqual(between.caption.detail, String(localized: "Started this turn"))
        var during = between
        during = AgentMessage(
            id: "p", sender: .plugin(name: "ralph", duringTurn: true), name: "ralph", text: "go", line: between.line)
        XCTAssertEqual(during.caption.detail, String(localized: "While Claude worked"))
    }

    func testAnAutoContinuationSaysWhy() {
        typealias Why = SessionDivider.Continuation
        XCTAssertEqual(Why(text: "Your claude.ai usage limit has reset. Continue the task."), .usageLimitReset)
        XCTAssertEqual(Why(text: "The user approved the ultraplan in the browser…"), .planApproved)
        XCTAssertEqual(Why(text: "Goal set: ship it"), .goal)
        XCTAssertEqual(Why(text: "Continue."), .automatic)
        XCTAssertEqual(
            SessionDivider(id: "d", kind: .continued(.usageLimitReset), prompt: "x").label,
            String(localized: "Continued after the usage limit reset"))
        XCTAssertEqual(
            SessionDivider(id: "d", kind: .continued(.goal), prompt: "x").label, String(localized: "Goal set"))
        XCTAssertEqual(
            SessionDivider(id: "d", kind: .continued(.automatic), prompt: "x").linkTitle, String(localized: "Prompt"))
    }

    /// Needs AgentSDK's `autoContinuation` decoding (workstream A).
    func testAnAutoContinuationIsADividerWithItsPrompt() throws {
        var s = MessageScript()
        s.prompt("Hi")
        s.user("Your claude.ai usage limit has reset. Continue the task.", origin: "auto-continuation")
        guard case .user(let user) = s.messages[1], case .autoContinuation = user.kind else {
            throw XCTSkip("AgentSDK does not decode auto-continuation yet (workstream A)")
        }
        guard case .divider(let divider) = s.page.entries[1] else { return XCTFail("\(s.page.entries)") }
        XCTAssertEqual(divider.kind, .continued(.usageLimitReset))
        XCTAssertEqual(s.page.document(for: divider.id), .continuationPrompt(divider.prompt!))
        let markdown = DocumentMarkdown.markdown(for: .continuationPrompt("x"))
        XCTAssertTrue(markdown.contains(String(localized: "Written by Claude Code, not by you")))
    }
}

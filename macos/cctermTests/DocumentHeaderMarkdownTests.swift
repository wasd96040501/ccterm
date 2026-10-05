import AgentSDK
import DisplayModels
import XCTest

@testable import ccterm

/// The header words of the documents that are words: the title that is the
/// crumb and names the tab, the kind's tile, a search's file count.
final class DocumentHeaderMarkdownTests: XCTestCase {
    private func header(_ script: MessageScript) -> DocumentHeader {
        let page = script.page
        return DocumentHeader.markdown(page.document(for: page.entries.last!.id)!)
    }

    func testASearchIsTitledByWhatItSearchedForAndCountsItsFiles() {
        var s = MessageScript()
        s.call("g", "Grep", #"{"pattern":"rowSpacing"}"#)
        s.result("g", output: #"{"mode":"files_with_matches","numFiles":3,"filenames":["a","b","c"]}"#)
        let header = header(s)
        XCTAssertEqual(header.title, String(localized: "Search: \("rowSpacing")"))
        XCTAssertEqual(header.crumbs, [header.title])
        let count = 3
        XCTAssertEqual(header.stat.string, String(localized: "\(count) files"))
        XCTAssertEqual(header.tile, Tile(glyph: .tool(.search), state: .done))
    }

    func testAPageFetchedIsItsHostAndASearchItsQuery() {
        var s = MessageScript()
        s.call("w", "WebFetch", #"{"url":"https://example.com/a","prompt":"p"}"#)
        s.result("w")
        XCTAssertEqual(header(s).title, "example.com")
        XCTAssertEqual(header(s).tile.glyph, .tool(.web))
        var q = MessageScript()
        q.call("w", "WebSearch", #"{"query":"nstableview"}"#)
        q.result("w")
        XCTAssertEqual(header(q).title, "“nstableview”")
    }

    func testAnAgentIsItsDescriptionUnderTheAgentTile() {
        var s = MessageScript()
        s.call("a", "Agent", #"{"description":"Find gaps","prompt":"p"}"#)
        s.result("a")
        XCTAssertEqual(header(s).title, "Find gaps")
        XCTAssertEqual(header(s).tile, Tile(glyph: .tool(.agent), state: .done))
        var bare = MessageScript()
        bare.call("a", "Agent", #"{"prompt":"p"}"#)
        XCTAssertEqual(header(bare).title, String(localized: "Agent"))
    }

    func testACallWaitingForTheReaderHasTheWaitingTile() {
        let use = ToolUseBlock(id: "a", name: "Agent", input: MessageScript.json(#"{"description":"Go","prompt":"p"}"#))
        let call = ToolCall(
            use: use, result: nil, kind: .agent, state: .waiting(reason: nil), startedAt: nil, finishedAt: nil)
        XCTAssertEqual(DocumentHeader.markdown(.agent(call)).tile.state, .waiting)
    }

    func testTheTaskListACommandsOutputAndACompactionAreNamed() {
        XCTAssertEqual(DocumentHeader.markdown(.taskList([])).title, String(localized: "Task list"))
        XCTAssertEqual(DocumentHeader.markdown(.taskList([])).tile.glyph, .tool(.tasks))
        XCTAssertEqual(DocumentHeader.markdown(.compactionSummary("x")).title, String(localized: "Summary"))
        let command = LocalCommand(
            id: "l", command: .slash(name: "/context", arguments: ""), output: "x", errorOutput: "")
        XCTAssertEqual(DocumentHeader.markdown(.commandOutput(command)).title, "/context")
    }

    func testNewsIsTitledByTheTaskItNamesWithTheTasksOwnTile() {
        var s = MessageScript()
        s.user(
            "<task-notification><task-id>t1</task-id><status>failed</status><summary>Workflow “review-changes” finished</summary><usage><agent_count>9</agent_count></usage></task-notification>",
            origin: "task-notification")
        let header = header(s)
        XCTAssertEqual(header.title, "review-changes")
        XCTAssertEqual(header.tile, Tile(glyph: .workflow, state: .failed))
    }

    func testAnyOtherCallIsItsTool() {
        var s = MessageScript()
        s.call("m", "mcp__computer-use__screenshot", "{}")
        s.result("m")
        XCTAssertEqual(header(s).title, "screenshot")
    }

    func testALogAndTheContextHaveNoWayBackToARow() {
        let log = DocumentHeader.markdown(.log(SessionFailure(message: "Exit code 1 · boom", log: "x")))
        XCTAssertEqual(log.title, String(localized: "Session Log"))
        XCTAssertEqual(log.stat.string, "Exit code 1 · boom")
        XCTAssertEqual(log.tile.state, .failed)
        XCTAssertFalse(log.showsTranscriptJump)

        let context = DocumentHeader.markdown(.contextUsage(ContextUsageFixture.sample))
        XCTAssertEqual(context.title, String(localized: "Context Usage"))
        XCTAssertEqual(context.stat.string, "39%")
        XCTAssertFalse(context.showsTranscriptJump)

        XCTAssertTrue(DocumentHeader.markdown(.compactionSummary("x")).showsTranscriptJump)
    }
}

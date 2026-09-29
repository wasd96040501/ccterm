import AgentSDK
import XCTest

@testable import ccterm

/// Where the page draws its boundaries (design/transcript/01-run.md "Where a
/// run begins and ends", 04-background.md, 05-local.md), and how it settles
/// each call from what the transcript recorded.
final class TranscriptPageTests: XCTestCase {

    private func bash(_ description: String, _ command: String = "make") -> String {
        #"{"command":"\#(command)","description":"\#(description)"}"#
    }

    private func runs(_ page: TranscriptPage) -> [ToolRun] {
        page.entries.compactMap { if case .run(let run) = $0 { run } else { nil } }
    }

    // MARK: - Runs

    func testCallsWithOnlyResultsBetweenThemAreOneRunAndTextEndsIt() {
        var s = MessageScript()
        s.prompt("Build it")
        s.call("c1", "Bash", bash("Build"))
        s.result("c1")
        s.call("c2", "Read", #"{"file_path":"/r/A.swift"}"#)
        s.result("c2")
        s.reply("Done.")
        s.call("c3", "Bash", bash("Test"))
        s.result("c3")

        let page = s.page
        XCTAssertEqual(page.entries.map(\.id), ["0", "c1", "5.0", "c3"])
        XCTAssertEqual(runs(page).map { $0.items.map(\.id) }, [["c1", "c2"], ["c3"]])
    }

    func testAQuestionBreaksOutOfTheRunAroundIt() {
        var s = MessageScript()
        s.call("c1", "Bash", bash("Build"))
        s.result("c1")
        s.call(
            "q", "AskUserQuestion",
            #"{"questions":[{"question":"Which?","header":"H","options":[{"label":"A","description":"First"},{"label":"B","description":""}],"multiSelect":false}]}"#
        )
        s.result("q", output: #"{"questions":[],"answers":{"Which?":"A"}}"#)
        s.call("c2", "Bash", bash("Test"))
        s.result("c2")

        let entries = s.page.entries
        XCTAssertEqual(entries.map(\.id), ["c1", "q", "c2"])
        guard case .question(let question) = entries[1] else { return XCTFail("\(entries[1])") }
        XCTAssertEqual(
            question.items,
            [
                Question.Item(
                    header: "H", text: "Which?",
                    options: [
                        .init(label: "A", detail: "First", isChosen: true),
                        .init(label: "B", detail: "", isChosen: false),
                    ], allowsSeveral: false)
            ])
        XCTAssertEqual(question.tile, Tile(glyph: .question, state: .done))
    }

    func testConsecutiveEditsToOneFileAreOneItem() {
        var s = MessageScript()
        s.call("e1", "Edit", #"{"file_path":"/r/A.swift","old_string":"a","new_string":"b"}"#)
        s.result("e1")
        s.call("e2", "Edit", #"{"file_path":"/r/A.swift","old_string":"c","new_string":"d"}"#)
        s.result("e2")
        s.call("e3", "Edit", #"{"file_path":"/r/B.swift","old_string":"a","new_string":"b"}"#)
        s.result("e3")

        let run = runs(s.page)[0]
        XCTAssertEqual(run.items.map { $0.calls.map(\.id) }, [["e1", "e2"], ["e3"]])
        XCTAssertEqual(s.page.document(for: "e1"), .change(run.items[0].calls))
    }

    // MARK: - Settling a call

    func testARefusedCallIsDeniedAndACutOffOneInterrupted() {
        var s = MessageScript()
        s.call("c1", "Bash", bash("Push"))
        s.result("c1", "The user doesn't want to proceed with this tool use. The tool use was rejected.", error: true)
        s.call("c2", "Bash", bash("Wait"))
        s.user("[Request interrupted by user for tool use]")
        s.prompt("Stop")
        s.call("c3", "Bash", bash("Build"))

        let calls = runs(s.page).flatMap { $0.items.flatMap(\.calls) }
        XCTAssertEqual(calls.map(\.state), [.denied, .interrupted, .running])
    }

    func testAFailureKeepsTheToolsMessage() {
        var s = MessageScript()
        s.call("c1", "Bash", bash("Test"))
        s.result("c1", "Exit code 1\nerror: 'rowSpacing' is inaccessible", error: true)

        let item = runs(s.page)[0].items[0]
        XCTAssertEqual(item.state, .failed(message: "Exit code 1\nerror: 'rowSpacing' is inaccessible"))
        XCTAssertEqual(item.error, "error: 'rowSpacing' is inaccessible")
    }

    // MARK: - Background news

    func testConsecutiveNewsIsOneRowAndACommandsNewsOpensTheCommand() {
        var s = MessageScript()
        s.call("bg", "Bash", #"{"command":"make release","description":"Release build","run_in_background":true}"#)
        s.result("bg", output: #"{"stdout":"","stderr":"","backgroundTaskId":"t1"}"#)
        s.reply("Started.")
        s.wait(360)
        s.notification(summary: "Background command \"Release build\" completed", toolUseID: "bg")
        s.notification(summary: "Agent \"Review\" finished")

        let page = s.page
        guard case .news(let news) = page.entries.last else { return XCTFail("\(page.entries)") }
        XCTAssertEqual(news.news.count, 2)
        XCTAssertEqual(page.document(for: news.news[0].id), .command(page.call("bg")!))

        let launched = runs(page)[0].items[0]
        XCTAssertEqual(launched.state, .done, "the notification settles the call that started it")
        XCTAssertEqual(launched.line.meta.string, String(localized: "Background · \(WorkLineWriter.format(363))"))
    }

    // MARK: - The session's shape

    func testCompactFoldsIntoOneDividerThatOpensTheSummary() throws {
        var s = MessageScript()
        s.prompt("Hi")
        s.user(
            "<command-name>/compact</command-name><command-message>compact</command-message><command-args></command-args>"
        )
        s.compacted()
        s.compactionSummary("We were making rowSpacing public.")
        s.user("<local-command-stdout>Compacted</local-command-stdout>")

        let page = s.page
        XCTAssertEqual(page.entries.count, 2)
        guard case .divider(let divider) = page.entries[1] else { return XCTFail("\(page.entries)") }
        XCTAssertEqual(divider.kind, .compacted(automatically: false, preTokens: 168_000, postTokens: 14_000))
        XCTAssertEqual(page.document(for: divider.id), .compactionSummary("We were making rowSpacing public."))
    }

    func testExitThenAPromptIsAResumption() {
        var s = MessageScript()
        s.prompt("Hi")
        s.user("<command-name>/exit</command-name><command-message>exit</command-message><command-args></command-args>")
        s.user("<local-command-stdout>Bye!</local-command-stdout>")
        s.wait(86_400)
        s.prompt("Again")

        let kinds = s.page.entries.map { entry -> String in
            switch entry {
            case .prompt: "prompt"
            case .divider(let d): if case .resumed = d.kind { "resumed" } else { "divider" }
            default: "other"
            }
        }
        XCTAssertEqual(kinds, ["prompt", "resumed", "prompt"])
    }

    func testAnHourOfSilenceIsADivider() {
        var s = MessageScript()
        s.prompt("Hi")
        s.reply("Hello")
        s.wait(2 * 3600)
        s.call("c1", "Bash", bash("Build"))
        s.result("c1")

        guard case .divider(let divider) = s.page.entries[2], case .pause = divider.kind else {
            return XCTFail("\(s.page.entries)")
        }
    }

    func testASlashCommandsOutputJoinsItsCapsule() {
        var s = MessageScript()
        s.user(
            "<command-name>/model</command-name><command-message>model</command-message><command-args>opus</command-args>"
        )
        s.user("<local-command-stdout>Set model to opus</local-command-stdout>")

        XCTAssertEqual(
            s.page.entries,
            [
                .command(
                    LocalCommand(
                        id: "0", command: .slash(name: "/model", arguments: "opus"), output: "Set model to opus",
                        errorOutput: ""))
            ])
    }

    // MARK: - Documents

    func testTheTaskListOpensAsItStoodAfterThatCall() {
        var s = MessageScript()
        s.call("t1", "TaskCreate", #"{"subject":"Read","description":""}"#)
        s.result("t1", output: #"{"task":{"id":"1","subject":"Read"}}"#)
        s.call("t2", "TaskCreate", #"{"subject":"Write","description":""}"#)
        s.result("t2", output: #"{"task":{"id":"2","subject":"Write"}}"#)
        s.call("t3", "TaskUpdate", #"{"taskId":"1","status":"completed"}"#)
        s.result("t3")

        let page = s.page
        XCTAssertEqual(page.taskList(through: "t1").map(\.subject), ["Read"])
        XCTAssertEqual(page.taskList(through: "t3").map(\.status), [.completed, .pending])
    }
}

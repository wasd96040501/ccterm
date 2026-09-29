import AgentSDK
import TranscriptKit
import XCTest

@testable import ccterm

/// The sample session read into rows and cards: tool calls with nothing said
/// between them fold into one card, a command takes its output along, news
/// and interruptions are lines, and what the CLI adds for the model is left
/// out.
final class TranscriptOutlineTests: XCTestCase {
    private var root: URL!
    private var transcriptURL: URL!
    private var outline: TranscriptOutline!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        transcriptURL = try SampleSession.write(into: root)
        outline = TranscriptOutline(try Transcript(contentsOf: transcriptURL), source: transcriptURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Every row, in order, as one word each.
    func testRowsInOrder() {
        let shape = outline.rows.map { row -> String in
            switch (row.content, outline.cards[row.id]) {
            case (.userMessage, _): "user"
            case (.markdown, _): "text"
            case (.view, .tools(let group)?): "tools \(group.steps.count)"
            case (.view, .notice?): "notice"
            case (.view, .command(let command)?): command.kind == nil ? "output" : "command"
            default: "?"
            }
        }
        XCTAssertEqual(
            shape,
            [
                "user", "text",
                "tools 5", "text",
                "tools 6", "text",
                "tools 7", "text",
                "tools 1", "text",
                "tools 11", "notice",
                "command", "command", "command", "command", "command",
                "notice", "notice", "notice", "notice", "notice",
                "text", "text", "text", "text",
                "text",
                "notice",
                "user", "text",
            ])
    }

    func testAGroupCountsWhatItDid() throws {
        let edits = try group(at: 4)
        XCTAssertEqual(edits.steps.map(\.kind), [.edit, .edit, .edit, .edit, .edit, .edit])
        XCTAssertEqual(edits.failures, 1)
        XCTAssertEqual(edits.steps.last?.outcome, .failed)
        XCTAssertEqual(edits.summary, String(localized: "Edited \(6) files"))
        guard case .lines(let added, let removed)? = edits.lineStat else { return XCTFail("no line stat") }
        XCTAssertGreaterThan(added, 0)
        XCTAssertGreaterThan(removed, 0)

        guard case .comparison(_, let hunks, let original)? = edits.steps.first?.document?.content else {
            return XCTFail("an edit opens its comparison")
        }
        XCTAssertEqual(hunks.count, 1)
        XCTAssertNotNil(original)
    }

    func testReadingABackgroundCommandsOutputNamesTheCommand() throws {
        let shell = try group(at: 6)
        XCTAssertEqual(shell.steps[1].outcome, .failed)
        guard case .command(let command)? = shell.steps[3].document?.content else {
            return XCTFail("output opens as a command")
        }
        XCTAssertEqual(command.command, "swift test --parallel")
        XCTAssertEqual(command.status, .succeeded)
    }

    func testARefusedCallIsStoppedNotFailed() throws {
        let last = try XCTUnwrap(try group(at: 10).steps.last)
        XCTAssertEqual(last.outcome, .stopped)
    }

    func testCommandsTakeTheirOutput() throws {
        let commands = outline.rows.compactMap { row -> LocalCommand? in
            guard case .command(let command)? = outline.cards[row.id] else { return nil }
            return command
        }
        XCTAssertEqual(commands.map(\.input), ["/model opus", "/cost", "git status --short", "cat missing.txt", "/clear"])
        XCTAssertEqual(commands.map(\.kind), [.slash, .slash, .shell, .shell, .slash])
        XCTAssertTrue(commands[0].output.contains("Set model to"))
        XCTAssertEqual(commands[1].printedLineCount, 7)
        XCTAssertEqual(commands[1].previewLineCount, LocalCommand.previewLimit)
        XCTAssertEqual(commands[3].errorOutput, "cat: missing.txt: No such file or directory")
        XCTAssertNil(commands[4].document, "nothing printed, nothing to open")
    }

    func testNoticesCarryTheirNews() {
        let notices = outline.rows.compactMap { row -> TranscriptNotice? in
            guard case .notice(let notice)? = outline.cards[row.id] else { return nil }
            return notice
        }
        XCTAssertEqual(notices.count, 7)
        XCTAssertNotNil(notices[1].document, "a finished agent's result opens")
        XCTAssertEqual(notices[3].tone, .neutral)
    }

    func testDocumentsAreKnownByTheirTranscript() {
        for card in outline.cards.values {
            guard case .tools(let group) = card else { continue }
            for step in group.steps {
                XCTAssertEqual(step.document?.id.transcript ?? transcriptURL, transcriptURL)
            }
        }
    }

    private func group(at row: Int) throws -> ToolGroup {
        guard case .tools(let group)? = outline.cards[outline.rows[row].id] else {
            throw XCTSkip("row \(row) is not a tool group")
        }
        return group
    }
}

import AgentSDK
import DisplayModels
import XCTest

@testable import ccterm

/// The words of a work line (design/transcript/01-run.md "The sentence",
/// "A run of one is the call itself", "Live"). Expectations are built from
/// the same localized keys, so the tests hold in any language the machine
/// runs in.
final class WorkLineWriterTests: XCTestCase {

    private func run(_ script: MessageScript) -> ToolRun {
        for entry in script.page.entries {
            if case .run(let run) = entry { return run }
        }
        fatalError("no run in \(script.page.entries)")
    }

    private func edit(_ s: inout MessageScript, _ id: String, _ path: String, error: Bool = false) {
        s.call(id, "Edit", #"{"file_path":"\#(path)","old_string":"a","new_string":"b\nc"}"#)
        if error {
            s.result(id, "String to replace not found", error: true)
        } else {
            s.result(
                id,
                output:
                    #"{"filePath":"\#(path)","structuredPatch":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":2,"lines":["-a","+b","+c"]}]}"#
            )
        }
    }

    private func bash(_ s: inout MessageScript, _ id: String, _ description: String, error: Bool = false) {
        s.call(id, "Bash", #"{"command":"cd /r && make","description":"\#(description)"}"#)
        s.result(id, error ? "Exit code 2\nmake: *** [all] Error 2" : "ok", error: error)
    }

    /// A localized key with its slots filled by plain words.
    private func words(_ localized: String, _ arguments: String...) -> String {
        StyledText(localized: localized, arguments: arguments.map { StyledText($0) }).string
    }

    /// Clauses as a sentence joins them: later ones start lower-case.
    private func sentence(_ clauses: String...) -> String {
        clauses.enumerated().map {
            $0.offset == 0 ? $0.element : $0.element.prefix(1).lowercased() + $0.element.dropFirst()
        }
        .joined(separator: String(localized: ", ", comment: "Between clauses of a work summary"))
    }

    func testFilesAreNamedUpToTwoThenCountedAndCommandsCounted() {
        var s = MessageScript()
        edit(&s, "e1", "/r/A.swift")
        edit(&s, "e2", "/r/B.swift")
        bash(&s, "b1", "Build")
        bash(&s, "b2", "Test", error: true)
        bash(&s, "b3", "Test")

        let line = run(s).line
        XCTAssertEqual(
            line.text.string,
            sentence(
                words(
                    String(localized: "Edited \(StyledText.slot(0)) and \(StyledText.slot(1))"), "A.swift", "B.swift"),
                String(localized: "Ran \(3) commands")))
        XCTAssertTrue(line.text.runs.contains(.init(text: "A.swift", style: .noun(opens: "e1"))), "a named file links")
        XCTAssertEqual(line.exceptions.runs.last, .init(text: String(localized: "\(1) failed"), style: .failure))
        XCTAssertEqual(line.meta.string, "+4 −2")
        XCTAssertEqual(line.tile, Tile(glyph: .tool(.change), state: .done), "a recovered failure leaves the tile")

        var more = MessageScript()
        edit(&more, "e1", "/r/A.swift")
        edit(&more, "e2", "/r/B.swift")
        edit(&more, "e3", "/r/C.swift")
        XCTAssertEqual(run(more).line.text.string, String(localized: "Edited \(3) files"))
    }

    func testClausesCountOnlyWhatTookEffect() {
        var s = MessageScript()
        edit(&s, "e1", "/r/A.swift", error: true)
        s.call("e2", "Edit", #"{"file_path":"/r/B.swift","old_string":"a","new_string":"b"}"#)
        s.result("e2", "The user doesn't want to proceed with this tool use.", error: true)
        bash(&s, "b1", "Build")

        let line = run(s).line
        XCTAssertEqual(line.text.string, String(localized: "Ran a command"))
        XCTAssertEqual(
            line.exceptions.string, "· \(String(localized: "\(1) failed")) · \(String(localized: "\(1) denied"))")
    }

    func testPastThreeClausesTheRestIsCounted() {
        var s = MessageScript()
        edit(&s, "e1", "/r/A.swift")
        bash(&s, "b1", "Build")
        s.call("r1", "Read", #"{"file_path":"/r/C.swift"}"#)
        s.result("r1")
        s.call("g1", "Grep", #"{"pattern":"rowSpacing"}"#)
        s.result("g1")
        s.call("w1", "WebFetch", #"{"url":"https://docs.swift.org/x","prompt":"p"}"#)
        s.result("w1")

        XCTAssertEqual(
            run(s).line.text.string,
            sentence(
                words(String(localized: "Edited \(StyledText.slot(0))"), "A.swift"), String(localized: "Ran a command"),
                String(localized: "Fetched a page")) + String(localized: ", and \(2) more"))
    }

    func testTheLastCallFailingColoursTheTile() {
        var s = MessageScript()
        bash(&s, "b1", "Build")
        bash(&s, "b2", "Test", error: true)

        XCTAssertEqual(run(s).line.tile, Tile(glyph: .tool(.command), state: .failed))
    }

    /// A failed item is its red tile, and nothing more: why it failed is its
    /// document's. A command keeps its time, as a done one does.
    func testAFailedItemIsItsTileAndACommandKeepsItsTime() throws {
        var s = MessageScript()
        s.call("b1", "Bash", #"{"command":"make test","description":"Test"}"#)
        s.wait(20)
        s.result("b1", "Exit code 2\nmake: *** [all] Error 2", error: true)
        edit(&s, "e1", "/r/A.swift", error: true)

        let items = run(s).items
        XCTAssertEqual(items.map(\.line.tile.state), [.failed, .failed])
        let duration = try XCTUnwrap(items[0].calls[0].duration)
        XCTAssertEqual(items[0].line.meta.string, TimeInterval(duration).durationText, "the command's time")
        XCTAssertEqual(items[1].line.meta.string, "", "no word where a done edit has its stat")
        XCTAssertEqual(items.map(\.line.exceptions.string), ["", ""])
    }

    func testARunOfOneNamesTheCall() {
        var s = MessageScript()
        bash(&s, "b1", "Build the package")
        let line = run(s).line
        XCTAssertEqual(line.text.string, "Build the package")
        XCTAssertEqual(line.detail, "make", "a leading cd is where, not what")

        var e = MessageScript()
        edit(&e, "e1", "/r/Sources/Kit/A.swift")
        let edited = run(e)
        XCTAssertEqual(edited.line.text.string, words(String(localized: "Edited \(StyledText.slot(0))"), "A.swift"))
        XCTAssertEqual(edited.line.meta.string, "+2 −1")
        XCTAssertEqual(edited.items[0].line.text.string, "A.swift", "as a list item, the file alone")
        XCTAssertEqual(edited.items[0].line.detail, "Sources/Kit", "relative to the session's directory")
    }

    func testALongRunShowsItsTime() {
        var s = MessageScript()
        s.call("b1", "Bash", #"{"command":"make","description":"Build"}"#)
        s.wait(33)
        s.result("b1")
        s.call("b2", "Bash", #"{"command":"make","description":"Test"}"#)
        s.result("b2")

        XCTAssertEqual(run(s).line.meta.string, TimeInterval(36).durationText)
    }

    func testALiveRunSaysWhatIsHappeningNow() {
        var s = MessageScript()
        bash(&s, "b1", "Build")
        s.call("e1", "Edit", #"{"file_path":"/r/A.swift","old_string":"a","new_string":"b"}"#)

        let line = run(s).line
        XCTAssertEqual(line.text.string, words(String(localized: "Editing \(StyledText.slot(0))"), "A.swift"))
        XCTAssertEqual(line.tile, Tile(glyph: .tool(.change), state: .running))
    }

    func testSlotsLetATranslationReorderStyledArguments() {
        let text = StyledText(
            localized: "\(StyledText.slot(1)) と \(StyledText.slot(0))", StyledText("A", style: .code),
            StyledText("B", style: .noun(opens: nil)))
        XCTAssertEqual(
            text.runs,
            [
                .init(text: "B", style: .noun(opens: nil)), .init(text: " と ", style: .plain),
                .init(text: "A", style: .code),
            ])
    }
}

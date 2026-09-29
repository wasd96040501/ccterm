import AgentSDK
import XCTest

@testable import ccterm

/// How a page's entries become the transcript's rows: a run is its line and,
/// opened, one row per item up to twelve then *Show N more*; voices and plans
/// are a caption over TranscriptKit markdown (design/transcript/01-run.md
/// "Expanded", 06-voices.md, 07-talk.md).
final class PageRowTests: XCTestCase {

    private func run(of count: Int) -> TranscriptEntry {
        var s = MessageScript()
        for index in 0..<count {
            s.call("c\(index)", "Bash", #"{"command":"make","description":"Step \#(index)"}"#)
            s.result("c\(index)")
        }
        return s.page.entries[0]
    }

    private func parts(_ rows: [PageRow]) -> [PageRow.Part] {
        rows.map(\.id.part)
    }

    func testACollapsedRunIsItsLineAndAnOpenOneListsItsItems() {
        let entry = run(of: 3)
        XCTAssertEqual(parts(PageRow.rows(for: entry, disclosure: .collapsed)), [.main])
        XCTAssertEqual(
            parts(PageRow.rows(for: entry, disclosure: .expanded)), [.main, .item("c0"), .item("c1"), .item("c2")])
    }

    func testAListStopsAtTwelveUntilTheReaderAsksForAll() {
        let entry = run(of: 14)
        let expanded = PageRow.rows(for: entry, disclosure: .expanded)
        XCTAssertEqual(expanded.count, 1 + 12 + 1)
        XCTAssertEqual(expanded.last?.kind, .showMore(runID: "c0", hidden: 2))
        XCTAssertEqual(PageRow.rows(for: entry, disclosure: .showingAll).count, 1 + 14)
    }

    func testARunOfOneNeverExpandsAndOpensItsCall() {
        let rows = PageRow.rows(for: run(of: 1), disclosure: .expanded)
        XCTAssertEqual(parts(rows), [.main])
        XCTAssertEqual(rows[0].opens, "c0")
        XCTAssertNil(PageRow.rows(for: run(of: 2), disclosure: .collapsed)[0].opens, "a longer run's line toggles")
    }

    func testAVoiceIsACaptionOverItsWordsQuoted() {
        let voice = Voice(id: "v", sender: .coordinator, name: "Coordinator", text: "Found it.\n\nTwo more.")
        let rows = PageRow.rows(for: .voice(voice), disclosure: .collapsed)
        XCTAssertEqual(
            rows.map(\.kind),
            [
                .caption(Caption(glyph: .sender(.coordinator), text: "Coordinator")),
                .markdown("> Found it.\n>\n> Two more."),
            ])
    }

    func testRowIdentitiesAreUniqueAcrossAPage() {
        var s = MessageScript()
        s.prompt("Go")
        s.call("c1", "Bash", #"{"command":"make","description":"Build"}"#)
        s.result("c1")
        s.call("c2", "Bash", #"{"command":"make","description":"Test"}"#)
        s.result("c2")
        s.reply("Done")
        let page = s.page
        let rows = page.entries.flatMap { PageRow.rows(for: $0, disclosure: .expanded) }
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }
}

import AgentSDK
import AppKit
import TranscriptKit
import XCTest

@testable import ccterm

/// The reader's place holds while the page changes under it: opening or
/// closing a run above, below or at the viewport moves nothing on screen but
/// the rows that came or went, and ↓ scrolls at most one row. Mounts the
/// real tab on a long transcript, as the app does.
@MainActor
final class TranscriptScrollStabilityTests: XCTestCase {
    private var stage: AppKitStage!
    private var controller: TranscriptViewController!
    private var transcript: TranscriptView!
    private var clip: NSClipView!
    private var page: TranscriptPage!
    /// Runs this test opened, as the controller should now show them.
    private var expanded: Set<String> = []

    /// Enough runs that the history arrives in several chunks behind the first screen.
    private static let runs = 240

    override func setUp() async throws {
        // Not `continueAfterFailure = false`: interrupting an async test runs the
        // async tearDown from inside the failure and deadlocks.
        var script = MessageScript()
        for index in 0..<Self.runs {
            script.reply("Step \(index): what the model says between runs of work, long enough to wrap once or twice.")
            for call in 0..<4 {
                let id = "r\(index)c\(call)"
                script.call(id, "Bash", #"{"command":"make test-\#(call)","description":"Test \#(call)"}"#)
                script.result(id, call == 2 ? "Exit code 1\nerror: failed" : "ok", error: call == 2)
            }
        }
        page = script.page
        var file = Transcript(data: Data())
        file.messages = script.messages
        controller = TranscriptViewController(fileURL: URL(fileURLWithPath: "/nonexistent/s.jsonl"), title: "s") {
            _ in file
        }
        stage = AppKitStage.mount(controller, size: CGSize(width: 900, height: 700))
        transcript = try XCTUnwrap(stage.find(TranscriptView.self))
        clip = try XCTUnwrap(stage.find(NSScrollView.self, in: transcript)?.contentView)
        let total = PageRow.rows(for: page).count
        // Awaiting, not spinning the runloop: the load resumes on the main actor.
        for _ in 0..<250 where transcript.numberOfRows != total {
            await stage.settle(rounds: 1)
        }
        XCTAssertEqual(transcript.numberOfRows, total, "the page never loaded")
        await stage.settle()
    }

    override func tearDown() async throws {
        stage.teardown()
    }

    func testOpeningOrClosingARunAboveKeepsThePlace() async {
        let anchor = await centre(on: "r120c0")
        await assertStays(anchor, whileToggling: "r100c0")
        await assertStays(anchor, whileToggling: "r100c0")
    }

    func testOpeningOrClosingARunBelowKeepsThePlace() async {
        let anchor = await centre(on: "r120c0")
        await assertStays(anchor, whileToggling: "r140c0")
        await assertStays(anchor, whileToggling: "r140c0")
    }

    func testOpeningTheRunInViewKeepsItsLineWhereItIs() async {
        let anchor = await centre(on: "r120c0")
        await assertStays(anchor, whileToggling: "r120c0")
        await assertStays(anchor, whileToggling: "r120c0")
    }

    /// The run just above the top row opens: its items arrive exactly where
    /// the top row was, and the top row keeps its place.
    func testOpeningTheRunJustAboveTheTopRowKeepsIt() async {
        let all = rows()
        let reply = all.indices.first { $0 > 0 && all[$0 - 1].id.entry == "r119c0" && all[$0].id.entry != "r119c0" }!
        transcript.scrollToRow(at: reply, scrollPosition: .top)
        await stage.settle()
        let top = rows()[firstVisibleRow()].id
        XCTAssertEqual(top, rows()[reply].id, "premise: the reply after r119 is the top row")
        await assertStays(top, whileToggling: "r119c0")
    }

    /// Runs on screen open too, so what holds is the top of the screen: the
    /// first row in view stays where it is and everything opens below it.
    func testOpeningEveryRunKeepsTheTopRowInPlace() async {
        _ = await centre(on: "r120c0")
        let top = rows()[firstVisibleRow()].id
        let before = screenY(of: top)
        controller.rowView(NSView(), toggle: "r120c0", all: true)
        expanded = Set((0..<Self.runs).map { "r\($0)c0" })
        await stage.settle()
        XCTAssertEqual(transcript.numberOfRows, rows().count)
        XCTAssertEqual(screenY(of: top), before, accuracy: 0.5, "the top row moved when every run opened")
    }

    /// ↓ steps to the next item and scrolls no more than it takes to show it.
    func testDownStepsToTheNextItemAndScrollsAtMostOneRow() async throws {
        controller.rowView(NSView(), toggle: "r120c0", all: false)
        expanded.insert("r120c0")
        await stage.settle()
        _ = await centre(on: "r120c0")
        controller.rowView(NSView(), open: "r120c3", pinned: false)
        await stage.settle()
        var previous = clip.bounds.minY
        for _ in 0..<8 {
            XCTAssertTrue(
                controller.transcriptView(transcript, doCommandBy: #selector(NSResponder.moveDown(_:))),
                "↓ was not the tab's")
            await stage.settle()
            let moved = clip.bounds.minY - previous
            XCTAssertGreaterThanOrEqual(moved, -0.5, "↓ scrolled up")
            XCTAssertLessThanOrEqual(moved, 44.5, "↓ scrolled more than a row")
            previous = clip.bounds.minY
        }
    }

    // MARK: - Helpers

    /// The rows the controller should show now.
    private func rows() -> [PageRow] {
        page.entries.flatMap { PageRow.rows(for: $0, disclosure: expanded.contains($0.id) ? .expanded : .collapsed) }
    }

    /// Scrolls entry `id`'s first row to the middle, and answers its id.
    private func centre(on id: String) async -> PageRow.ID {
        let index = rows().firstIndex { $0.id.entry == id }!
        transcript.scrollToRow(at: index, scrollPosition: .center)
        await stage.settle()
        return rows()[index].id
    }

    /// The first row any of which is in view under the transcript's top inset —
    /// the one TranscriptKit holds in place.
    private func firstVisibleRow() -> Int {
        let top = clip.bounds.minY + (clip.enclosingScrollView?.contentInsets.top ?? 0)
        return (0..<transcript.numberOfRows).first { transcript.rect(ofRow: $0).maxY > top }!
    }

    /// Where row `id` is on screen: its top, from the top of the clip.
    private func screenY(of id: PageRow.ID) -> CGFloat {
        let index = rows().firstIndex { $0.id == id }!
        return transcript.rect(ofRow: index).minY - clip.bounds.minY
    }

    private func assertStays(
        _ anchor: PageRow.ID, whileToggling run: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let before = screenY(of: anchor)
        controller.rowView(NSView(), toggle: run, all: false)
        if expanded.contains(run) { expanded.remove(run) } else { expanded.insert(run) }
        await stage.settle()
        XCTAssertEqual(transcript.numberOfRows, rows().count, "rows after toggling \(run)", file: file, line: line)
        XCTAssertEqual(
            screenY(of: anchor), before, accuracy: 0.5, "toggling \(run) moved the row in view", file: file,
            line: line)
    }
}

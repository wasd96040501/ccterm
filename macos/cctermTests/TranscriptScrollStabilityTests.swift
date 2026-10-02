import AgentSDK
import AppKit
import TranscriptKit
import XCTest

@testable import ccterm

/// The reader's place holds while the page changes under it: opening or
/// closing a run above, below or at the viewport moves nothing on screen but
/// the rows that came or went. Mounts the
/// real tab on a long transcript, as the app does.
@MainActor
final class TranscriptScrollStabilityTests: XCTestCase {
    private var stage: AppKitStage!
    private var controller: TranscriptViewController!
    private var transcript: TranscriptView!
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
        controller.pageRowView(NSView(), didToggleDisclosureOf: "r120c0", inAllRuns: true)
        expanded = Set((0..<Self.runs).map { "r\($0)c0" })
        await stage.settle()
        XCTAssertEqual(transcript.numberOfRows, rows().count)
        XCTAssertEqual(screenY(of: top), before, accuracy: 0.5, "the top row moved when every run opened")
    }

    /// A run opened by its own line — the reader's click — opens with motion,
    /// and the line stays exactly where it was on every frame: the rows below
    /// slide away from it, nothing under the pointer jumps.
    ///
    /// Sampled after every run-loop turn in window coordinates, which is where
    /// the reader sees it; needs the display awake, since the motion advances
    /// on display refreshes. Under Reduce Motion the rows below land at once,
    /// and only that and the line holding are asserted.
    func testARunOpenedByItsLineOpensWithMotionAndTheLineHoldsStill() async throws {
        let line = await centre(on: "r120c0")
        let index = rows().firstIndex { $0.id == line }!
        let lineView = try XCTUnwrap(
            stage.findAll(WorkLineRowView.self, in: transcript).first { transcript.row(for: $0) == index })
        let nextView = try XCTUnwrap(
            stage.findAll(NSView.self, in: transcript).first { transcript.row(for: $0) == index + 1 })
        func windowY(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: nil).minY }
        let lineStart = windowY(lineView)
        let nextStart = windowY(nextView)

        controller.pageRowView(lineView, didToggleDisclosureOf: "r120c0", inAllRuns: false)
        expanded.insert("r120c0")
        var lineYs: [CGFloat] = []
        var nextYs: [CGFloat] = []
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
            lineYs.append(windowY(lineView))
            nextYs.append(windowY(nextView))
        }

        XCTAssertEqual(transcript.numberOfRows, rows().count)
        XCTAssertTrue(
            lineYs.allSatisfy { abs($0 - lineStart) < 0.5 }, "the clicked line moved: \(Set(lineYs).sorted())")
        let positions = Set(nextYs.map { ($0 * 2).rounded() / 2 })
        XCTAssertNotEqual(nextYs.last ?? nextStart, nextStart, accuracy: 0.5, "the row below never moved")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertEqual(positions.count, 1, "Reduce Motion is on, and the row below slid: \(positions.sorted())")
        } else {
            XCTAssertGreaterThan(
                positions.count, 3,
                "the row below jumped rather than slid: \(positions.sorted()); a screen: \(NSScreen.main != nil)")
        }
    }

    /// An opened run's items sit flush under its line and each other, and the
    /// next entry keeps the gap between entries (design README "Spacing").
    func testAnOpenedRunsItemsSitFlushUnderItsLine() async {
        let line = await centre(on: "r120c0")
        controller.pageRowView(NSView(), didToggleDisclosureOf: "r120c0", inAllRuns: false)
        expanded.insert("r120c0")
        await stage.settle()
        let rows = rows()
        let first = rows.firstIndex { $0.id == line }!
        let items = (first + 1..<rows.count).prefix { rows[$0].id.entry == "r120c0" }
        XCTAssertEqual(items.count, 4, "premise: the run opened")
        for row in items {
            XCTAssertEqual(
                transcript.rect(ofRow: row).minY, transcript.rect(ofRow: row - 1).maxY,
                "item \(row - first) isn't flush under the row above")
        }
        // Between entries the gap is measured from a line of work's words,
        // which sit `air` inside its box.
        let next = items.upperBound
        let nextIsWork = stage.findAll(WorkLineRowView.self, in: transcript).contains {
            transcript.row(for: $0) == next
        }
        let air = WorkLineRowView.air * (nextIsWork ? 2 : 1)
        XCTAssertEqual(
            transcript.rect(ofRow: next).minY - transcript.rect(ofRow: next - 1).maxY + air, 14,
            "the next entry isn't the gap between entries below the last item's words")
    }

    /// A hovered item slides down as a run opens above it, under a pointer
    /// that stays still: it stops showing the hover. Entered and exited come
    /// only when the pointer moves, so the row learns it from AppKit updating
    /// its tracking areas. The stage's window is off screen: the pointer is
    /// over none of it.
    func testAnItemThatSlidesFromUnderTheStillPointerLosesItsHover() async throws {
        _ = await centre(on: "r120c0")
        controller.pageRowView(NSView(), didToggleDisclosureOf: "r121c0", inAllRuns: false)
        expanded.insert("r121c0")
        await stage.settle()
        let item = rows().firstIndex { $0.id.entry == "r121c0" }! + 1
        let view = try XCTUnwrap(
            stage.findAll(WorkLineRowView.self, in: transcript).first { transcript.row(for: $0) == item })
        // The ↗ that opens beside shows only on hover; the tile has an image of its own.
        let arrow = try XCTUnwrap(view.subviews.lazy.compactMap { $0 as? NSImageView }.first)
        XCTAssertEqual(arrow.alphaValue, 0, "premise: the item isn't hovered")
        let entered = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseEntered(with: entered)
        XCTAssertEqual(arrow.alphaValue, 1, "premise: the item shows the hover")
        let before = view.convert(view.bounds, to: nil).minY

        controller.pageRowView(NSView(), didToggleDisclosureOf: "r120c0", inAllRuns: false)
        expanded.insert("r120c0")
        await stage.settle()

        XCTAssertEqual(transcript.row(for: view), item + 4, "premise: the same view holds the item")
        XCTAssertNotEqual(view.convert(view.bounds, to: nil).minY, before, accuracy: 0.5, "premise: the item moved")
        XCTAssertEqual(arrow.alphaValue, 0, "the item slid from under the pointer and still shows the hover")
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
        (0..<transcript.numberOfRows).first { transcript.rect(ofRow: $0).maxY > transcript.contentInsets.top }!
    }

    /// Where row `id` is on screen: its top, from the transcript's top.
    /// `rect(ofRow:)` answers with the scroll applied.
    private func screenY(of id: PageRow.ID) -> CGFloat {
        let index = rows().firstIndex { $0.id == id }!
        return transcript.rect(ofRow: index).minY
    }

    private func assertStays(
        _ anchor: PageRow.ID, whileToggling run: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let before = screenY(of: anchor)
        controller.pageRowView(NSView(), didToggleDisclosureOf: run, inAllRuns: false)
        if expanded.contains(run) { expanded.remove(run) } else { expanded.insert(run) }
        await stage.settle()
        XCTAssertEqual(transcript.numberOfRows, rows().count, "rows after toggling \(run)", file: file, line: line)
        XCTAssertEqual(
            screenY(of: anchor), before, accuracy: 0.5, "toggling \(run) moved the row in view", file: file,
            line: line)
    }
}

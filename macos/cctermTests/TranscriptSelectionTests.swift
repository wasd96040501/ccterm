import AppKit
import XCTest

@testable import AgentSDK
@testable import ccterm

/// Merge-gate probes for the history transcript's text selection — drives
/// the real `TranscriptSelectionCoordinator` through the mounted production
/// tree (`TranscriptViewController` → `TranscriptTableView` holds the
/// coordinator), asserting on `copyText()` output: the same observable
/// surface Cmd+C uses.
///
/// The private mouse-tracking loop (`NSApp.nextEvent`) can't run headless;
/// per test conventions the gesture's *algorithm* is driven directly
/// (`updateSelection` / `selectWord` / `selectUnit` / `selectAllText`),
/// which is everything below the event pump.
@MainActor
final class TranscriptSelectionTests: XCTestCase {

    enum FakeHistory: TranscriptHistoryService {
        nonisolated(unsafe) static var messages: [Message2] = []
        static func loadMessages(sessionId: String) -> [Message2] { messages }
    }

    private var window: NSWindow!
    private var vc: TranscriptViewController!
    private var store: TranscriptStore!
    private var table: TranscriptTableView!
    private var selection: TranscriptSelectionCoordinator!

    override func setUpWithError() throws {
        continueAfterFailure = false
        FakeHistory.messages = Self.fixture()
        store = TranscriptStore(historySource: FakeHistory.self)
        vc = TranscriptViewController(store: store)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 1200, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        vc.present(sessionId: "fixture")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        table = try XCTUnwrap(Self.findTable(in: vc.view))
        selection = try XCTUnwrap(table.selection, "VC must wire the selection coordinator")
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    // MARK: - Wiring

    func testSelectionIsWiredAndSelectableContentExists() {
        XCTAssertTrue(selection.isEmpty)
        XCTAssertTrue(selection.hasSelectableText)
        XCTAssertNotNil(selection.adapter(atRow: 0), "markdown row must be selectable")
        XCTAssertNil(selection.adapter(atRow: groupHeaderRow), "group-header rows expose no adapter")
    }

    // MARK: - Word / unit selection

    func testDoubleClickSelectsWord() {
        selection.selectWord(at: pointInRow(0, dx: 2, dy: 8))
        XCTAssertEqual(selection.copyText(), "Hello")
        XCTAssertFalse(selection.isEmpty)
    }

    func testClearAllEmptiesSelection() {
        selection.selectWord(at: pointInRow(0, dx: 2, dy: 8))
        XCTAssertFalse(selection.isEmpty)
        selection.clearAll()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.copyText(), "")
    }

    // MARK: - Multi-row sweep

    func testDragSweepAcrossParagraphs() {
        selection.updateSelection(
            from: pointInRow(0, dx: 2, dy: 8),
            to: pointInRow(1, dx: 600, dy: 8))
        let copied = selection.copyText()
        XCTAssertTrue(copied.contains("Hello"), "sweep must include the first paragraph")
        XCTAssertTrue(
            copied.contains("Second paragraph."), "sweep must include the second paragraph")
    }

    func testSweepAcrossHeaderRowSkipsItSilently() {
        // Row order: para, para, group header (adapter-less), user bubble.
        // The sweep bottom targets the bubble row; dx runs past the
        // column's right edge so the bottom endpoint clamps to the bubble
        // text's end.
        let lastRow = table.numberOfRows - 1
        selection.updateSelection(
            from: pointInRow(0, dx: 2, dy: 8),
            to: pointInRow(lastRow, dx: 900, dy: table.rect(ofRow: lastRow).height / 2))
        let copied = selection.copyText()
        XCTAssertTrue(copied.contains("Hello"))
        XCTAssertTrue(copied.contains("Second paragraph."))
        XCTAssertTrue(copied.contains("thanks!"), "bubble at the sweep bottom is included")
        XCTAssertFalse(
            headerTitle.isEmpty, "fixture must produce a group header")
        XCTAssertFalse(
            copied.contains(headerTitle), "header narration text must never enter the copy")
    }

    // MARK: - Select all

    func testSelectAllTextCopiesEverySelectableRow() {
        selection.selectAllText()
        let copied = selection.copyText()
        XCTAssertTrue(copied.contains("Hello"))
        XCTAssertTrue(copied.contains("Second paragraph."))
        XCTAssertTrue(copied.contains("thanks!"))
        XCTAssertFalse(
            copied.contains(headerTitle),
            "the group header is not selectable and must not be copied")
    }

    // MARK: - Helpers

    /// The row index of the (single) group header in the fixture.
    private var groupHeaderRow: Int {
        store.rows.firstIndex {
            if case .groupHeader = $0.content { return true }
            return false
        } ?? -1
    }

    /// The group header's title (for asserting it never leaks into a copy).
    private var headerTitle: String {
        for row in store.rows {
            if case .groupHeader(let t) = row.content { return t }
        }
        return ""
    }

    /// A document-space point inside `row`, offset from the row's content
    /// origin (the same origin the selection algorithm uses).
    private func pointInRow(_ row: Int, dx: CGFloat, dy: CGFloat) -> CGPoint {
        let rect = table.rect(ofRow: row)
        let x = TranscriptMetrics.contentX(forRowWidth: table.bounds.width)
        return CGPoint(x: x + dx, y: rect.minY + dy)
    }

    private static func findTable(in view: NSView) -> TranscriptTableView? {
        if let table = view as? TranscriptTableView { return table }
        for sub in view.subviews {
            if let found = findTable(in: sub) { return found }
        }
        return nil
    }

    /// 2 paras + (Read + Bash) group header + user bubble.
    private static func fixture() -> [Message2] {
        let resolver = Message2Resolver()
        func resolve(_ dict: [String: Any]) -> Message2 { try! resolver.resolve(dict) }
        return [
            resolve([
                "type": "assistant", "uuid": UUID().uuidString, "session_id": "s",
                "message": [
                    "id": "m1", "type": "message", "role": "assistant",
                    "content": [
                        ["type": "text", "text": "Hello **world**\n\nSecond paragraph."]
                    ],
                ],
            ]),
            resolve([
                "type": "assistant", "uuid": UUID().uuidString, "session_id": "s",
                "message": [
                    "id": "m2", "type": "message", "role": "assistant",
                    "content": [
                        [
                            "type": "tool_use", "id": "t1", "name": "Read",
                            "input": ["file_path": "/tmp/greeter.swift"],
                        ],
                        [
                            "type": "tool_use", "id": "t2", "name": "Bash",
                            "input": ["command": "echo hi", "description": "greet"],
                        ],
                    ],
                ],
            ]),
            resolve([
                "type": "user", "uuid": UUID().uuidString, "session_id": "s",
                "message": ["role": "user", "content": "thanks!"],
            ]),
        ]
    }
}

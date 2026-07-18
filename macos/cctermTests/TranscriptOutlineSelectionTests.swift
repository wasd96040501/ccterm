import AppKit
import XCTest

@testable import AgentSDK
@testable import ccterm

/// Merge-gate probes for the outline transcript's text selection —
/// drives the real `TranscriptSelectionCoordinator` through the mounted
/// production tree (`TranscriptViewController` → `TranscriptOutlineView`
/// holds the coordinator), asserting on `copyText()` output: the same
/// observable surface Cmd+C uses.
///
/// The private mouse-tracking loop (`NSApp.nextEvent`) can't run
/// headless; per test conventions the gesture's *algorithm* is driven
/// directly (`updateSelection` / `selectWord` / `selectUnit` /
/// `selectAllText`), which is everything below the event pump.
@MainActor
final class TranscriptOutlineSelectionTests: XCTestCase {

    enum FakeHistory: TranscriptHistoryService {
        nonisolated(unsafe) static var messages: [Message2] = []
        static func loadMessages(sessionId: String) -> [Message2] { messages }
    }

    private var window: NSWindow!
    private var vc: TranscriptViewController!
    private var store: TranscriptStore!
    private var outline: TranscriptOutlineView!
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
        outline = try XCTUnwrap(Self.findOutline(in: vc.view))
        selection = try XCTUnwrap(outline.selection, "VC must wire the selection coordinator")
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
        let groupRow = outline.row(forItem: store.roots.first { $0.isExpandable })
        XCTAssertNil(selection.adapter(atRow: groupRow), "header rows expose no adapter")
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
        // The sweep bottom targets the bubble row's vertical middle —
        // its top band is bubble padding where a hit-test resolves to
        // char 0 (an empty range that would drop the row by design).
        // dx runs past the column's right edge so the bottom endpoint
        // clamps to the bubble text's end (a mid-text endpoint would
        // legitimately copy only a prefix).
        let lastRow = outline.numberOfRows - 1
        selection.updateSelection(
            from: pointInRow(0, dx: 2, dy: 8),
            to: pointInRow(lastRow, dx: 900, dy: outline.rect(ofRow: lastRow).height / 2))
        let copied = selection.copyText()
        XCTAssertTrue(copied.contains("Hello"))
        XCTAssertTrue(copied.contains("Second paragraph."))
        XCTAssertTrue(copied.contains("thanks!"), "bubble at the sweep bottom is included")
        XCTAssertFalse(
            copied.contains("已"), "header narration text must never enter the copy")
    }

    // MARK: - Select all

    func testSelectAllTextCopiesEveryVisibleSelectableRow() {
        selection.selectAllText()
        let copied = selection.copyText()
        XCTAssertTrue(copied.contains("Hello"))
        XCTAssertTrue(copied.contains("Second paragraph."))
        XCTAssertTrue(copied.contains("thanks!"))
    }

    func testSelectAllSkipsCollapsedToolBodies() {
        selection.selectAllText()
        XCTAssertFalse(
            selection.copyText().contains("print(1)"),
            "collapsed tool bodies are not visible rows and must not be copied")
    }

    // MARK: - Tool body selection

    func testToolBodySelectsAndCopies() throws {
        let group = try XCTUnwrap(store.roots.first { $0.isExpandable })
        let readTool = try XCTUnwrap(group.children.first)
        outline.expandItem(group)
        outline.expandItem(readTool)
        outline.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let body = try XCTUnwrap(readTool.children.first)
        let bodyRow = outline.row(forItem: body)
        XCTAssertGreaterThanOrEqual(bodyRow, 0, "expanded body must be a visible row")
        XCTAssertNotNil(
            selection.adapter(atRow: bodyRow), "tool body must expose a selection adapter")

        // Triple-click semantics: whole unit (the diff card's content).
        selection.selectUnit(at: pointInRow(bodyRow, dx: 60, dy: 12))
        XCTAssertEqual(selection.copyText(), "print(1)")
    }

    // MARK: - Helpers

    /// A document-space point inside `row`, offset from the row's
    /// content origin (the same origin the selection algorithm uses).
    private func pointInRow(_ row: Int, dx: CGFloat, dy: CGFloat) -> CGPoint {
        let rect = outline.rect(ofRow: row)
        let level = max(0, outline.level(forRow: row))
        let isHeader = (outline.item(atRow: row) as? TranscriptNodeItem)?.isHeader ?? false
        let x = TranscriptOutlineMetrics.contentX(
            forRowWidth: outline.bounds.width, level: level, hasChevronSlot: isHeader)
        return CGPoint(x: x + dx, y: rect.minY + dy)
    }

    private static func findOutline(in view: NSView) -> TranscriptOutlineView? {
        if let outline = view as? TranscriptOutlineView { return outline }
        for sub in view.subviews {
            if let found = findOutline(in: sub) { return found }
        }
        return nil
    }

    /// Same shape as the geometry-test fixture: 2 paras + (Read + Bash)
    /// group + user bubble. One stateful resolver across messages.
    private static func fixture() -> [Message2] {
        let resolver = Message2Resolver()
        func resolve(_ dict: [String: Any]) -> Message2 {
            try! resolver.resolve(dict)
        }
        return [
            resolve([
                "type": "assistant",
                "uuid": UUID().uuidString,
                "session_id": "s",
                "message": [
                    "id": "m1", "type": "message", "role": "assistant",
                    "content": [
                        ["type": "text", "text": "Hello **world**\n\nSecond paragraph."]
                    ],
                ],
            ]),
            resolve([
                "type": "assistant",
                "uuid": UUID().uuidString,
                "session_id": "s",
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
                "message": [
                    "role": "user",
                    "content": [
                        ["type": "tool_result", "tool_use_id": "t1", "content": "1\tprint(1)"]
                    ],
                ],
            ]),
            resolve([
                "type": "user", "uuid": UUID().uuidString, "session_id": "s",
                "message": [
                    "role": "user",
                    "content": [
                        ["type": "tool_result", "tool_use_id": "t2", "content": "hi"]
                    ],
                ],
                "tool_use_result": [
                    "stdout": "hi", "stderr": "", "interrupted": false,
                    "isImage": false,
                ],
            ]),
            resolve([
                "type": "user", "uuid": UUID().uuidString, "session_id": "s",
                "message": ["role": "user", "content": "thanks!"],
            ]),
        ]
    }
}

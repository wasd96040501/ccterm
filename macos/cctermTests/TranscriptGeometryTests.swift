import AppKit
import XCTest

@testable import AgentSDK
@testable import ccterm

/// Merge-gate geometry probes for the flat history transcript
/// (assertion-driven, no `Snapshot` suffix — runs on the default suite +
/// CI).
///
/// Gates the geometry model:
///  1. The table documentView is **full-width and frame-based** — never
///     constrained narrower than the clip (the NSTableView contract).
///  2. Typeset widths all derive from `TranscriptMetrics` (single
///     chokepoint), and a width change re-typesets every row.
///  3. The two-phase live-resize contract holds: visible-only invalidation
///     mid-drag, off-screen refill + visual-top anchor at end.
@MainActor
final class TranscriptGeometryTests: XCTestCase {

    /// Fake history source — a static seam the store injects. Safe as a
    /// static because test classes run one per process.
    enum FakeHistory: TranscriptHistoryService {
        nonisolated(unsafe) static var messages: [Message2] = []
        static func loadMessages(sessionId: String) -> [Message2] { messages }
    }

    private var window: NSWindow!
    private var vc: TranscriptViewController!
    private var store: TranscriptStore!
    private var table: NSTableView!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let mount = Self.mountTable(messages: Self.fixture(), height: 700)
        window = mount.window
        vc = mount.vc
        store = mount.store
        table = mount.table
    }

    override func tearDown() async throws {
        InLiveResizeShim.clearAll()
        window?.close()
        window = nil
    }

    // MARK: - 1. Full-width frame-based document

    func testTableDocumentIsFullClipWidth() throws {
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertEqual(
            table.frame.width, scroll.contentView.bounds.width, accuracy: 0.5,
            "table documentView must span the clip (NSTableView contract)")
        XCTAssertTrue(
            table.translatesAutoresizingMaskIntoConstraints,
            "table must stay frame-based — translates=false breaks documentView height")
        XCTAssertGreaterThan(table.frame.height, 0)
    }

    // MARK: - 2. Centered column + typeset widths from the single chokepoint

    func testTypesetWidthsDeriveFromTheSingleChokepoint() throws {
        let rowWidth: CGFloat = 1200
        let pad = BlockStyle.blockHorizontalPadding
        XCTAssertEqual(
            TranscriptMetrics.layoutWidth(forRowWidth: rowWidth),
            BlockStyle.maxLayoutWidth - 2 * pad)
        XCTAssertEqual(
            TranscriptMetrics.columnX(forRowWidth: rowWidth),
            (rowWidth - BlockStyle.maxLayoutWidth) / 2, accuracy: 0.5,
            "wide window: column is the 780pt band centered in the row")

        // A markdown row's cached layout is typeset no wider than its slot.
        let markdown = try XCTUnwrap(
            store.rows.first {
                if case .block = $0.content { return true }
                return false
            })
        let slot = TranscriptMetrics.layoutWidth(forRowWidth: table.bounds.width)
        let layout = store.rowLayout(for: markdown, width: slot)
        XCTAssertLessThanOrEqual(layout.measuredWidth, slot + 0.5)
    }

    // MARK: - 3. Width-change re-typesets every row

    /// A width change re-typesets every row at the new width. Drives the
    /// non-live `tableFrameDidChange` branch (headless: `inLiveResize` is
    /// false); without the frame observer the cache would survive and text
    /// would stop reflowing.
    func testWidthChangeRetypesetsRowsAtNewWidth() throws {
        let wide = TranscriptMetrics.layoutWidth(forRowWidth: table.bounds.width)
        let firstRow = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(
            try XCTUnwrap(store.cachedWidth(for: firstRow.id)), wide, accuracy: 0.5,
            "precondition: rows cached at the wide (clamped-max) width")

        // Narrow past the >max clamp band so the per-row typeset width
        // actually changes (1200 → col 780; 600 → col 600).
        window.setContentSize(NSSize(width: 600, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        drain(0.2)

        let narrow = TranscriptMetrics.layoutWidth(forRowWidth: table.bounds.width)
        XCTAssertLessThan(narrow, wide, "column must actually narrow")
        for row in store.rows {
            XCTAssertEqual(
                try XCTUnwrap(store.cachedWidth(for: row.id)), narrow, accuracy: 0.5,
                "every row must be re-typeset at the narrowed width")
        }
    }

    // MARK: - 4. Live-resize two-phase (visible mid-drag, off-screen at end)

    /// Full live-resize lifecycle through the real production handlers
    /// (driven by `LiveResizeHarness`). Asserts the two-phase contract —
    /// **during the drag** only the visible rows re-typeset while an
    /// off-screen row keeps its stale layout (bounded per-frame work);
    /// **at end** the off-screen row is refilled at the settled width.
    func testLiveResizeInvalidatesVisibleThenRefillsOffscreen() throws {
        let mount = Self.mountTable(messages: Self.longFixture(count: 20), height: 500)
        addTeardownBlock { @MainActor in mount.window.close() }
        let localTable = mount.table
        let localStore = mount.store

        localTable.scrollRowToVisible(0)
        localTable.layoutSubtreeIfNeeded()
        drain(0.1)

        func widthNow() -> CGFloat {
            TranscriptMetrics.layoutWidth(forRowWidth: localTable.bounds.width)
        }
        let wide = widthNow()
        let visibleRow = try XCTUnwrap(localStore.rows.first)
        let offscreen = try XCTUnwrap(
            firstOffscreenRow(in: localTable, store: localStore),
            "the long fixture must push a row below the fold for this probe")
        XCTAssertEqual(
            try XCTUnwrap(localStore.cachedWidth(for: offscreen.id)), wide, accuracy: 0.5)

        let harness = LiveResizeHarness(window: mount.window, view: localTable)
        harness.begin()
        harness.step(toContentWidth: 600)

        let narrow = widthNow()
        XCTAssertLessThan(narrow, wide, "column must actually narrow")
        XCTAssertEqual(
            try XCTUnwrap(localStore.cachedWidth(for: visibleRow.id)), narrow, accuracy: 0.5,
            "visible row must reflow mid-drag")
        XCTAssertEqual(
            try XCTUnwrap(localStore.cachedWidth(for: offscreen.id)), wide, accuracy: 0.5,
            "off-screen row must keep its stale layout mid-drag (visible-only invalidation)")

        harness.end()
        waitUntil("off-screen row refills after live-resize end") {
            abs((localStore.cachedWidth(for: offscreen.id) ?? -1) - narrow) < 0.5
        }
    }

    // MARK: - 5. Post-resize refill keeps the visual-top anchor

    /// The end-of-resize refill corrects off-screen rows' heights; when
    /// those rows sit **above** the viewport, that shifts the visible
    /// content unless the visual-top anchor compensates.
    func testLiveResizeEndKeepsVisualTopPinned() throws {
        let mount = Self.mountTable(messages: Self.longFixture(count: 16), height: 400)
        addTeardownBlock { @MainActor in mount.window.close() }
        let localTable = mount.table
        let localStore = mount.store

        // Scroll to the tail so the early long paragraphs sit above the fold.
        localTable.scrollRowToVisible(localTable.numberOfRows - 1)
        localTable.layoutSubtreeIfNeeded()
        drain(0.1)

        let clip = try XCTUnwrap(localTable.enclosingScrollView).contentView
        let visBefore = localTable.rows(in: localTable.visibleRect)
        XCTAssertGreaterThan(
            visBefore.location, 0, "premise: some rows must sit above the viewport")
        let anchor = try XCTUnwrap(localStore.row(at: visBefore.location))
        let screenYBefore =
            localTable.rect(ofRow: visBefore.location).minY - clip.bounds.origin.y

        let harness = LiveResizeHarness(window: mount.window, view: localTable)
        harness.begin()
        harness.step(toContentWidth: 520)  // narrow → long paragraphs wrap taller
        harness.end()

        // Wait for the async refill to correct an above-viewport paragraph.
        let firstRow = try XCTUnwrap(localStore.rows.first)
        let narrow = TranscriptMetrics.layoutWidth(forRowWidth: localTable.bounds.width)
        waitUntil("above-viewport rows refill at end") {
            abs((localStore.cachedWidth(for: firstRow.id) ?? -1) - narrow) < 0.5
        }
        localTable.layoutSubtreeIfNeeded()

        let newRow = try XCTUnwrap(localStore.index(for: anchor.id))
        let screenYAfter = localTable.rect(ofRow: newRow).minY - clip.bounds.origin.y
        XCTAssertEqual(
            screenYAfter, screenYBefore, accuracy: 2.0,
            "the top visible row must stay pinned across the end-of-resize refill")
    }

    // MARK: - Helpers

    private static func mountTable(
        messages: [Message2], height: CGFloat
    ) -> (window: NSWindow, vc: TranscriptViewController, store: TranscriptStore, table: NSTableView) {
        FakeHistory.messages = messages
        let store = TranscriptStore(historySource: FakeHistory.self)
        let vc = TranscriptViewController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 1200, height: height))
        window.contentView?.layoutSubtreeIfNeeded()
        vc.present(sessionId: "fixture")
        let table = findTable(in: vc.view)!
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        return (window, vc, store, table)
    }

    /// `count` long wrapping paragraphs — each reflows to a different line
    /// count (and height) at 520 vs 780, so narrowing genuinely grows the
    /// rows and the list overflows the viewport.
    private static func longFixture(count: Int) -> [Message2] {
        let resolver = Message2Resolver()
        func resolve(_ dict: [String: Any]) -> Message2 { try! resolver.resolve(dict) }
        let long = String(
            repeating: "The quick brown fox jumps over the lazy dog. ", count: 8)
        return (0..<count).map { i in
            resolve([
                "type": "assistant", "uuid": UUID().uuidString, "session_id": "s",
                "message": [
                    "id": "m\(i)", "type": "message", "role": "assistant",
                    "content": [["type": "text", "text": long]],
                ],
            ])
        }
    }

    /// The first row whose index currently sits outside the viewport.
    private func firstOffscreenRow(
        in table: NSTableView, store: TranscriptStore
    ) -> TranscriptRow? {
        let visible = table.rows(in: table.visibleRect)
        let lo = visible.location
        let hi = visible.location + visible.length
        for index in 0..<table.numberOfRows where index < lo || index >= hi {
            return store.row(at: index)
        }
        return nil
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func drain(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let found = findTable(in: sub) { return found }
        }
        return nil
    }

    /// 2 markdown paras + a 2-tool group header + a user bubble → 4 rows.
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
                            "input": ["command": "seq 60", "description": "count"],
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

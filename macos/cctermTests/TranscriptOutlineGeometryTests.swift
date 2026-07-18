import AppKit
import XCTest

@testable import AgentSDK
@testable import ccterm

/// Merge-gate geometry probes for the outline transcript (assertion-driven,
/// no `Snapshot` suffix — runs on the default suite + CI).
///
/// Gates the v2 geometry model (SPEC §5):
///  1. The outline documentView is **full-width and frame-based** — never
///     constrained narrower than the clip (the table-family contract).
///  2. **Animated** (click-style) expansion grows the document height so
///     the tail stays reachable — the "can't scroll down after expanding a
///     tool" regression: under `translates=false` the animated path only
///     updated `intrinsicContentSize` and the frame stayed stale.
///  3. The centered column + chevron placement + typeset widths all agree
///     via `TranscriptOutlineMetrics` (single chokepoint).
///  4. The L1/L2/L3 vertical rhythm holds (4pt header gaps, 8pt block tier).
@MainActor
final class TranscriptOutlineGeometryTests: XCTestCase {

    /// Fake history source — a static seam the store injects. Safe as a
    /// static because test classes run one per process.
    enum FakeHistory: TranscriptHistoryService {
        nonisolated(unsafe) static var messages: [Message2] = []
        static func loadMessages(sessionId: String) -> [Message2] { messages }
    }

    private var window: NSWindow!
    private var vc: TranscriptViewController!
    private var store: TranscriptStore!
    private var outline: NSOutlineView!

    override func setUpWithError() throws {
        continueAfterFailure = false
        FakeHistory.messages = Self.fixture()
        store = TranscriptStore(historySource: FakeHistory.self)
        vc = TranscriptViewController(store: store)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        // Programmatic NSWindow defaults to isReleasedWhenClosed=true;
        // combined with ARC that double-releases on close() in tearDown.
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        // Setting contentViewController resizes the window to the VC's
        // fitting size (≈ 0 for a pin-only pane); restore the real size
        // so the clip/outline lay out at production-like width.
        window.setContentSize(NSSize(width: 1200, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        vc.present(sessionId: "fixture")
        drain(0.2)
        outline = try XCTUnwrap(Self.findOutline(in: vc.view), "no NSOutlineView mounted")
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    // MARK: - 1. Full-width frame-based document

    func testOutlineDocumentIsFullClipWidth() throws {
        let scroll = try XCTUnwrap(outline.enclosingScrollView)
        XCTAssertEqual(
            outline.frame.width, scroll.contentView.bounds.width, accuracy: 0.5,
            "outline documentView must span the clip (table-family contract)")
        XCTAssertTrue(
            outline.translatesAutoresizingMaskIntoConstraints,
            "outline must stay frame-based — translates=false breaks animated-expand height")
        XCTAssertGreaterThan(outline.frame.height, 0)
    }

    // MARK: - 2. Animated expansion keeps the tail reachable (Q5 gate)

    func testAnimatedExpansionGrowsDocumentHeight() throws {
        let group = try XCTUnwrap(store.roots.first { $0.isExpandable })

        NSAnimationContext.runAnimationGroup { _ in
            outline.animator().expandItem(group)
        }
        waitUntil("group expansion settles") { [self] in
            outline.numberOfRows == 6 && documentCoversLastRow()
        }

        // Expand the Bash tool (second tool_use → last child) — its
        // stdout body is tall, so the new bottom lands beyond the old
        // document bottom (the exact repro condition of the stuck-height
        // bug).
        let bashTool = try XCTUnwrap(group.children.last, "expected two tools in the group")
        XCTAssertTrue(bashTool.isExpandable, "bash tool must carry a body")
        let heightBefore = outline.frame.height
        NSAnimationContext.runAnimationGroup { _ in
            outline.animator().expandItem(bashTool)
        }
        // Settled = the tail actually moved past the old document bottom
        // (rows animate in from collapsed positions, so a covers-check
        // alone is satisfied spuriously mid-slide) AND the frame covers it.
        let deadline = Date().addingTimeInterval(5)
        var lastMaxY: CGFloat = 0
        while Date() < deadline {
            lastMaxY = outline.rect(ofRow: max(0, outline.numberOfRows - 1)).maxY
            if outline.numberOfRows == 7, lastMaxY > heightBefore + 50,
                outline.frame.height >= lastMaxY - 0.5
            {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(outline.numberOfRows, 7, "tool body row must be inserted")
        XCTAssertGreaterThan(
            lastMaxY, heightBefore + 50,
            "bash body must push the tail past the old bottom — frame=\(outline.frame) lastMaxY=\(lastMaxY) rows=\(outline.numberOfRows)"
        )
        XCTAssertGreaterThanOrEqual(
            outline.frame.height, lastMaxY - 0.5,
            "document frame must cover the expanded tail (stuck-height regression)")
        XCTAssertGreaterThan(
            outline.frame.height, heightBefore,
            "expanding a tall tool body must grow the document frame")

        // The clip must be able to scroll the last row fully into view.
        let scroll = try XCTUnwrap(outline.enclosingScrollView)
        let clip = scroll.contentView
        let lastRect = outline.rect(ofRow: outline.numberOfRows - 1)
        let target = NSRect(
            origin: NSPoint(x: clip.bounds.origin.x, y: 100_000),
            size: clip.bounds.size)
        let constrained = clip.constrainBoundsRect(target)
        XCTAssertGreaterThanOrEqual(
            constrained.maxY + scroll.contentInsets.bottom, lastRect.maxY - 0.5,
            "clip scroll clamp must reach the expanded tail")
    }

    // MARK: - 3. Centered column, chevron placement, typeset widths

    func testChevronSitsAtColumnContentEdge() throws {
        let group = try XCTUnwrap(store.roots.first { $0.isExpandable })
        let rowWidth = outline.bounds.width
        let columnX = TranscriptOutlineMetrics.columnX(forRowWidth: rowWidth)
        XCTAssertEqual(
            columnX, (rowWidth - BlockStyle.maxLayoutWidth) / 2, accuracy: 0.5,
            "wide window: column is the 780pt band centered in the row")

        let groupRow = outline.row(forItem: group)
        XCTAssertGreaterThanOrEqual(groupRow, 0)
        let chevron = outline.frameOfOutlineCell(atRow: groupRow)
        XCTAssertEqual(
            chevron.origin.x, columnX + BlockStyle.blockHorizontalPadding, accuracy: 0.5,
            "level-0 chevron aligns with the column's text edge (markdown left edge)")

        outline.expandItem(group)
        outline.layoutSubtreeIfNeeded()
        let tool = try XCTUnwrap(group.children.first)
        let toolChevron = outline.frameOfOutlineCell(atRow: outline.row(forItem: tool))
        XCTAssertEqual(
            toolChevron.origin.x,
            columnX + BlockStyle.blockHorizontalPadding + TranscriptOutlineMetrics.indentStep,
            accuracy: 0.5,
            "level-1 chevron indents by exactly one indentStep")
    }

    func testTypesetWidthsDeriveFromTheSingleChokepoint() throws {
        let rowWidth: CGFloat = 1200
        let pad = BlockStyle.blockHorizontalPadding
        XCTAssertEqual(
            TranscriptOutlineMetrics.layoutWidth(
                forRowWidth: rowWidth, level: 0, hasChevronSlot: false),
            BlockStyle.maxLayoutWidth - 2 * pad)
        XCTAssertEqual(
            TranscriptOutlineMetrics.layoutWidth(
                forRowWidth: rowWidth, level: 1, hasChevronSlot: true),
            BlockStyle.maxLayoutWidth - 2 * pad - TranscriptOutlineMetrics.indentStep
                - TranscriptOutlineMetrics.chevronSlot)

        // A markdown root's cached layout is typeset no wider than its slot.
        let markdown = try XCTUnwrap(store.roots.first { !$0.isExpandable })
        let slot = TranscriptOutlineMetrics.layoutWidth(
            forRowWidth: outline.bounds.width, level: 0, hasChevronSlot: false)
        let layout = store.rowLayout(for: markdown, width: slot)
        XCTAssertLessThanOrEqual(layout.measuredWidth, slot + 0.5)
    }

    // MARK: - 4. L1 / L2 / L3 vertical rhythm

    func testVerticalRhythmMatchesToolHeaderSpacing() throws {
        let group = try XCTUnwrap(store.roots.first { $0.isExpandable })
        let tool = try XCTUnwrap(group.children.first)
        let body = try XCTUnwrap(tool.children.first)

        let l1 = store.verticalPadding(for: group, level: 0)
        let l2 = store.verticalPadding(for: tool, level: 1)
        let l3 = store.verticalPadding(for: body, level: 2)

        XCTAssertEqual(l1.top, 8, "group header rides the hard-edged block tier")
        XCTAssertEqual(
            l1.bottom + l2.top, BlockStyle.toolHeaderChildSpacing,
            "group header ↔ tool header gap is the canonical 4pt")
        XCTAssertEqual(
            l2.bottom + l3.top, BlockStyle.toolHeaderChildSpacing,
            "tool header ↔ body gap is the canonical 4pt")
        XCTAssertEqual(
            l3.bottom + l2.top, BlockStyle.toolHeaderChildSpacing,
            "body ↔ next tool header gap is the canonical 4pt")

        // Row height = padding + layout height, at the row's real slot width.
        let slot = TranscriptOutlineMetrics.layoutWidth(
            forRowWidth: outline.bounds.width, level: 0, hasChevronSlot: true)
        let height = store.height(for: group, width: slot, level: 0)
        let layout = store.rowLayout(for: group, width: slot)
        XCTAssertEqual(height, l1.top + layout.totalHeight + l1.bottom, accuracy: 0.01)
    }

    // MARK: - Helpers

    private func documentCoversLastRow() -> Bool {
        let last = outline.numberOfRows - 1
        guard last >= 0 else { return false }
        return outline.frame.height >= outline.rect(ofRow: last).maxY - 0.5
    }

    /// Runloop-driven wait (services CA animation ticks); fails the test
    /// on timeout. Not a sleep — the runloop keeps draining.
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

    private static func findOutline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for sub in view.subviews {
            if let found = findOutline(in: sub) { return found }
        }
        return nil
    }

    /// 2 markdown paras + a 2-tool group (Read + Bash, Bash with a tall
    /// stdout body) + a user bubble → 4 roots.
    ///
    /// One `Message2Resolver` across all messages — the resolver is
    /// stateful (it types a `tool_use_result` by pairing the id against
    /// earlier assistant `tool_use`s), same as the production
    /// `SessionHistory` line loop.
    private static func fixture() -> [Message2] {
        let resolver = Message2Resolver()
        func resolve(_ dict: [String: Any]) -> Message2 {
            try! resolver.resolve(dict)
        }
        let tallStdout = (1...60).map { "line \($0)" }.joined(separator: "\n")
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
                            "input": ["command": "seq 60", "description": "count"],
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
                        ["type": "tool_result", "tool_use_id": "t2", "content": tallStdout]
                    ],
                ],
                "tool_use_result": [
                    "stdout": tallStdout, "stderr": "", "interrupted": false,
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

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
        InLiveResizeShim.clearAll()
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

    // MARK: - 5. Live-resize width tracking

    /// A width change re-typesets every row at the new width. Drives the
    /// non-live `outlineFrameDidChange` branch (headless: `inLiveResize`
    /// is false), which reaches the same end state as the live path's
    /// visible-invalidate + post-resize refill: no row keeps its old-width
    /// cached layout. Without the frame observer the cache would survive
    /// and text would stop reflowing.
    func testWidthChangeRetypesetsRowsAtNewWidth() throws {
        let markdown = try XCTUnwrap(store.roots.first { !$0.isExpandable })
        let wide = TranscriptOutlineMetrics.layoutWidth(
            forRowWidth: outline.bounds.width, level: 0, hasChevronSlot: false)
        XCTAssertEqual(
            try XCTUnwrap(store.cachedWidth(for: markdown.id)), wide, accuracy: 0.5,
            "precondition: root cached at the wide (clamped-max) width")

        // Narrow past the >max clamp band so the per-row typeset width
        // actually changes (1200 → col 780; 600 → col 600).
        window.setContentSize(NSSize(width: 600, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        outline.layoutSubtreeIfNeeded()
        drain(0.2)

        let narrow = TranscriptOutlineMetrics.layoutWidth(
            forRowWidth: outline.bounds.width, level: 0, hasChevronSlot: false)
        XCTAssertLessThan(narrow, wide, "column must actually narrow")
        for root in store.roots {
            let expected = TranscriptOutlineMetrics.layoutWidth(
                forRowWidth: outline.bounds.width,
                level: 0, hasChevronSlot: root.isHeader)
            XCTAssertEqual(
                try XCTUnwrap(store.cachedWidth(for: root.id)), expected, accuracy: 0.5,
                "every visible root must be re-typeset at the narrowed width")
        }
    }

    /// The native disclosure triangle tracks the width change — its frame
    /// re-derives from the live `bounds.width` through the same
    /// `TranscriptOutlineMetrics` chokepoint as the typeset content, so the
    /// chevron can't drift from the column edge on resize.
    func testChevronTracksWidthChange() throws {
        let group = try XCTUnwrap(store.roots.first { $0.isExpandable })
        window.setContentSize(NSSize(width: 600, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        outline.layoutSubtreeIfNeeded()
        drain(0.2)

        let rowWidth = outline.bounds.width
        let columnX = TranscriptOutlineMetrics.columnX(forRowWidth: rowWidth)
        let chevron = outline.frameOfOutlineCell(atRow: outline.row(forItem: group))
        XCTAssertEqual(
            chevron.origin.x, columnX + BlockStyle.blockHorizontalPadding, accuracy: 0.5,
            "chevron x must re-derive from the narrowed bounds.width")
    }

    /// Full live-resize lifecycle through the real production handlers
    /// (driven by `LiveResizeHarness`: real `inLiveResize`, real
    /// `frameDidChange`, real `viewDidEndLiveResize`). Asserts the two-phase
    /// contract — **during the drag** only the visible rows re-typeset while
    /// an off-screen row keeps its stale layout (bounded per-frame work);
    /// **at end** the off-screen row is refilled at the settled width.
    func testLiveResizeInvalidatesVisibleThenRefillsOffscreen() throws {
        let group = try XCTUnwrap(store.roots.first { $0.isExpandable })
        expandGroupAndTallTool(group)
        outline.scrollRowToVisible(0)
        outline.layoutSubtreeIfNeeded()
        drain(0.1)

        let offscreen = try XCTUnwrap(
            firstOffscreenRoot(),
            "the tall tool body must push a root below the fold for this probe")
        let visibleRoot = try XCTUnwrap(store.roots.first, "para0 sits at the top")
        func widthOf(_ item: TranscriptNodeItem) -> CGFloat {
            TranscriptOutlineMetrics.layoutWidth(
                forRowWidth: outline.bounds.width, level: 0, hasChevronSlot: item.isHeader)
        }
        let wideOffscreen = widthOf(offscreen)
        XCTAssertEqual(
            try XCTUnwrap(store.cachedWidth(for: offscreen.id)), wideOffscreen, accuracy: 0.5)

        let harness = LiveResizeHarness(window: window, view: outline)
        harness.begin()
        harness.step(toContentWidth: 600)

        // Column actually narrowed (1200 → 780 clamp; 600 → 600).
        XCTAssertLessThan(
            TranscriptOutlineMetrics.layoutWidth(
                forRowWidth: outline.bounds.width, level: 0, hasChevronSlot: false),
            wideOffscreen)
        XCTAssertEqual(
            try XCTUnwrap(store.cachedWidth(for: visibleRoot.id)), widthOf(visibleRoot),
            accuracy: 0.5, "visible row must reflow mid-drag")
        XCTAssertEqual(
            try XCTUnwrap(store.cachedWidth(for: offscreen.id)), wideOffscreen, accuracy: 0.5,
            "off-screen row must keep its stale layout mid-drag (visible-only invalidation)")

        harness.end()
        let narrowOffscreen = widthOf(offscreen)
        XCTAssertLessThan(narrowOffscreen, wideOffscreen, "sanity: the off-screen target narrows")
        waitUntil("off-screen row refills after live-resize end") { [self] in
            abs((store.cachedWidth(for: offscreen.id) ?? -1) - narrowOffscreen) < 0.5
        }
    }

    // MARK: - 6. Click-to-toggle on header rows

    /// A click anywhere on a header row (outside the disclosure triangle)
    /// toggles its expansion — the whole tool-group / tool header is a hit
    /// target, driven through the native `expandItem` / `collapseItem`.
    func testClickingHeaderBodyTogglesExpansion() throws {
        let group = try XCTUnwrap(store.roots.first { $0.isExpandable })
        let groupRow = outline.row(forItem: group)
        XCTAssertFalse(outline.isItemExpanded(group), "precondition: collapsed")

        let triangle = outline.frameOfOutlineCell(atRow: groupRow)
        let rowRect = outline.rect(ofRow: groupRow)
        let probe = NSPoint(x: triangle.maxX + 30, y: rowRect.midY)
        XCTAssertFalse(triangle.contains(probe), "probe must be off the triangle")

        clickOutline(atDocPoint: probe)
        waitUntil("header click expands the group") { [self] in
            outline.isItemExpanded(group)
        }

        clickOutline(atDocPoint: probe)
        waitUntil("second header click collapses the group") { [self] in
            !outline.isItemExpanded(group)
        }
    }

    // MARK: - 7. Post-resize refill keeps the visual-top anchor

    /// The end-of-resize refill corrects off-screen rows' heights; when those
    /// rows sit **above** the viewport, that shifts the visible content
    /// unless the visual-top anchor compensates. Needs rows that actually
    /// reflow taller when narrowed — the shared fixture's text is too short,
    /// so this mounts a dedicated long-paragraph outline.
    func testLiveResizeEndKeepsVisualTopPinned() throws {
        let mount = Self.mountOutline(messages: Self.longParagraphFixture())
        addTeardownBlock { @MainActor in mount.window.close() }
        let localOutline = mount.outline
        let localStore = mount.store

        // Scroll to the tail so the early long paragraphs sit above the fold.
        localOutline.scrollRowToVisible(localOutline.numberOfRows - 1)
        localOutline.layoutSubtreeIfNeeded()
        drain(0.1)

        let clip = try XCTUnwrap(localOutline.enclosingScrollView).contentView
        let visBefore = localOutline.rows(in: localOutline.visibleRect)
        XCTAssertGreaterThan(
            visBefore.location, 0, "premise: some rows must sit above the viewport")
        let anchor = try XCTUnwrap(
            localOutline.item(atRow: visBefore.location) as? TranscriptNodeItem)
        let screenYBefore =
            localOutline.rect(ofRow: visBefore.location).minY - clip.bounds.origin.y

        let harness = LiveResizeHarness(window: mount.window, view: localOutline)
        harness.begin()
        harness.step(toContentWidth: 520)  // narrow → long paragraphs wrap taller
        harness.end()

        // Wait for the async refill to correct an above-viewport paragraph.
        let firstRoot = try XCTUnwrap(localStore.roots.first)
        let narrow = TranscriptOutlineMetrics.layoutWidth(
            forRowWidth: localOutline.bounds.width, level: 0, hasChevronSlot: false)
        waitUntil("above-viewport rows refill at end") {
            abs((localStore.cachedWidth(for: firstRoot.id) ?? -1) - narrow) < 0.5
        }
        localOutline.layoutSubtreeIfNeeded()

        let newRow = localOutline.row(forItem: anchor)
        let screenYAfter = localOutline.rect(ofRow: newRow).minY - clip.bounds.origin.y
        XCTAssertEqual(
            screenYAfter, screenYBefore, accuracy: 2.0,
            "the top visible row must stay pinned across the end-of-resize refill")
    }

    // MARK: - Helpers

    /// Mount a throwaway outline VC in its own window from `messages` — used
    /// by tests that need a fixture different from the shared one. The
    /// static `FakeHistory.messages` seam is safe to re-point here because
    /// each `TranscriptStore.load` reads it fresh and the class runs its
    /// methods sequentially in one process.
    private static func mountOutline(
        messages: [Message2]
    ) -> (window: NSWindow, vc: TranscriptViewController, store: TranscriptStore, outline: NSOutlineView) {
        FakeHistory.messages = messages
        let store = TranscriptStore(historySource: FakeHistory.self)
        let vc = TranscriptViewController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 1200, height: 400))
        window.contentView?.layoutSubtreeIfNeeded()
        vc.present(sessionId: "fixture")
        let outline = findOutline(in: vc.view)!
        return (window, vc, store, outline)
    }

    /// Six long wrapping paragraphs — each reflows to a different line count
    /// (and height) at 520 vs 780, so narrowing genuinely grows the rows.
    private static func longParagraphFixture() -> [Message2] {
        let resolver = Message2Resolver()
        func resolve(_ dict: [String: Any]) -> Message2 { try! resolver.resolve(dict) }
        let long = String(
            repeating: "The quick brown fox jumps over the lazy dog. ", count: 8)
        return (0..<6).map { i in
            resolve([
                "type": "assistant", "uuid": UUID().uuidString, "session_id": "s",
                "message": [
                    "id": "m\(i)", "type": "message", "role": "assistant",
                    "content": [["type": "text", "text": long]],
                ],
            ])
        }
    }

    /// Synthesize a single left-click at a document-space point on the
    /// outline and dispatch it through the real `mouseDown` (the same path
    /// a user click takes — the cell forwards non-link clicks here).
    private func clickOutline(atDocPoint docPoint: NSPoint) {
        let windowPoint = outline.convert(docPoint, to: nil)
        guard
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1)
        else {
            XCTFail("failed to synthesize mouse event")
            return
        }
        outline.mouseDown(with: event)
    }

    /// Expand the group and its tall (bash) tool synchronously, so the
    /// document overflows the viewport and some rows land off-screen.
    private func expandGroupAndTallTool(_ group: TranscriptNodeItem) {
        outline.expandItem(group)
        if let tallTool = group.children.last { outline.expandItem(tallTool) }
        outline.layoutSubtreeIfNeeded()
    }

    /// The first root whose row currently sits outside the viewport.
    private func firstOffscreenRoot() -> TranscriptNodeItem? {
        let visible = outline.rows(in: outline.visibleRect)
        let lo = visible.location
        let hi = visible.location + visible.length
        return store.roots.first { root in
            let row = outline.row(forItem: root)
            return row >= 0 && (row < lo || row >= hi)
        }
    }

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

import AppKit
import XCTest
@testable import ccterm

/// User-bubble tests. Two layers, mirroring `ListSelectionTests`:
///
/// - **Layout layer** — `UserBubbleLayout.make` is a pure function of
///   `(text, maxWidth)`. Threshold / chevron / truncation / right-alignment
///   / chevron geometry assert directly on the returned layout's fields
///   without any AppKit harness.
/// - **Coordinator layer** — `requestUserBubbleSheet(id:)` is the chevron's
///   destination. Tests use a window-backed harness to verify a chevron
///   request reaches `Transcript2Controller.pendingUserBubbleSheet` (the
///   SwiftUI `.sheet(item:)` binding's source of truth).
@MainActor
final class UserBubbleTests: XCTestCase {

    private let testWidth: CGFloat = 700

    // MARK: - 1. Threshold + min-hidden guard → chevron presence

    func testNoChevronBelowThreshold() {
        let layout = UserBubbleLayout.make(
            text: text(lines: 10), maxWidth: testWidth)
        XCTAssertNil(layout.chevronHitRect, "10 lines is below threshold")
        XCTAssertNil(layout.chevronCenter, "no chevron geometry without fold")
    }

    func testMinHiddenGuardChevron() {
        let threshold = BlockStyle.userBubbleCollapseThreshold
        let minHidden = BlockStyle.userBubbleMinHiddenLines

        let borderline = UserBubbleLayout.make(
            text: text(lines: threshold + minHidden - 1), maxWidth: testWidth)
        XCTAssertNil(borderline.chevronHitRect,
            "must hide at least `minHiddenLines` rows before folding pays off")

        let overThreshold = UserBubbleLayout.make(
            text: text(lines: threshold + minHidden), maxWidth: testWidth)
        XCTAssertNotNil(overThreshold.chevronHitRect, "fold UI activates")
    }

    // MARK: - 2. Truncation: drawn lines = threshold

    func testFoldedDrawsExactlyThresholdLines() {
        let threshold = BlockStyle.userBubbleCollapseThreshold
        let layout = UserBubbleLayout.make(
            text: text(lines: 25), maxWidth: testWidth)
        XCTAssertEqual(layout.lines.count, threshold,
            "folded bubble draws exactly `threshold` lines (prefix + truncated tail)")
    }

    // MARK: - 3. Width reflow

    func testWidthChangeChangesWrap() {
        let longLines = (0..<20).map { i in
            "line \(i) with enough text to definitely wrap when the column gets narrow"
        }.joined(separator: "\n")
        let wide = UserBubbleLayout.make(text: longLines, maxWidth: testWidth)
        let narrow = UserBubbleLayout.make(text: longLines, maxWidth: testWidth * 0.45)
        // Both fold; both draw `threshold` lines. What changes is the
        // bubble width, not line count — verify total height differs
        // because narrow bubble's lines have shorter widths but identical
        // count (both = threshold).
        XCTAssertEqual(wide.lines.count, narrow.lines.count,
            "both folded → same drawn line count regardless of width")
        XCTAssertGreaterThan(wide.bubbleRect.width, narrow.bubbleRect.width,
            "narrow maxWidth shrinks bubble width")
    }

    // MARK: - 4. Right alignment + left gutter

    func testBubbleHugsRightEdge() {
        let layout = UserBubbleLayout.make(text: "short", maxWidth: testWidth)
        XCTAssertEqual(layout.bubbleRect.maxX, testWidth, accuracy: 0.5,
            "bubble right edge sits flush with maxWidth so the row's only "
            + "right gap is the row-level blockHorizontalPadding")
    }

    func testBubbleRespectsLeftGutter() {
        let veryLong = String(repeating: "x", count: 10_000)
        let layout = UserBubbleLayout.make(text: veryLong, maxWidth: testWidth)
        XCTAssertGreaterThanOrEqual(layout.bubbleRect.minX,
                                    BlockStyle.bubbleMinLeftGutter - 0.5)
    }

    // MARK: - 5. Chevron geometry: corner-anchored, uniform R inset

    func testChevronCorner_uniformInsetFromRightAndBottom() {
        let layout = UserBubbleLayout.make(
            text: text(lines: 25), maxWidth: testWidth)
        guard let center = layout.chevronCenter else { return XCTFail() }
        let r = BlockStyle.bubbleCornerRadius
        XCTAssertEqual(center.x, layout.bubbleRect.maxX - r, accuracy: 0.01,
            "chevron x-center sits one cornerRadius from the bubble's right edge")
        XCTAssertEqual(center.y, layout.bubbleRect.maxY - r, accuracy: 0.01,
            "chevron y-center sits one cornerRadius from the bubble's bottom edge — "
            + "uniform inset, reads as anchored to the corner pivot")
    }

    // MARK: - 6. Selection: drag onto truncated tail returns text

    func testTruncatedTail_dragOntoItYieldsText() {
        // Truncated tail is treated as a regular line — drag onto it
        // selects, and `string()` returns the source slice. May include
        // chars from the hidden suffix; that's accepted by design (sheet
        // is the canonical "see all" path; opportunistic drag-copy on the
        // tail is a shortcut to the same content).
        let layout = UserBubbleLayout.make(
            text: text(lines: 25), maxWidth: testWidth)
        let adapter = layout.selectionAdapter
        guard let lastIdx = layout.lineOrigins.indices.last
        else { return XCTFail() }
        let tailY = layout.textOriginInRow.y + layout.lineOrigins[lastIdx].y
        let start = CGPoint(
            x: layout.textOriginInRow.x + 1,
            y: layout.textOriginInRow.y + 1)
        let endOnTail = CGPoint(
            x: layout.textOriginInRow.x + 12,
            y: tailY)
        let s = adapter.string(adapter.hitTest(start), adapter.hitTest(endOnTail))
        XCTAssertFalse(s.isEmpty, "selection onto truncated tail must yield text")
    }

    // MARK: - 7. Chevron click → coordinator forwards (id, fullText)

    func testChevronRequestForwardsIdAndFullText() {
        let h = makeHarness(text: text(lines: 25))
        var fired: (UUID, String)?
        h.coordinator.onUserBubbleSheetRequested = { id, text in
            fired = (id, text)
        }

        h.coordinator.requestUserBubbleSheet(id: h.blockId)

        guard let (firedId, firedText) = fired
        else { return XCTFail("expected sheet request to fire") }
        XCTAssertEqual(firedId, h.blockId)
        XCTAssertTrue(firedText.hasPrefix("line 0"),
            "sheet payload is the original full text, not the truncated display")
    }

    func testRequestSheet_unknownIdIsNoop() {
        let h = makeHarness(text: "short")
        var fired = false
        h.coordinator.onUserBubbleSheetRequested = { _, _ in fired = true }
        h.coordinator.requestUserBubbleSheet(id: UUID())
        XCTAssertFalse(fired)
    }

    func testRequestSheet_nonUserBubbleIdIsNoop() {
        let para = Block(id: UUID(), kind: .paragraph(inlines: [.text("hi")]))
        let h = makeHarness(block: para)
        var fired = false
        h.coordinator.onUserBubbleSheetRequested = { _, _ in fired = true }
        h.coordinator.requestUserBubbleSheet(id: h.blockId)
        XCTAssertFalse(fired)
    }

    // MARK: - Helpers

    private func text(lines n: Int) -> String {
        (0..<n).map { "line \($0)" }.joined(separator: "\n")
    }

    private func makeHarness(text: String) -> Harness {
        Harness(block: Block(id: UUID(), kind: .userBubble(text: text)))
    }

    private func makeHarness(block: Block) -> Harness {
        Harness(block: block)
    }

    /// Window-backed harness — same shape as `ListSelectionTests.Harness`.
    /// Tests probe the coordinator's `onUserBubbleSheetRequested` closure
    /// directly (the controller's job is to wire that closure to its
    /// `@Observable pendingUserBubbleSheet` field — two lines of init,
    /// not worth a separate harness).
    @MainActor
    final class Harness {
        let window: NSWindow
        let scroll: Transcript2ScrollView
        let tableView: Transcript2TableView
        let coordinator: Transcript2Coordinator
        let block: Block
        var blockId: UUID { block.id }

        init(block: Block, size: NSSize = NSSize(width: 600, height: 400)) {
            self.block = block
            window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .resizable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false

            scroll = Transcript2ScrollView(frame: NSRect(origin: .zero, size: size))
            scroll.hasVerticalScroller = false
            scroll.contentView = Transcript2ClipView()
            scroll.autoresizingMask = [.width, .height]
            window.contentView = scroll

            tableView = Transcript2TableView()
            tableView.headerView = nil
            tableView.style = .plain
            tableView.selectionHighlightStyle = .none
            tableView.intercellSpacing = NSSize(width: 0, height: 0)
            tableView.usesAutomaticRowHeights = false
            tableView.gridStyleMask = []
            tableView.allowsColumnResizing = false
            tableView.allowsColumnReordering = false
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
            column.resizingMask = .autoresizingMask
            column.minWidth = 0
            column.maxWidth = .greatestFiniteMagnitude
            tableView.addTableColumn(column)

            coordinator = Transcript2Coordinator()
            tableView.dataSource = coordinator
            tableView.delegate = coordinator
            coordinator.tableView = tableView
            tableView.coordinator = coordinator
            scroll.documentView = tableView

            coordinator.apply([.insert(after: nil, [block])])

            scroll.frame = NSRect(origin: .zero, size: size)
            scroll.tile()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            tableView.layoutSubtreeIfNeeded()
        }

        deinit {
            Task { @MainActor [window] in window.close() }
        }
    }
}

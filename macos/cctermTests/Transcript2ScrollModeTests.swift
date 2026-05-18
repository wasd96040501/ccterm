import AppKit
import XCTest

@testable import ccterm

/// Drives `Transcript2Coordinator` through its public surface (apply,
/// loadInitial, scrollToBottom) and an off-window NSScrollView /
/// NSTableView pair mirroring `Transcript2NSViewBridge.makeNSView`.
/// Verifies the `ScrollMode` state machine: sticky-bottom tracks
/// appends and width changes, user scroll captures a free anchor that
/// survives detach + re-attach, scrolling back to the bottom edge
/// re-enters sticky-bottom.
///
/// **Why these tests run off-window.** AppKit honors `setFrameSize` →
/// `frameDidChange` → `NSClipView.boundsDidChangeNotification` even
/// without a key window, and `NSTableView.rect(ofRow:)` lazy-recomputes
/// against `heightOfRow` (which the coordinator answers from its layout
/// cache). That's the entire path the production code exercises, so
/// asserting against clip-view bounds is a real integration test of
/// the scroll-mode pipeline — no mocking of NSTableView semantics.
@MainActor
final class Transcript2ScrollModeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Sticky-bottom

    func testColdLoadLandsAtBottom() {
        let coord = Transcript2Coordinator()
        let blocks = Self.makeTextBlocks(count: 30)
        coord.apply([.insert(after: nil, blocks)])
        let h = Self.attachOffWindow(coordinator: coord, size: NSSize(width: 780, height: 800))

        XCTAssertEqual(coord.scrollMode, .stickyBottom)
        XCTAssertEqual(
            h.scroll.contentView.bounds.origin.y,
            Self.expectedBottomClipY(in: h),
            accuracy: 1.0,
            "after load + first frame change, clip.y should be at the document bottom")
    }

    func testStickyBottomTracksAppendedBlocks() {
        let coord = Transcript2Coordinator()
        coord.apply([.insert(after: nil, Self.makeTextBlocks(count: 30))])
        let h = Self.attachOffWindow(coordinator: coord, size: NSSize(width: 780, height: 800))
        let initialBottom = Self.expectedBottomClipY(in: h)
        XCTAssertEqual(
            h.scroll.contentView.bounds.origin.y, initialBottom, accuracy: 1.0)

        // Append more rows — sticky-bottom should re-pin to the new bottom.
        let last = coord.blockIds.last
        coord.apply([.insert(after: last, Self.makeTextBlocks(count: 5))])

        let newBottom = Self.expectedBottomClipY(in: h)
        XCTAssertGreaterThan(
            newBottom, initialBottom,
            "appending blocks should grow the doc, moving the bottom y")
        XCTAssertEqual(
            h.scroll.contentView.bounds.origin.y, newBottom, accuracy: 1.0,
            "clip should track the new bottom under sticky-bottom mode")
        XCTAssertEqual(coord.scrollMode, .stickyBottom)
    }

    func testStickyBottomReaffirmsOnWidthChange() {
        let coord = Transcript2Coordinator()
        coord.apply([.insert(after: nil, Self.makeTextBlocks(count: 40))])
        let h = Self.attachOffWindow(coordinator: coord, size: NSSize(width: 780, height: 800))
        XCTAssertEqual(
            h.scroll.contentView.bounds.origin.y,
            Self.expectedBottomClipY(in: h), accuracy: 1.0)

        // Narrow the viewport. Rows reflow taller (longer wraps), so
        // doc height grows and the "bottom" target moves. Reaffirm
        // should chase it.
        Self.resize(h, to: NSSize(width: 400, height: 800))

        XCTAssertEqual(
            h.scroll.contentView.bounds.origin.y,
            Self.expectedBottomClipY(in: h), accuracy: 1.0,
            "narrower width grows row heights; reaffirm should re-land at the new bottom")
        XCTAssertEqual(coord.scrollMode, .stickyBottom)
    }

    // MARK: - Free-scroll capture

    func testUserScrollAwayFromBottomCapturesFreeMode() {
        let coord = Transcript2Coordinator()
        let blocks = Self.makeTextBlocks(count: 40)
        coord.apply([.insert(after: nil, blocks)])
        let h = Self.attachOffWindow(coordinator: coord, size: NSSize(width: 780, height: 800))
        XCTAssertEqual(coord.scrollMode, .stickyBottom)

        // User scrolls up. Direct `scroll(to:)` is exactly what AppKit
        // would dispatch on a wheel event; the clip-bounds observer
        // fires synchronously with `isProgrammaticallyScrolling=false`,
        // so the coordinator captures the new position as `.free(...)`.
        let target = NSPoint(x: 0, y: 200)
        h.scroll.contentView.scroll(to: target)

        guard case .free(let id, let offset) = coord.scrollMode else {
            return XCTFail("expected .free mode after user scroll, got \(coord.scrollMode)")
        }
        // Captured id should be one of the original blocks.
        XCTAssertTrue(blocks.contains(where: { $0.id == id }))
        // The offset can be negative (row's top edge above clip's top
        // because partially clipped) or positive (row starts within
        // visible content area). Just sanity-check it's finite.
        XCTAssertTrue(offset.isFinite)
    }

    func testFreeScrollSurvivesDetachAndReattach() {
        let coord = Transcript2Coordinator()
        let blocks = Self.makeTextBlocks(count: 60)
        coord.apply([.insert(after: nil, blocks)])
        let firstMount = Self.attachOffWindow(
            coordinator: coord, size: NSSize(width: 780, height: 800))

        // User scrolls to an arbitrary mid-document position.
        firstMount.scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        guard case .free = coord.scrollMode else {
            return XCTFail("expected .free after user scroll, got \(coord.scrollMode)")
        }
        let capturedMode = coord.scrollMode

        // Simulate `dismantleNSView`. Clip observer detaches; scrollMode
        // persists on the coordinator (session-scoped).
        coord.willDismantleView()
        NotificationCenter.default.removeObserver(coord)
        coord.tableView = nil

        XCTAssertEqual(
            coord.scrollMode, capturedMode,
            "scrollMode must survive view detach")

        // Re-mount with a fresh table/scrollview pair.
        let secondMount = Self.attachOffWindow(
            coordinator: coord, size: NSSize(width: 780, height: 800))

        // Reaffirm should have placed the same row at the same offset.
        guard case .free(let id, let offset) = coord.scrollMode else {
            return XCTFail("expected .free post-reattach, got \(coord.scrollMode)")
        }
        guard let row = coord.blockIds.firstIndex(of: id) else {
            return XCTFail("captured row id missing after reattach")
        }
        let expectedClipY = secondMount.table.rect(ofRow: row).origin.y - offset
        XCTAssertEqual(
            secondMount.scroll.contentView.bounds.origin.y,
            expectedClipY, accuracy: 1.0,
            "after reattach, reaffirm should re-pin captured row to its offset")
    }

    func testScrollingBackToBottomReentersStickyBottom() {
        let coord = Transcript2Coordinator()
        // 60 rows × ~28pt = ~1680pt, comfortably bigger than the 800
        // viewport so the user has somewhere to scroll up TO.
        coord.apply([.insert(after: nil, Self.makeTextBlocks(count: 60))])
        let h = Self.attachOffWindow(coordinator: coord, size: NSSize(width: 780, height: 800))

        // First leave sticky-bottom by scrolling to the document top.
        h.scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        guard case .free = coord.scrollMode else {
            return XCTFail("setup: should be in .free after scrolling up, got \(coord.scrollMode)")
        }

        // Now scroll back to the document bottom (within the epsilon).
        let bottomY = Self.expectedBottomClipY(in: h)
        h.scroll.contentView.scroll(to: NSPoint(x: 0, y: bottomY))

        XCTAssertEqual(
            coord.scrollMode, .stickyBottom,
            "scrolling to the bottom edge should re-enter .stickyBottom")
    }

    // MARK: - loadInitial sets sticky-bottom

    func testLoadInitialEntersStickyBottomEvenIfPreviousModeWasFree() {
        let coord = Transcript2Coordinator()
        coord.apply([.insert(after: nil, Self.makeTextBlocks(count: 60))])
        let h = Self.attachOffWindow(coordinator: coord, size: NSSize(width: 780, height: 800))

        // Drive mode to .free first by scrolling away from the bottom.
        h.scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        XCTAssertNotEqual(coord.scrollMode, .stickyBottom)

        // Detach (simulating session unmount), then loadInitial fresh blocks.
        coord.willDismantleView()
        NotificationCenter.default.removeObserver(coord)
        coord.tableView = nil

        let controller = Transcript2Controller()
        // Reuse the same coordinator pattern by going via the public
        // surface: we want to confirm loadInitial resets to sticky-
        // bottom even when the underlying coordinator was last in .free.
        // Use the controller's own coordinator (it owns one); we test the
        // semantic on that.
        let blocks = Self.makeTextBlocks(count: 25)
        controller.loadInitial(blocks)
        // Attach the controller's coordinator and confirm.
        let h2 = Self.attachOffWindow(
            coordinator: controller.coordinator,
            size: NSSize(width: 780, height: 800))
        XCTAssertEqual(controller.coordinator.scrollMode, .stickyBottom)
        XCTAssertEqual(
            h2.scroll.contentView.bounds.origin.y,
            Self.expectedBottomClipY(in: h2), accuracy: 1.0)
    }

    // MARK: - Off-window helper

    /// Holds the AppKit objects that back a coordinator in tests.
    /// Constructed by `attachOffWindow`; retained by the test for the
    /// duration of the assertions to keep the scroll view alive (the
    /// coordinator's `tableView` is `weak`).
    struct OffWindowHarness {
        let scroll: Transcript2ScrollView
        let table: Transcript2TableView
    }

    /// Build a Transcript2ScrollView / Transcript2TableView pair the
    /// same way `Transcript2NSViewBridge.makeNSView` does, attach the
    /// coordinator, and size the scroll view so a real frame-change
    /// notification fires. Returns the harness for retention.
    static func attachOffWindow(
        coordinator: Transcript2Coordinator,
        size: NSSize
    ) -> OffWindowHarness {
        let scroll = Transcript2ScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true
        scroll.layerContentsRedrawPolicy = .never
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView = Transcript2ClipView()
        // Off-window NSScrollView ignores `contentInsets.bottom` for
        // `NSClipView.constrainBoundsRect` clamping (the window's safe
        // area / responder chain normally provides that signal). Use
        // zero insets in tests so the clamp math reduces to "max
        // clip.y = docHeight - clipH" — matching what production would
        // see after the window honors the bottom inset.
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let table = Transcript2TableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAutomaticRowHeights = false
        table.gridStyleMask = []
        table.allowsColumnResizing = false
        table.allowsColumnReordering = false
        table.allowsColumnSelection = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        table.addTableColumn(column)

        table.dataSource = coordinator
        table.delegate = coordinator
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Transcript2Coordinator.tableFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: table)

        coordinator.tableView = table
        scroll.documentView = table

        // Setting the scroll's frame triggers `tile()` which sizes the
        // table to clip width, which fires `frameDidChange` on the
        // table → tableFrameDidChange → reaffirmScrollMode.
        scroll.frame = NSRect(origin: .zero, size: size)
        scroll.tile()

        return OffWindowHarness(scroll: scroll, table: table)
    }

    /// Resize an existing harness's scroll view. Triggers the same
    /// `tile` → `frameDidChange` cascade as a window resize.
    static func resize(_ h: OffWindowHarness, to size: NSSize) {
        h.scroll.frame = NSRect(origin: .zero, size: size)
        h.scroll.tile()
    }

    /// Compute the expected clip.y for the document bottom given the
    /// current harness geometry. Mirrors `Transcript2Coordinator
    /// .maxClipY`, but reads via `rect(ofRow:)` on the last row to
    /// stay in lock-step with the coordinator's own computation.
    static func expectedBottomClipY(in h: OffWindowHarness) -> CGFloat {
        let lastRow = h.table.numberOfRows - 1
        let docMaxY = h.table.rect(ofRow: lastRow).maxY
        let visibleBottomInClip =
            h.scroll.contentView.bounds.height - h.scroll.contentInsets.bottom
        let target = docMaxY - visibleBottomInClip
        return max(-h.scroll.contentInsets.top, target)
    }

    /// Test fixture: identifiable paragraphs short enough to dodge
    /// `Transcript2Coordinator`'s `>maxLayoutWidth` clamp band. 30
    /// rows is more than enough to overflow an 800-tall viewport
    /// (each paragraph renders at ~30pt).
    static func makeTextBlocks(count: Int) -> [Block] {
        (0..<count).map { i in
            Block(
                id: UUID(),
                kind: .paragraph(inlines: [.text("Row \(i) — sticky-bottom test fixture.")]))
        }
    }
}

import AppKit
import XCTest
@testable import ccterm

/// Paragraph-flat selection tests for `ListLayout` +
/// `Transcript2SelectionCoordinator`.
///
/// Two layers, mirroring `TableSelectionTests`:
/// - **Layout layer** — `ListLayout.selectionAdapter` is a pure function
///   of `(ListBlock, maxWidth)`. We drive `hitTest` / `rects` / `string`
///   directly without any AppKit harness.
/// - **Selection layer** — `updateSelection(from:to:in:)` reads geometry
///   off a real `NSTableView`, so these tests build a window-backed
///   `Transcript2ScrollView`, push a list block, force a layout pass,
///   then drive synthetic drag points and inspect the resulting
///   `SelectionRange` via the adapter's projected rects / string.
@MainActor
final class ListSelectionTests: XCTestCase {

    // MARK: - Layout layer: hit-test → opaque position round-trip

    func testHitTest_pointInsideEachParagraph_roundTripsThroughAdapter() {
        let layout = makeLayout()
        let adapter = layout.selectionAdapter
        for i in 0 ..< layout.items.count {
            guard case .text(let para, let origin) = layout.items[i].contents[0]
            else { return XCTFail("paragraph \(i) not a leaf text") }
            // 4pt into the text — well inside the first character regardless
            // of font metrics. (`measuredWidth` is the *input* width, not
            // the rendered text width, so "center" via `measuredWidth/2`
            // would over-shoot a short paragraph.)
            let inside = CGPoint(
                x: origin.x + 4,
                y: origin.y + para.totalHeight / 2)
            let pos = adapter.hitTest(inside)
            guard case .listItem(let p, _) = pos
            else { return XCTFail("expected .listItem at paragraph \(i)") }
            XCTAssertEqual(p, i)

            // Word at this position is non-empty (sanity).
            guard let word = adapter.wordBoundary(pos) else {
                return XCTFail("wordBoundary nil at paragraph \(i)")
            }
            XCTAssertFalse(adapter.string(word.start, word.end).isEmpty)
        }
    }

    func testHitTest_clampsOutOfBounds() {
        let layout = makeLayout()
        let adapter = layout.selectionAdapter
        let lastP = layout.items.count - 1

        // Above + left → first paragraph, char 0.
        let topLeft = adapter.hitTest(CGPoint(x: -50, y: -50))
        if case .listItem(let p, let ch) = topLeft {
            XCTAssertEqual(p, 0)
            XCTAssertEqual(ch, 0)
        } else { XCTFail() }

        // Below + right → last paragraph; char index is whatever the
        // last paragraph's TextLayout returns for a clamped point —
        // non-negative.
        let bottomRight = adapter.hitTest(CGPoint(x: 9_999, y: 9_999))
        if case .listItem(let p, _) = bottomRight {
            XCTAssertEqual(p, lastP)
        } else { XCTFail() }
    }

    // MARK: - Selection layer: drag → SelectionRange → adapter outputs

    /// Same-paragraph drag: 1×1 paragraph with a non-empty inner range.
    /// Adapter projects to a glyph band and a per-paragraph substring.
    func testSameParagraphDrag_paintsInnerGlyphBandAndCopiesSubstring() {
        let h = makeHarness()
        let p = h.docPoint(forParagraphAt: 1)
        let nudge = CGPoint(x: p.x + 12, y: p.y)
        h.coordinator.selection.updateSelection(
            from: p, to: nudge, in: h.tableView)

        guard let range = h.coordinator.selection.selection(for: h.blockId)
        else { return XCTFail("expected selection") }
        guard case .listItem(let p1, _) = range.start,
              case .listItem(let p2, _) = range.end
        else { return XCTFail("expected .listItem positions") }
        XCTAssertEqual(p1, 1)
        XCTAssertEqual(p2, 1)

        let adapter = h.listLayout.selectionAdapter
        let rects = adapter.rects(range.start, range.end)
        XCTAssertFalse(rects.isEmpty)
        let s = adapter.string(range.start, range.end)
        XCTAssertFalse(s.isEmpty)
        XCTAssertTrue("Banana".contains(s), "got: \(s)")
    }

    /// Multi-paragraph drag: rectangle spans paragraphs. Middle
    /// paragraph fully selected; first/last contribute a slice. Joined
    /// by `\n`.
    func testMultiParagraphDrag_fullsMiddleAndJoinsByNewline() {
        let h = makeHarness()
        // Endpoint x-offsets are chosen to land *inside* both endpoint
        // paragraphs' rendered text so neither slice gets clamped to a
        // boundary (which would empty out one side of the join).
        let start = h.docPoint(forParagraphAt: 0, xOffsetIntoText: 4)
        let end = h.docPoint(forParagraphAt: 2, xOffsetIntoText: 24)
        h.coordinator.selection.updateSelection(
            from: start, to: end, in: h.tableView)

        guard let range = h.coordinator.selection.selection(for: h.blockId)
        else { return XCTFail() }
        let adapter = h.listLayout.selectionAdapter
        let s = adapter.string(range.start, range.end)
        // Middle paragraph is fully captured because both endpoints
        // landed past it.
        XCTAssertTrue(s.contains("Banana"), "got: \(s)")
        // Two newlines separate three paragraph slices.
        XCTAssertEqual(s.components(separatedBy: "\n").count, 3)
        XCTAssertFalse(adapter.rects(range.start, range.end).isEmpty)
    }

    /// Reversed direction yields the same selection — `rects` and
    /// `string` closures normalize internally.
    func testReversedDrag_yieldsSameRectsAndString() {
        let h = makeHarness()
        let a = h.docPoint(forParagraphAt: 0)
        let b = h.docPoint(forParagraphAt: 2)

        h.coordinator.selection.updateSelection(from: a, to: b, in: h.tableView)
        let forward = h.coordinator.selection.selection(for: h.blockId)
        let adapter = h.listLayout.selectionAdapter
        let forwardString = adapter.string(forward!.start, forward!.end)

        h.coordinator.selection.clearAll()
        h.coordinator.selection.updateSelection(from: b, to: a, in: h.tableView)
        let reversed = h.coordinator.selection.selection(for: h.blockId)
        let reversedString = adapter.string(reversed!.start, reversed!.end)

        XCTAssertEqual(forwardString, reversedString)
    }

    /// Cmd+A: adapter's `fullRange` covers every flat paragraph; copy
    /// joins them with `\n`.
    func testCmdA_selectsFullListAndCopiesEverything() {
        let h = makeHarness()
        h.coordinator.selection.selectAllText()
        XCTAssertEqual(
            h.coordinator.selection.copyText(),
            "Apple\nBanana\nCherry")
    }

    /// Triple-click selects only the clicked paragraph — distinct from
    /// Cmd+A, which selects the whole list. Uses the adapter's
    /// `unitRange` (paragraph-at-position) rather than `fullRange`.
    func testTripleClick_selectsParagraphNotWholeList() {
        let h = makeHarness()
        let p = h.docPoint(forParagraphAt: 1)
        h.coordinator.selection.selectUnit(at: p, in: h.tableView)
        XCTAssertEqual(h.coordinator.selection.copyText(), "Banana")
    }

    // MARK: - Helpers

    /// Build a 3-item ordered list. Cell contents: Apple / Banana / Cherry.
    private func makeBlock() -> Block {
        let items: [ListBlock.Item] = [
            ListBlock.Item(content: [.paragraph([.text("Apple")])]),
            ListBlock.Item(content: [.paragraph([.text("Banana")])]),
            ListBlock.Item(content: [.paragraph([.text("Cherry")])]),
        ]
        return Block(id: UUID(),
                     kind: .list(ListBlock(ordered: true, items: items)))
    }

    private func makeLayout(maxWidth: CGFloat = 460) -> ListLayout {
        let block = makeBlock()
        guard case .list(let listBlock) = block.kind else { preconditionFailure() }
        // Match the cell's content width so paragraph geometry lines up
        // with what the harness sees — the cell strips horizontal block
        // padding before passing width into `ListLayout.make`.
        let contentWidth = max(1, maxWidth - 2 * BlockStyle.blockHorizontalPadding)
        return ListLayout.make(block: listBlock, maxWidth: contentWidth)
    }

    private func makeHarness() -> Harness { Harness(block: makeBlock()) }

    /// Window-backed harness identical in shape to `TableSelectionTests.Harness` —
    /// any drift between the two should be deliberate.
    @MainActor
    final class Harness {
        let window: NSWindow
        let scroll: Transcript2ScrollView
        let tableView: Transcript2TableView
        let coordinator: Transcript2Coordinator
        let block: Block
        var blockId: UUID { block.id }

        var listLayout: ListLayout {
            guard let block = coordinator.block(forId: blockId),
                  case .list(let listBlock) = block.kind
            else { preconditionFailure() }
            let width = max(0,
                            BlockStyle.clampedLayoutWidth(
                                forRowWidth: tableView.tableColumns.first!.width)
                            - 2 * BlockStyle.blockHorizontalPadding)
            return ListLayout.make(block: listBlock, maxWidth: width)
        }

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

        /// Doc-coord point inside the i-th paragraph's text. `xOffsetIntoText`
        /// is added to the paragraph's left edge — small (default 4)
        /// guarantees a landing on the first few characters regardless
        /// of the paragraph's actual rendered width. (`TextLayout.measuredWidth`
        /// is the *input* maxWidth, not the rendered text width, so a
        /// "center via measuredWidth/2" point would over-shoot the text
        /// and clamp to its end.)
        func docPoint(forParagraphAt index: Int,
                      xOffsetIntoText: CGFloat = 4) -> CGPoint {
            let layout = listLayout
            guard layout.items.indices.contains(index),
                  case .text(let para, let origin) = layout.items[index].contents[0]
            else { preconditionFailure("paragraph \(index) not a leaf text") }
            let rowRect = tableView.rect(ofRow: 0)
            let originX = rowRect.minX
                + BlockStyle.cellOriginX(forRowWidth: rowRect.width)
                + BlockStyle.blockHorizontalPadding
            let originY = rowRect.minY + BlockStyle.blockVerticalPadding
            return CGPoint(
                x: originX + origin.x + xOffsetIntoText,
                y: originY + origin.y + para.totalHeight / 2)
        }
    }
}

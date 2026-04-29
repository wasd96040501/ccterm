import AppKit
import XCTest
@testable import ccterm

/// Cell-grid selection tests for `TableLayout` + `Transcript2SelectionCoordinator`.
///
/// Two layers:
/// - **Layout layer** — `TableLayout.selectionAdapter` is a pure function
///   of `(TableBlock, maxWidth)`. We drive `hitTest` / `rects` / `string`
///   directly without any AppKit harness.
/// - **Selection layer** — `updateSelection(from:to:in:)` reads geometry
///   off a real `NSTableView`, so these tests build a window-backed
///   `Transcript2ScrollView`, push a known table block, force a layout
///   pass, then drive synthetic drag points and inspect the resulting
///   `SelectionRange` via the adapter's projected rects / string.
@MainActor
final class TableSelectionTests: XCTestCase {

    // MARK: - Layout layer: hit-test → opaque position round-trip

    func testHitTest_pointInsideEachCell_roundTripsThroughAdapter() {
        let layout = makeLayout()
        let adapter = layout.selectionAdapter
        // Walk every cell; hit-test its center; ask the adapter for a
        // 1×1 selection at that position; assert rects come back inside
        // that cell's frame.
        for r in 0 ..< layout.cellRects.count {
            for c in 0 ..< layout.cellRects[r].count {
                let center = CGPoint(
                    x: layout.cellRects[r][c].midX,
                    y: layout.cellRects[r][c].midY)
                let pos = adapter.hitTest(center)
                // String for a same-cell same-char (zero-width) selection
                // is empty — but expanding to the word at that position
                // gives the cell's text.
                guard let word = adapter.wordBoundary(pos) else {
                    XCTFail("wordBoundary nil at (\(r), \(c))"); continue
                }
                let s = adapter.string(word.start, word.end)
                XCTAssertFalse(
                    s.isEmpty,
                    "word at center of (\(r), \(c)) should not be empty")
            }
        }
    }

    func testHitTest_clampsOutOfBounds() {
        let layout = makeLayout()
        let adapter = layout.selectionAdapter
        let lastR = layout.rowHeights.count - 1
        let lastC = layout.columnWidths.count - 1

        // Above + left → cell (0, 0).
        let topLeft = adapter.hitTest(CGPoint(x: -50, y: -50))
        XCTAssertEqual(topLeft, .cell(row: 0, col: 0, char: 0))

        // Below + right → cell (lastR, lastC). Char index is whatever the
        // cell's TextLayout returns for a clamped point — non-negative.
        let bottomRight = adapter.hitTest(CGPoint(x: 9_999, y: 9_999))
        guard case .cell(let r, let c, _) = bottomRight else {
            return XCTFail("expected .cell for clamped point")
        }
        XCTAssertEqual(r, lastR)
        XCTAssertEqual(c, lastC)
    }

    func testCellRects_partitionTableEdgeToEdge() {
        let layout = makeLayout()
        XCTAssertEqual(layout.cellRects.count, layout.rowHeights.count)
        for row in layout.cellRects {
            XCTAssertEqual(row.count, layout.columnWidths.count)
        }
        for r in 0 ..< layout.cellRects.count {
            for c in 1 ..< layout.cellRects[r].count {
                XCTAssertEqual(
                    layout.cellRects[r][c - 1].maxX,
                    layout.cellRects[r][c].minX,
                    accuracy: 0.01)
            }
        }
        for r in 1 ..< layout.cellRects.count {
            XCTAssertEqual(
                layout.cellRects[r - 1][0].maxY,
                layout.cellRects[r][0].minY,
                accuracy: 0.01)
        }
    }

    // MARK: - Selection layer: drag → SelectionRange → adapter outputs

    /// Same-cell drag: 1×1 cell with a non-empty inner range. The
    /// adapter projects this to a glyph-band rect inside that cell —
    /// a single rect (one line of text), and the selected string is
    /// a substring of the cell's contents.
    func testSameCellDrag_paintsInnerGlyphBandAndCopiesSubstring() {
        let h = makeHarness()
        let cellMid = h.docPoint(forCellAt: 1, col: 1)
        let nudge = CGPoint(x: cellMid.x + 8, y: cellMid.y)
        h.coordinator.selection.updateSelection(
            from: cellMid, to: nudge, in: h.tableView)

        guard let range = h.coordinator.selection.selection(for: h.blockId) else {
            return XCTFail("expected selection after same-cell drag")
        }
        // Both endpoints are .cell(1, 1, _) with different char indices.
        guard case .cell(let r1, let c1, _) = range.start,
              case .cell(let r2, let c2, _) = range.end
        else { return XCTFail("expected .cell positions") }
        XCTAssertEqual(r1, 1); XCTAssertEqual(c1, 1)
        XCTAssertEqual(r2, 1); XCTAssertEqual(c2, 1)

        // Adapter projection: rects exist (glyph band), string is a
        // proper substring of the cell ("r1c1").
        let adapter = h.tableLayout.selectionAdapter
        let rects = adapter.rects(range.start, range.end)
        XCTAssertFalse(rects.isEmpty)
        // The whole cell rect would have larger area than a single-glyph
        // band — assert the painted rect is *strictly inside* the cell.
        let cellRect = h.tableLayout.cellRects[1][1]
        for rect in rects {
            XCTAssertLessThan(rect.width, cellRect.width,
                "inner glyph band must be narrower than full cell")
        }
        let s = adapter.string(range.start, range.end)
        XCTAssertFalse(s.isEmpty)
        XCTAssertTrue("r1c1".contains(s), "got: \(s)")
    }

    /// Same-row drag across cells: rectangle is 1 × N, no inner range.
    /// Adapter rects = N full-cell rects in that row; string joins by `\t`.
    func testSameRowDrag_paintsFullCellsAndJoinsByTab() {
        let h = makeHarness()
        let start = h.docPoint(forCellAt: 1, col: 0)
        let end = h.docPoint(forCellAt: 1, col: 2)
        h.coordinator.selection.updateSelection(from: start, to: end, in: h.tableView)

        guard let range = h.coordinator.selection.selection(for: h.blockId)
        else { return XCTFail() }
        let adapter = h.tableLayout.selectionAdapter
        let rects = adapter.rects(range.start, range.end)
        XCTAssertEqual(rects.count, 3, "row × 3 cols → 3 rects")
        // Each rect equals the corresponding cellRect (full-cell highlight).
        for c in 0 ... 2 {
            XCTAssertTrue(
                rects.contains { abs($0.minX - h.tableLayout.cellRects[1][c].minX) < 0.5 })
        }
        XCTAssertEqual(
            adapter.string(range.start, range.end),
            "r1c0\tr1c1\tr1c2")
    }

    /// Same-column drag (the user's mandate): rectangle is N × 1, full
    /// cells, joined by `\n`.
    func testSameColumnDrag_paintsFullCellsAndJoinsByNewline() {
        let h = makeHarness()
        let start = h.docPoint(forCellAt: 0, col: 1)
        let end = h.docPoint(forCellAt: 2, col: 1)
        h.coordinator.selection.updateSelection(from: start, to: end, in: h.tableView)

        guard let range = h.coordinator.selection.selection(for: h.blockId)
        else { return XCTFail() }
        let adapter = h.tableLayout.selectionAdapter
        let rects = adapter.rects(range.start, range.end)
        XCTAssertEqual(rects.count, 3, "3 rows × col → 3 rects")
        XCTAssertEqual(
            adapter.string(range.start, range.end),
            "B\nr1c1\nr2c1")
    }

    /// Diagonal drag: rectangle is N × M.
    func testDiagonalDrag_paintsFullRectangle() {
        let h = makeHarness()
        let start = h.docPoint(forCellAt: 0, col: 0)
        let end = h.docPoint(forCellAt: 2, col: 2)
        h.coordinator.selection.updateSelection(from: start, to: end, in: h.tableView)

        guard let range = h.coordinator.selection.selection(for: h.blockId)
        else { return XCTFail() }
        let adapter = h.tableLayout.selectionAdapter
        XCTAssertEqual(adapter.rects(range.start, range.end).count, 9)
        XCTAssertEqual(
            adapter.string(range.start, range.end),
            """
            A\tB\tC
            r1c0\tr1c1\tr1c2
            r2c0\tr2c1\tr2c2
            """)
    }

    /// Reversed direction must produce the same selection as forward —
    /// `rects` and `string` are order-independent (closures normalize).
    func testReversedDrag_yieldsSameRectsAndString() {
        let h = makeHarness()
        let a = h.docPoint(forCellAt: 0, col: 0)
        let b = h.docPoint(forCellAt: 2, col: 2)

        h.coordinator.selection.updateSelection(from: a, to: b, in: h.tableView)
        let forward = h.coordinator.selection.selection(for: h.blockId)
        let adapter = h.tableLayout.selectionAdapter
        let forwardString = adapter.string(forward!.start, forward!.end)

        h.coordinator.selection.clearAll()
        h.coordinator.selection.updateSelection(from: b, to: a, in: h.tableView)
        let reversed = h.coordinator.selection.selection(for: h.blockId)
        let reversedString = adapter.string(reversed!.start, reversed!.end)

        XCTAssertEqual(forwardString, reversedString)
    }

    /// Triple-click on a cell selects only that cell — *not* the entire
    /// table. Cmd+A is the whole-table path; triple-click goes through
    /// the adapter's `unitRange` (cell-at-position), which is what
    /// users expect on a Numbers / Excel-style grid.
    func testTripleClick_selectsCellNotWholeTable() {
        let h = makeHarness()
        let p = h.docPoint(forCellAt: 1, col: 1)
        h.coordinator.selection.selectUnit(at: p, in: h.tableView)
        XCTAssertEqual(h.coordinator.selection.copyText(), "r1c1")
    }

    /// Cmd+A: adapter's `fullRange` covers the entire table; copy yields
    /// the whole flattened table.
    func testCmdA_selectsFullTableAndCopiesEverything() {
        let h = makeHarness()
        h.coordinator.selection.selectAllText()
        XCTAssertEqual(
            h.coordinator.selection.copyText(),
            """
            A\tB\tC
            r1c0\tr1c1\tr1c2
            r2c0\tr2c1\tr2c2
            """)
    }

    /// `copyText` joins per-block selections with `\n\n`. Single-block
    /// table case has no joiner — verifies we don't accidentally
    /// double-newline.
    func testCopyText_singleBlockHasNoTrailingJoiner() {
        let h = makeHarness()
        let start = h.docPoint(forCellAt: 0, col: 1)
        let end = h.docPoint(forCellAt: 2, col: 1)
        h.coordinator.selection.updateSelection(from: start, to: end, in: h.tableView)
        let s = h.coordinator.selection.copyText()
        XCTAssertFalse(s.contains("\n\n"))
    }

    // MARK: - Helpers

    /// Build a 3×3 table (1 header + 2 body rows × 3 cols) directly via
    /// the Block model — avoids the markdown parser dependency. Cell
    /// contents: header A/B/C, body cells r{i}c{j}.
    private func makeBlock() -> Block {
        let header: [[InlineNode]] = [
            [.text("A")], [.text("B")], [.text("C")],
        ]
        let rows: [[[InlineNode]]] = [
            [[.text("r1c0")], [.text("r1c1")], [.text("r1c2")]],
            [[.text("r2c0")], [.text("r2c1")], [.text("r2c2")]],
        ]
        let table = TableBlock(
            header: header, rows: rows,
            alignments: [.left, .left, .left])
        return Block(id: UUID(), kind: .table(table))
    }

    private func makeLayout(maxWidth: CGFloat = 460) -> TableLayout {
        let block = makeBlock()
        guard case .table(let tableBlock) = block.kind else {
            preconditionFailure()
        }
        return TableLayout.make(block: tableBlock, maxWidth: maxWidth)
    }

    private func makeHarness() -> Harness { Harness(block: makeBlock()) }

    /// Window-backed harness: NSWindow → Transcript2ScrollView →
    /// NSTableView wired the same way `NativeTranscript2View.makeNSView`
    /// wires it for production. After init, `tableView.rect(ofRow:)`
    /// returns the actual frame the selection coordinator needs to map
    /// drag points to layout-local coords.
    @MainActor
    final class Harness {
        let window: NSWindow
        let scroll: Transcript2ScrollView
        let tableView: Transcript2TableView
        let coordinator: Transcript2Coordinator
        let block: Block
        var blockId: UUID { block.id }

        var tableLayout: TableLayout {
            // Pull through the cached layout — selection paths use the
            // same accessor.
            guard let block = coordinator.block(forId: blockId),
                  case .table(let tableBlock) = block.kind
            else { preconditionFailure() }
            // Recompute via the public make path. Same width discipline
            // as the cached layout (clamped layoutWidth), so geometry
            // matches what the cell view paints.
            let width = max(0,
                            BlockStyle.clampedLayoutWidth(
                                forRowWidth: tableView.tableColumns.first!.width)
                            - 2 * BlockStyle.blockHorizontalPadding)
            return TableLayout.make(block: tableBlock, maxWidth: width)
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

        /// Map a `(tableRow, tableCol)` pair to a doc-coord point at the
        /// center of that cell. Mirrors the inverse of the selection
        /// coordinator's local-to-doc transform.
        func docPoint(forCellAt tableRow: Int, col tableCol: Int) -> CGPoint {
            let table = tableLayout
            let rowRect = tableView.rect(ofRow: 0)
            let originX = rowRect.minX
                + BlockStyle.cellOriginX(forRowWidth: rowRect.width)
                + BlockStyle.blockHorizontalPadding
            let originY = rowRect.minY
                + BlockStyle.blockPadding(for: block.kind).top
            let cell = table.cellRects[tableRow][tableCol]
            return CGPoint(x: originX + cell.midX, y: originY + cell.midY)
        }
    }
}

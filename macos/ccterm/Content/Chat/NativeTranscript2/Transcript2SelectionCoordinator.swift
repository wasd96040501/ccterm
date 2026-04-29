import AppKit

/// Cross-row selection state for the transcript table.
///
/// Owned by `Transcript2Coordinator`. Reads back per-row data through the
/// weak `transcript` reference (`block(atRow:)`,
/// `selectionAdapter(atRow:)`, `selectionAdapter(forBlockId:)`) and asks
/// the coordinator to repaint affected cells via
/// `markCellNeedsDisplay(blockId:)`.
///
/// ### Source of truth
///
/// `selections: [UUID: SelectionRange]` is the source of truth, keyed by
/// `Block.id`. Per-cell state is derived — when a cell is reused for a
/// previously-selected block on scroll-in, `viewFor` reads the entry out
/// of this dict and applies it to the cell. Holding a weak ref to the
/// cell would break under NSTableView view recycling.
///
/// ### Layout-agnostic algorithm
///
/// The drag-tick algorithm works in opaque `LayoutPosition` values
/// produced and consumed by each row's `SelectionAdapter`. Text rows
/// use 1-D char positions; table rows use 2-D `(row, col, char)`
/// positions; the coordinator never `switch`es on the case. Per-row
/// behavior (paragraph char-flow / table cell-grid / future kinds) is
/// fully encapsulated inside the adapter — this file has zero
/// kind-specific code.
///
/// ### Multi-row drag
///
/// Top / middle / bottom row math is the classic chat-style sweep:
///
/// - **single-row drag** (start and end in the same row) — both endpoints
///   from `adapter.hitTest`.
/// - **top of multi-row drag** — anchor from the click point, cursor at
///   `adapter.fullRange.end` (selection runs from the click to the row
///   edge; reverse drag mirrors).
/// - **bottom of multi-row drag** — anchor at `adapter.fullRange.start`,
///   cursor from the click.
/// - **middle row** — full row (`adapter.fullRange`).
///
/// Rows whose `selectionAdapter` is `nil` (image, list) drop out
/// silently — they're skipped in the sweep without breaking the
/// surrounding selection.
///
/// ### Window-key tracking
///
/// `selectedTextBackgroundColor` (key) vs
/// `unemphasizedSelectedTextBackgroundColor` (resigned) — the cell reads
/// `window?.isKeyWindow` at draw time, so we just need to mark affected
/// cells dirty when key state flips.
@MainActor
final class Transcript2SelectionCoordinator: NSObject {
    weak var transcript: Transcript2Coordinator?

    private var selections: [UUID: SelectionRange] = [:]

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowKeyChanged(_:)),
                       name: NSWindow.didBecomeKeyNotification, object: nil)
        nc.addObserver(self, selector: #selector(windowKeyChanged(_:)),
                       name: NSWindow.didResignKeyNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Read

    var isEmpty: Bool { selections.isEmpty }

    func selection(for blockId: UUID) -> SelectionRange? { selections[blockId] }

    // MARK: - Mutation

    func clearAll() {
        guard !selections.isEmpty else { return }
        let ids = Array(selections.keys)
        selections.removeAll()
        for id in ids { transcript?.markCellNeedsDisplay(blockId: id) }
    }

    /// Replace selection for one block. Empty range (start == end) clears.
    func setSelection(_ range: SelectionRange, blockId: UUID) {
        if range.start == range.end {
            if selections.removeValue(forKey: blockId) != nil {
                transcript?.markCellNeedsDisplay(blockId: blockId)
            }
        } else if selections[blockId] != range {
            selections[blockId] = range
            transcript?.markCellNeedsDisplay(blockId: blockId)
        }
    }

    /// Drop the entry for a block whose row was removed or whose content
    /// was replaced (`.update`). No cell push — the caller (`apply`) is
    /// already running `removeRows` / `reloadData(forRowIndexes:)`, and
    /// the next `viewFor` for an `.update` reads the (now absent) entry
    /// out of this dict so the new cell starts with no selection.
    func dropEntry(blockId: UUID) {
        selections.removeValue(forKey: blockId)
    }

    /// Cmd+A: select every selectable block via its adapter's `fullRange`.
    /// Non-selectable blocks (image, list) silently drop out.
    func selectAllText() {
        guard let tc = transcript else { return }
        var changed = Set<UUID>()
        for id in tc.blockIds {
            guard let adapter = tc.selectionAdapter(forBlockId: id) else { continue }
            let next = adapter.fullRange
            if next.start == next.end { continue }
            if selections[id] != next {
                selections[id] = next
                changed.insert(id)
            }
        }
        for id in changed { tc.markCellNeedsDisplay(blockId: id) }
    }

    /// Replace the entire selection set from a drag tick. `start` and
    /// `current` are in the table's document coords (y-down, since the
    /// table is flipped).
    ///
    /// `byWord` snaps endpoint-row positions to word boundaries via the
    /// adapter's `wordBoundary` closure. Middle rows are full-row regardless.
    func updateSelection(from start: CGPoint, to current: CGPoint,
                         in tableView: NSTableView,
                         byWord: Bool = false) {
        guard let tc = transcript, tableView.numberOfRows > 0 else { return }

        let startRow = resolvedRow(at: start, in: tableView)
        let currentRow = resolvedRow(at: current, in: tableView)
        let lowRow = min(startRow, currentRow)
        let highRow = max(startRow, currentRow)
        let reversed = currentRow < startRow

        var next: [UUID: SelectionRange] = [:]
        for row in lowRow ... highRow {
            guard let block = tc.block(atRow: row),
                  let adapter = tc.selectionAdapter(atRow: row)
            else { continue }

            let rowRect = tableView.rect(ofRow: row)
            let originX = rowRect.minX
                + BlockStyle.cellOriginX(forRowWidth: rowRect.width)
                + BlockStyle.blockHorizontalPadding
            let originY = rowRect.minY + BlockStyle.blockVerticalPadding
            let startLocal = CGPoint(x: start.x - originX, y: start.y - originY)
            let currentLocal = CGPoint(x: current.x - originX, y: current.y - originY)

            let posStart = adapter.hitTest(startLocal)
            let posCurrent = adapter.hitTest(currentLocal)

            var a: LayoutPosition
            var b: LayoutPosition
            if lowRow == highRow {
                a = posStart; b = posCurrent
            } else if row == lowRow {
                // Top of multi-row sweep: anchor at the click point that
                // landed in this row, cursor runs to layout end. Reverse
                // drag's cursor is the one in this row.
                a = reversed ? posCurrent : posStart
                b = adapter.fullRange.end
            } else if row == highRow {
                // Bottom of multi-row sweep: mirror.
                a = adapter.fullRange.start
                b = reversed ? posStart : posCurrent
            } else {
                // Middle: full row.
                a = adapter.fullRange.start
                b = adapter.fullRange.end
            }

            if byWord, row == lowRow || row == highRow {
                if let word = adapter.wordBoundary(a) { a = word.start }
                if let word = adapter.wordBoundary(b) { b = word.end }
            }

            // Empty selection on this row → omit (e.g. zero-distance click).
            // We use rect emptiness rather than position equality because a
            // table 1×1 with ch1 == ch2 has equal positions but a
            // legitimately-empty highlight; both signals collapse to "no
            // visible selection on this row, don't store."
            guard a != b, !adapter.rects(a, b).isEmpty else { continue }
            next[block.id] = SelectionRange(start: a, end: b)
        }

        let dirty = Set(selections.keys).union(next.keys)
        selections = next
        for id in dirty { tc.markCellNeedsDisplay(blockId: id) }
    }

    /// Word selection at a single click point — driven by double-click.
    /// Defers to the adapter's `wordBoundary`, which knows the layout's
    /// own word semantics (text uses `NSAttributedString.doubleClick`;
    /// table snaps inside the hit cell).
    func selectWord(at point: CGPoint, in tableView: NSTableView) {
        guard let tc = transcript else { return }
        let row = tableView.row(at: point)
        guard row >= 0,
              let block = tc.block(atRow: row),
              let adapter = tc.selectionAdapter(atRow: row)
        else { return }

        let rowRect = tableView.rect(ofRow: row)
        let local = CGPoint(
            x: point.x - rowRect.minX
                - BlockStyle.cellOriginX(forRowWidth: rowRect.width)
                - BlockStyle.blockHorizontalPadding,
            y: point.y - rowRect.minY - BlockStyle.blockVerticalPadding)

        let pos = adapter.hitTest(local)
        guard let word = adapter.wordBoundary(pos) else { return }
        setSelection(word, blockId: block.id)
    }

    /// Whole-block selection — driven by triple-click. Mapped to the
    /// adapter's `fullRange`.
    func selectFullBlock(at point: CGPoint, in tableView: NSTableView) {
        guard let tc = transcript else { return }
        let row = tableView.row(at: point)
        guard row >= 0,
              let block = tc.block(atRow: row),
              let adapter = tc.selectionAdapter(atRow: row)
        else { return }
        setSelection(adapter.fullRange, blockId: block.id)
    }

    // MARK: - Copy

    /// Concatenated plain-text copy in document order. Per-block joiner
    /// is `\n\n`; intra-block joining (e.g. `\t` between table cells) is
    /// the adapter's `string` closure's responsibility.
    func copyText() -> String {
        guard let tc = transcript else { return "" }
        var pieces: [String] = []
        for id in tc.blockIds {
            guard let range = selections[id],
                  let adapter = tc.selectionAdapter(forBlockId: id)
            else { continue }
            let s = adapter.string(range.start, range.end)
            if !s.isEmpty { pieces.append(s) }
        }
        return pieces.joined(separator: "\n\n")
    }

    /// Whether there is any selectable content at all (used to validate
    /// the Cmd+A menu item).
    var hasSelectableText: Bool {
        guard let tc = transcript else { return false }
        for id in tc.blockIds {
            if tc.selectionAdapter(forBlockId: id) != nil { return true }
        }
        return false
    }

    // MARK: - Window key

    @objc private func windowKeyChanged(_ note: Notification) {
        guard !selections.isEmpty,
              let table = transcript?.tableView,
              let window = table.window,
              note.object as? NSWindow === window
        else { return }
        for id in selections.keys {
            transcript?.markCellNeedsDisplay(blockId: id)
        }
    }

    // MARK: - Helpers

    /// Like `tableView.row(at:)` but resolves "above all rows" to row 0
    /// and "below all rows" to the last row, instead of -1. Drag updates
    /// past the viewport need a row to map to so the gesture's bound
    /// row clamps correctly when the user keeps dragging past the
    /// content.
    private func resolvedRow(at point: CGPoint, in tableView: NSTableView) -> Int {
        let r = tableView.row(at: point)
        if r >= 0 { return r }
        if point.y < 0 { return 0 }
        return max(0, tableView.numberOfRows - 1)
    }
}

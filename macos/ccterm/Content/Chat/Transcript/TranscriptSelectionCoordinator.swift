import AppKit

/// Row-data surface the selection coordinator reads through — implemented
/// by `TranscriptViewController` (which owns the table + store). Kept a
/// protocol so the coordinator stays free of store / table specifics and
/// testable through a fake.
@MainActor
protocol TranscriptSelectionRowSource: AnyObject {
    /// Row at a table index (`nil` outside the row range).
    func selectionRow(atRow row: Int) -> TranscriptRow?
    /// The row's selection adapter (`nil` = row not selectable).
    func selectionAdapter(for row: TranscriptRow) -> SelectionAdapter?
    /// The row's layout origin in the table's document coords — where
    /// `LayoutPosition`-local (0,0) sits.
    func selectionContentOrigin(atRow row: Int) -> CGPoint
    /// Push the current selection state into the row hosting `rowId`
    /// (if its cell is realized) and repaint it.
    func selectionMarkNeedsDisplay(rowId: UUID)
}

/// Cross-row selection state for the history transcript. Ported from the
/// streaming renderer's `Transcript2SelectionCoordinator` — the drag-tick
/// algorithm, the multi-row sweep (top / middle / bottom), the byWord
/// snapping, and the copy semantics are unchanged; only the row surface
/// differs (table rows through `TranscriptSelectionRowSource`).
///
/// ### Source of truth
///
/// `selections: [UUID: SelectionRange]`, keyed by `TranscriptRow.id`.
/// Per-cell state is derived — `viewFor` re-applies the entry on reuse.
///
/// ### Layout-agnostic algorithm
///
/// Works in opaque `LayoutPosition` values produced and consumed by each
/// row's `SelectionAdapter`; this file has zero kind-specific code. Rows
/// whose adapter is `nil` (group headers, images) drop out of a sweep
/// silently.
@MainActor
final class TranscriptSelectionCoordinator: NSObject {
    weak var rowSource: TranscriptSelectionRowSource?
    weak var tableView: NSTableView?

    private var selections: [UUID: SelectionRange] = [:]

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(
            self, selector: #selector(windowKeyChanged(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)
        nc.addObserver(
            self, selector: #selector(windowKeyChanged(_:)),
            name: NSWindow.didResignKeyNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Read

    var isEmpty: Bool { selections.isEmpty }

    func selection(for rowId: UUID) -> SelectionRange? { selections[rowId] }

    func adapter(atRow row: Int) -> SelectionAdapter? {
        guard let source = rowSource, let item = source.selectionRow(atRow: row)
        else { return nil }
        return source.selectionAdapter(for: item)
    }

    // MARK: - Mutation

    func clearAll() {
        guard !selections.isEmpty else { return }
        let ids = Array(selections.keys)
        selections.removeAll()
        for id in ids { rowSource?.selectionMarkNeedsDisplay(rowId: id) }
    }

    /// Replace selection for one row. Empty range (start == end) clears.
    func setSelection(_ range: SelectionRange, rowId: UUID) {
        if range.start == range.end {
            if selections.removeValue(forKey: rowId) != nil {
                rowSource?.selectionMarkNeedsDisplay(rowId: rowId)
            }
        } else if selections[rowId] != range {
            selections[rowId] = range
            rowSource?.selectionMarkNeedsDisplay(rowId: rowId)
        }
    }

    /// Cmd+A: select every selectable row via its adapter's `fullRange`.
    /// Non-selectable rows silently drop out.
    func selectAllText() {
        guard let source = rowSource, let table = tableView else { return }
        var changed = Set<UUID>()
        for row in 0..<table.numberOfRows {
            guard let item = source.selectionRow(atRow: row),
                let adapter = source.selectionAdapter(for: item)
            else { continue }
            let next = adapter.fullRange
            if next.start == next.end { continue }
            if selections[item.id] != next {
                selections[item.id] = next
                changed.insert(item.id)
            }
        }
        for id in changed { source.selectionMarkNeedsDisplay(rowId: id) }
    }

    /// Replace the entire selection set from a drag tick. `start` and
    /// `current` are in the table's document coords (flipped, y-down).
    ///
    /// `byWord` snaps endpoint-row positions to word boundaries via the
    /// adapter's `wordBoundary` closure. Middle rows are full-row
    /// regardless.
    func updateSelection(
        from start: CGPoint, to current: CGPoint, byWord: Bool = false
    ) {
        guard let source = rowSource, let table = tableView,
            table.numberOfRows > 0
        else { return }

        let startRow = resolvedRow(at: start, in: table)
        let currentRow = resolvedRow(at: current, in: table)
        let lowRow = min(startRow, currentRow)
        let highRow = max(startRow, currentRow)
        let reversed = currentRow < startRow

        var next: [UUID: SelectionRange] = [:]
        for row in lowRow...highRow {
            guard let item = source.selectionRow(atRow: row),
                let adapter = source.selectionAdapter(for: item)
            else { continue }

            let origin = source.selectionContentOrigin(atRow: row)
            let startLocal = CGPoint(x: start.x - origin.x, y: start.y - origin.y)
            let currentLocal = CGPoint(x: current.x - origin.x, y: current.y - origin.y)

            let posStart = adapter.hitTest(startLocal)
            let posCurrent = adapter.hitTest(currentLocal)

            var a: LayoutPosition
            var b: LayoutPosition
            if lowRow == highRow {
                a = posStart
                b = posCurrent
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

            // Empty selection on this row → omit (e.g. zero-distance
            // click). Rect emptiness rather than position equality — a
            // legitimately-empty highlight also collapses to "don't
            // store".
            guard a != b, !adapter.rects(a, b).isEmpty else { continue }
            next[item.id] = SelectionRange(start: a, end: b)
        }

        let dirty = Set(selections.keys).union(next.keys)
        selections = next
        for id in dirty { source.selectionMarkNeedsDisplay(rowId: id) }
    }

    /// Word selection at a single click point — driven by double-click.
    func selectWord(at point: CGPoint) {
        guard let source = rowSource, let table = tableView else { return }
        let row = table.row(at: point)
        guard row >= 0,
            let item = source.selectionRow(atRow: row),
            let adapter = source.selectionAdapter(for: item)
        else { return }

        let origin = source.selectionContentOrigin(atRow: row)
        let pos = adapter.hitTest(CGPoint(x: point.x - origin.x, y: point.y - origin.y))
        guard let word = adapter.wordBoundary(pos) else { return }
        setSelection(word, rowId: item.id)
    }

    /// Whole-unit selection at click point — driven by triple-click.
    /// "Unit" is the layout's smallest semantic chunk (paragraph for
    /// text, cell for tables).
    func selectUnit(at point: CGPoint) {
        guard let source = rowSource, let table = tableView else { return }
        let row = table.row(at: point)
        guard row >= 0,
            let item = source.selectionRow(atRow: row),
            let adapter = source.selectionAdapter(for: item)
        else { return }

        let origin = source.selectionContentOrigin(atRow: row)
        let pos = adapter.hitTest(CGPoint(x: point.x - origin.x, y: point.y - origin.y))
        setSelection(adapter.unitRange(pos), rowId: item.id)
    }

    // MARK: - Copy

    /// Concatenated plain-text copy in document (row) order. Per-row joiner
    /// is `\n\n`; intra-row joining is the adapter's `string` closure's
    /// responsibility.
    func copyText() -> String {
        guard let source = rowSource, let table = tableView else { return "" }
        var pieces: [String] = []
        for row in 0..<table.numberOfRows {
            guard let item = source.selectionRow(atRow: row),
                let range = selections[item.id],
                let adapter = source.selectionAdapter(for: item)
            else { continue }
            let s = adapter.string(range.start, range.end)
            if !s.isEmpty { pieces.append(s) }
        }
        return pieces.joined(separator: "\n\n")
    }

    /// Whether any row is selectable at all (validates Cmd+A).
    var hasSelectableText: Bool {
        guard let source = rowSource, let table = tableView else { return false }
        for row in 0..<table.numberOfRows
        where adapterExists(source: source, row: row) {
            return true
        }
        return false
    }

    private func adapterExists(source: TranscriptSelectionRowSource, row: Int) -> Bool {
        guard let item = source.selectionRow(atRow: row) else { return false }
        return source.selectionAdapter(for: item) != nil
    }

    // MARK: - Window key

    @objc private func windowKeyChanged(_ note: Notification) {
        guard !selections.isEmpty,
            let window = tableView?.window,
            note.object as? NSWindow === window
        else { return }
        for id in selections.keys {
            rowSource?.selectionMarkNeedsDisplay(rowId: id)
        }
    }

    // MARK: - Helpers

    /// Like `row(at:)` but resolves "above all rows" to row 0 and "below
    /// all rows" to the last row, instead of -1 — a drag past the content
    /// still needs a row to clamp to.
    private func resolvedRow(at point: CGPoint, in table: NSTableView) -> Int {
        let r = table.row(at: point)
        if r >= 0 { return r }
        if point.y < 0 { return 0 }
        return max(0, table.numberOfRows - 1)
    }
}

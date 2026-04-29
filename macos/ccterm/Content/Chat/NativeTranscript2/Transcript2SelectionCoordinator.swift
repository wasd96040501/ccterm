import AppKit

/// Cross-row text selection state for the transcript table.
///
/// Owned by `Transcript2Coordinator`. The coordinator delegates all
/// selection mutations to this object; in turn, this object reads
/// per-row data (`block(atRow:)`, `textLayout(atRow:)`,
/// `attributedString(forBlockId:)`) back through the weak `transcript`
/// reference and asks the coordinator to push the new range to the
/// affected `BlockCellView` via `markCellNeedsDisplay(blockId:)`.
///
/// ### Source of truth
///
/// `selections: [UUID: NSRange]` is the source of truth, keyed by
/// `Block.id`. Per-cell state is **derived** — when a cell is reused for
/// a previously-selected block on scroll-in, `viewFor` reads the range
/// out of this dict and applies it to the cell. Holding a weak ref to
/// the cell instead would break under NSTableView view recycling.
///
/// ### Drag-update algorithm
///
/// `updateSelection(from:to:in:)` runs per drag tick during
/// `Transcript2TableView`'s tracking loop. It computes the row range
/// `[lowRow, highRow]` covered by `(start, current)` and, for each row,
/// maps a per-row `(loIndex, hiIndex)` pair:
///
/// - **Single-row drag** — both indexes from drag-start and drag-current,
///   sorted.
/// - **Multi-row, top row** — forward drag: from drag-start to layout
///   end. Reverse drag: from layout start to drag-current.
/// - **Multi-row, bottom row** — symmetric.
/// - **Middle row** — full layout `[0, length]`.
///
/// Image rows (no `TextLayout`) are skipped — selection is non-contiguous
/// across non-text blocks, and copy concatenates text-only entries.
///
/// ### Window-key tracking
///
/// `selectedTextBackgroundColor` (key) vs
/// `unemphasizedSelectedTextBackgroundColor` (resigned) — the cell
/// reads `window?.isKeyWindow` at draw time, so we just need to mark
/// affected cells dirty when key state flips. We listen unscoped (any
/// window) and let `markCellNeedsDisplay` no-op for non-visible cells.
/// Cheap because the dict is small (only blocks with active selection).
@MainActor
final class Transcript2SelectionCoordinator: NSObject {
    weak var transcript: Transcript2Coordinator?

    private var selections: [UUID: NSRange] = [:]

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

    /// Selection range for a block, or `nil` if none. Length-0 ranges are
    /// never stored (callers treat them as "no selection").
    func selection(for blockId: UUID) -> NSRange? { selections[blockId] }

    // MARK: - Mutation

    func clearAll() {
        guard !selections.isEmpty else { return }
        let ids = Array(selections.keys)
        selections.removeAll()
        for id in ids { transcript?.markCellNeedsDisplay(blockId: id) }
    }

    /// Replace selection for one block. Length-0 → clear.
    func setSelection(_ range: NSRange, blockId: UUID) {
        if range.length == 0 {
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
    /// the next `viewFor` for an `.update` reads the (now absent) range
    /// out of this dict to leave the new cell's `selectedRange` empty.
    func dropEntry(blockId: UUID) {
        selections.removeValue(forKey: blockId)
    }

    /// Cmd+A: full select every text-bearing block.
    func selectAllText() {
        guard let tc = transcript else { return }
        var changed = Set<UUID>()
        for id in tc.blockIds {
            guard let attributed = tc.attributedString(forBlockId: id),
                  attributed.length > 0
            else { continue }
            let new = NSRange(location: 0, length: attributed.length)
            if selections[id] != new {
                selections[id] = new
                changed.insert(id)
            }
        }
        for id in changed { tc.markCellNeedsDisplay(blockId: id) }
    }

    /// Replace the entire selection set from a drag tick. `start` and
    /// `current` are in the table's document coords (y-down, since the
    /// table is flipped).
    ///
    /// `byWord` snaps each row's per-row endpoints to word boundaries
    /// (via `NSAttributedString.doubleClick(at:)` — the same Cocoa
    /// primitive `NSTextView` uses for double-click word selection).
    /// Internal endpoints (`0` and `length` at row boundaries) aren't
    /// snapped: they're already at line/paragraph boundaries and
    /// snapping them would either no-op or cross a line break and
    /// drop a character. The attributed string is fetched only for
    /// rows whose endpoint actually came from a click point — middle
    /// rows are full-row select and don't need it.
    func updateSelection(from start: CGPoint, to current: CGPoint,
                         in tableView: NSTableView,
                         byWord: Bool = false) {
        guard let tc = transcript, tableView.numberOfRows > 0 else { return }

        let startRow = resolvedRow(at: start, in: tableView)
        let currentRow = resolvedRow(at: current, in: tableView)
        let lowRow = min(startRow, currentRow)
        let highRow = max(startRow, currentRow)
        let reversed = currentRow < startRow

        var next: [UUID: NSRange] = [:]
        for row in lowRow ... highRow {
            guard let block = tc.block(atRow: row),
                  let layout = tc.textLayout(atRow: row)
            else { continue }

            let rowRect = tableView.rect(ofRow: row)
            let originX = rowRect.minX + BlockStyle.blockHorizontalPadding
            let originY = rowRect.minY + BlockStyle.blockVerticalPadding
            let startLocal = CGPoint(x: start.x - originX, y: start.y - originY)
            let currentLocal = CGPoint(x: current.x - originX, y: current.y - originY)
            let length = layout.length

            var lo: Int
            var hi: Int
            if lowRow == highRow {
                let i1 = layout.characterIndex(at: startLocal)
                let i2 = layout.characterIndex(at: currentLocal)
                lo = min(i1, i2); hi = max(i1, i2)
            } else if row == lowRow {
                if !reversed {
                    lo = layout.characterIndex(at: startLocal); hi = length
                } else {
                    lo = 0; hi = layout.characterIndex(at: currentLocal)
                }
            } else if row == highRow {
                if !reversed {
                    lo = 0; hi = layout.characterIndex(at: currentLocal)
                } else {
                    lo = layout.characterIndex(at: startLocal); hi = length
                }
            } else {
                lo = 0; hi = length
            }

            if byWord, row == lowRow || row == highRow,
               let attributed = tc.attributedString(forBlockId: block.id),
               attributed.length > 0
            {
                // Same-position drag in byWord (mouse hasn't moved past
                // the original word): expand to the word at that index
                // so the click-word selection survives stray 0-distance
                // drag events.
                if lo == hi {
                    let r = attributed.doubleClick(
                        at: max(0, min(lo, attributed.length - 1)))
                    lo = r.location
                    hi = r.location + r.length
                } else {
                    if lo > 0 {
                        let r = attributed.doubleClick(
                            at: max(0, min(lo, attributed.length - 1)))
                        lo = r.location
                    }
                    if hi < attributed.length {
                        let r = attributed.doubleClick(
                            at: max(0, min(hi, attributed.length - 1)))
                        hi = r.location + r.length
                    }
                }
            }

            if hi > lo {
                next[block.id] = NSRange(location: lo, length: hi - lo)
            }
        }

        // Dirty the union of old and new — union covers cells whose
        // range changed, dropped, or added in this tick. Cells whose
        // range is identical across ticks still get setNeedsDisplay,
        // but with `.onSetNeedsDisplay` redraw policy the layer cache
        // absorbs no-op redraws for free.
        let dirty = Set(selections.keys).union(next.keys)
        selections = next
        for id in dirty { tc.markCellNeedsDisplay(blockId: id) }
    }

    /// Word selection at a single click point — driven by double-click.
    /// Defers to `NSAttributedString.doubleClick(at:)` so word semantics
    /// (CJK / Latin / numerics / punctuation gaps) match what
    /// `NSTextView` produces system-wide.
    func selectWord(at point: CGPoint, in tableView: NSTableView) {
        guard let tc = transcript else { return }
        let row = tableView.row(at: point)
        guard row >= 0,
              let block = tc.block(atRow: row),
              let layout = tc.textLayout(atRow: row),
              let attributed = tc.attributedString(forBlockId: block.id),
              attributed.length > 0
        else { return }

        let rowRect = tableView.rect(ofRow: row)
        let local = CGPoint(
            x: point.x - rowRect.minX - BlockStyle.blockHorizontalPadding,
            y: point.y - rowRect.minY - BlockStyle.blockVerticalPadding)
        let idx = max(0, min(layout.characterIndex(at: local), attributed.length - 1))
        setSelection(attributed.doubleClick(at: idx), blockId: block.id)
    }

    /// Whole-block selection at a single click point — driven by
    /// triple-click. In our model "the block" *is* the paragraph /
    /// heading content, so this is equivalent to selecting from
    /// position 0 to attributed.length.
    func selectFullBlock(at point: CGPoint, in tableView: NSTableView) {
        guard let tc = transcript else { return }
        let row = tableView.row(at: point)
        guard row >= 0,
              let block = tc.block(atRow: row),
              let attributed = tc.attributedString(forBlockId: block.id),
              attributed.length > 0
        else { return }
        setSelection(NSRange(location: 0, length: attributed.length),
                     blockId: block.id)
    }

    // MARK: - Copy

    /// Concatenated plain-text copy in document order. Newlines between
    /// blocks; the U+2028 line-separator we use inside paragraphs (for
    /// `lineBreak`) is normalized to `\n` so paste targets that can't
    /// render U+2028 don't show a tofu.
    func copyText() -> String {
        guard let tc = transcript else { return "" }
        var pieces: [String] = []
        for id in tc.blockIds {
            guard let range = selections[id], range.length > 0,
                  let attributed = tc.attributedString(forBlockId: id),
                  range.location + range.length <= attributed.length
            else { continue }
            let s = attributed
                .attributedSubstring(from: range)
                .string
                .replacingOccurrences(of: "\u{2028}", with: "\n")
            pieces.append(s)
        }
        return pieces.joined(separator: "\n\n")
    }

    /// Whether there is any text-bearing block at all (used to validate
    /// the Cmd+A menu item).
    var hasSelectableText: Bool {
        guard let tc = transcript else { return false }
        for id in tc.blockIds {
            if let s = tc.attributedString(forBlockId: id), s.length > 0 {
                return true
            }
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

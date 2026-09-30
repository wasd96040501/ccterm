import Foundation

/// The reader's selection: where the press started and where the pointer is now,
/// each a position in one row's flat index space — so a selection can start in
/// one row and end several rows further on.
///
/// **Held by the transcript, not by a row's view.** A view is recycled the moment
/// its row scrolls off, and a selection that runs across rows is always partly
/// off screen; state kept on the view would be lost with it. Held here, a row
/// scrolling back in is handed its part again (`range(inRow:length:)`), the way
/// `NSTableView` hands a reused row view `isSelected`.
///
/// Every row between the two ends is wholly selected, and the two ends are
/// positions like any other — the block that owns one decides what lies between
/// it and its row's edge, which is how a selection starting inside a table still
/// comes out as that table's rectangle.
///
/// Internal rather than private because the arithmetic on row indices is the part
/// most likely to be wrong and the part with nothing to do with AppKit.
struct TextSelection: Equatable {

    /// One end: a row and a position in it.
    ///
    /// The row is held twice. The index is what everything reads — ordering, and
    /// which rows lie between the ends — and is renumbered by an insertion, whose
    /// indices say exactly where every row went. The identity is what the index is
    /// found again by after a removal or a reload, which say only which rows are
    /// left.
    struct Position: Equatable {
        var row: Int
        let id: TranscriptRow.ID
        var index: Int
    }

    /// Where the press started — the end that does not move.
    var anchor: Position

    /// Where the pointer is now.
    var focus: Position

    /// `range` of one row — what a click, a double-click or a triple-click
    /// starts with — anchored at its start.
    init(row: Int, id: TranscriptRow.ID, range: Range<Int>) {
        anchor = Position(row: row, id: id, index: range.lowerBound)
        focus = Position(row: row, id: id, index: range.upperBound)
    }

    /// A caret: a press that has not moved. Kept rather than discarded, because it
    /// is where the next drag extends from, and it selects nothing.
    var isEmpty: Bool {
        anchor.row == focus.row && anchor.index == focus.index
    }

    /// The first and last rows the selection touches.
    var rows: ClosedRange<Int> {
        min(anchor.row, focus.row)...max(anchor.row, focus.row)
    }

    /// The two ends in reading order.
    private var ordered: (start: Position, end: Position) {
        (anchor.row, anchor.index) <= (focus.row, focus.index) ? (anchor, focus) : (focus, anchor)
    }

    /// The part of row `row` that is selected, for a row `length` positions long,
    /// or `nil` where none of it is.
    ///
    /// Clamped to `length`: a row rewritten while off screen can come back shorter
    /// than the index an end was left at, and a selection covering the wrong
    /// characters until the next click is a better failure than a range past the
    /// end of the text.
    func range(inRow row: Int, length: Int) -> Range<Int>? {
        let (start, end) = ordered
        guard start.row <= row, row <= end.row else { return nil }
        let lower = row == start.row ? min(start.index, length) : 0
        let upper = row == end.row ? min(end.index, length) : length
        return lower < upper ? lower..<upper : nil
    }

    /// Whether the position `index` in row `row` is inside — what a right-click
    /// asks before deciding to keep the selection rather than take a word.
    ///
    /// In the index space, not geometrically, which is `NSTextView`'s test too.
    func contains(row: Int, index: Int) -> Bool {
        let (start, end) = ordered
        return (start.row, start.index) <= (row, index) && (row, index) < (end.row, end.index)
    }

    /// Whether either end is in the row `id` — the rows whose content decides
    /// whether the selection still means anything.
    func ends(in id: TranscriptRow.ID) -> Bool {
        anchor.id == id || focus.id == id
    }

    /// The same selection, renumbered for rows inserted at `indexes` (positions in
    /// the *post*-insertion data, as `insertRows(at:)` takes them): each end moves
    /// down one for every inserted position at or before where it lands.
    func shifted(byRowsInserted indexes: IndexSet) -> TextSelection {
        func shifted(_ row: Int) -> Int {
            var shifted = row
            for index in indexes where index <= shifted { shifted += 1 }
            return shifted
        }
        var selection = self
        selection.anchor.row = shifted(anchor.row)
        selection.focus.row = shifted(focus.row)
        return selection
    }

    /// The same selection with its rows found again by identity, or `nil` when a
    /// row an end was in is gone — there is nowhere left for that end to be.
    ///
    /// `rows` needs to hold only the two ends' identities: it is filled by the one
    /// walk over the data source a removal or a reload already makes.
    func relocated(to rows: [TranscriptRow.ID: Int]) -> TextSelection? {
        guard let anchorRow = rows[anchor.id], let focusRow = rows[focus.id] else { return nil }
        var selection = self
        selection.anchor.row = anchorRow
        selection.focus.row = focusRow
        return selection
    }
}

import AppKit

/// One entry per row, holding what that row cost to build.
///
/// The transcript is asked for a row's height and, later, for its view. Without
/// this, both answered by parsing the markdown source and typesetting it from
/// scratch — twice per row per screen, and again for every row on every width
/// change. What makes a cache possible rather than merely desirable is the phase
/// split: a `Block` is built once and is **width-independent**, so a resize
/// re-measures without re-parsing and without re-shaping a glyph.
///
/// ## Why the six mutation paths live here
///
/// Every entry is positional — `entries[i]` is row `i`'s — so every mutation that
/// renumbers rows has to renumber these too, and a single missed one shows up as
/// a row rendering another row's content, only under some orderings, long after
/// the mutation. Keeping all of them in one file is what makes that invariant
/// something a reader can check in one sitting rather than something spread
/// across six public methods of a 950-line view.
///
/// **Width is not one of those paths.** It is recorded per entry and checked when
/// the entry is read, so a width change needs no sweep, no stored "current
/// width", and no invalidation call — a stale entry simply re-measures the next
/// time it is asked for. `TypesetText.typesetWidth` is the same comparison one
/// level down.
///
/// Entries are `nil` for rows never asked about and for rows the transcript does
/// not draw itself (`.view`), so the array stays index-aligned with the data
/// source whatever mix of row kinds it holds.
final class RowCache {

    private struct Entry {
        /// Width-independent: survives every resize.
        let block: Block

        var measured: MeasuredBlock
        var measuredWidth: CGFloat
    }

    private var entries: [Entry?] = []

    /// Row `row`'s measured tree at `width`, building whatever is missing.
    ///
    /// `build` is a closure rather than a value so that a hit costs nothing —
    /// the parse it would perform is the expensive half, and on a hit it must not
    /// happen at all.
    func measuredBlock(forRow row: Int, width: CGFloat, build: () -> Block) -> MeasuredBlock {
        if row >= entries.count {
            entries.append(contentsOf: repeatElement(nil, count: row - entries.count + 1))
        }

        if let entry = entries[row] {
            if entry.measuredWidth == width { return entry.measured }
            let measured = entry.block.measure(width)
            entries[row] = Entry(block: entry.block, measured: measured, measuredWidth: width)
            return measured
        }

        let built = build()
        let measured = built.measure(width)
        entries[row] = Entry(block: built, measured: measured, measuredWidth: width)
        return measured
    }

    // MARK: - Renumbering

    func reloadAll() {
        entries.removeAll(keepingCapacity: true)
    }

    /// Positions in the post-insertion data, as `TranscriptView.insertRows` takes
    /// them. `IndexSet` iterates ascending, which is the order that keeps each
    /// index meaning what it meant when the caller wrote it.
    ///
    /// An index past the end needs no placeholder: the rows before it were never
    /// built either, and the array grows into them the first time one is asked
    /// for.
    func insert(at indexes: IndexSet) {
        for index in indexes where index <= entries.count {
            entries.insert(nil, at: index)
        }
    }

    /// Positions in the pre-removal data, as `TranscriptView.removeRows` takes
    /// them — so descending, or each removal would shift the ones still to come.
    func remove(at indexes: IndexSet) {
        for index in indexes.reversed() where index < entries.count {
            entries.remove(at: index)
        }
    }

    /// The row's content changed. Drops the block too: the source it was parsed
    /// from is no longer what the data source would hand over.
    func reload(at indexes: IndexSet) {
        for index in indexes where index < entries.count {
            entries[index] = nil
        }
    }
}

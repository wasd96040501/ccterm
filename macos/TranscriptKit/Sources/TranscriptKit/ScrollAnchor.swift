import Foundation

/// Where the viewport was before a mutation, and everything needed to put it
/// back after one.
///
/// Two cases, because there are two ways to restore and the difference has to
/// survive the mutation: whether the viewport was sitting at the end of the
/// scroll cannot be re-derived afterwards — appending a row means it no longer
/// is. So the answer is sampled before and carried across.
///
/// An enum rather than a struct with a flag: in the `tail` case a row and an
/// offset mean nothing, and three fields would admit the combination where the
/// flag is set and a row nobody should read sits next to it.
///
/// The value lives only between sampling and restoring — nothing here is state
/// the transcript keeps. Which of the two rules applies is decided by where the
/// scroll offset was when it was sampled, never by a flag an earlier call set.
///
/// Internal rather than private so the arithmetic below can be tested on its
/// own: shifting an index through an insertion or a removal is the part most
/// likely to be wrong and the part with nothing to do with AppKit, so it is
/// worth reaching without a window.
enum ScrollAnchor: Equatable {

    /// The viewport was at the end of the scrollable range. Restore by going
    /// back to the end, wherever that now is.
    case tail

    /// The viewport's top edge was `offsetFromTop` points below the top edge of
    /// row `row` — so restoring means putting that row's top back that far above
    /// the viewport's.
    ///
    /// Anchoring on the topmost visible row is what makes the two rules one rule:
    /// geometry changing above it moves that row, and following it holds the
    /// content still; geometry changing below it doesn't move it, and nothing
    /// needs doing.
    case row(Int, offsetFromTop: CGFloat)

    /// The same content position, renumbered for rows inserted at `indexes`.
    ///
    /// `indexes` are positions in the *post*-insertion data, matching
    /// `TranscriptView.insertRows(at:withAnimation:)`. An inserted position at or
    /// before where the anchor ends up pushes it one further down; iterating
    /// ascending (which `IndexSet` does) makes that a running total rather than a
    /// counting argument.
    func shifted(byRowsInserted indexes: IndexSet) -> ScrollAnchor {
        guard case .row(let row, let offsetFromTop) = self else { return self }
        var shifted = row
        for index in indexes where index <= shifted { shifted += 1 }
        return .row(shifted, offsetFromTop: offsetFromTop)
    }

    /// The same content position, renumbered for rows removed at `indexes`
    /// (positions in the *pre*-removal data, matching
    /// `TranscriptView.removeRows(at:withAnimation:)`).
    ///
    /// When the anchor row itself is removed there is no content position to
    /// hold: what the reader had at the top of the viewport is gone. The next
    /// surviving row takes its place at the top instead, which loses the
    /// sub-row offset — the alternative is holding an offset into a row that no
    /// longer exists.
    func shifted(byRowsRemoved indexes: IndexSet) -> ScrollAnchor {
        guard case .row(let row, let offsetFromTop) = self else { return self }
        guard indexes.contains(row) else {
            return .row(row - indexes.count(in: 0..<row), offsetFromTop: offsetFromTop)
        }
        var survivor = row
        while indexes.contains(survivor) { survivor += 1 }
        // Past the last row when the removal reached the end; the restore clamps
        // against the post-mutation row count rather than this doing it blind.
        return .row(survivor - indexes.count(in: 0..<survivor), offsetFromTop: 0)
    }
}

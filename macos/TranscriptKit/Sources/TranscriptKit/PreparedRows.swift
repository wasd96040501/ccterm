import AppKit

/// Rows already measured, on their way to `insertRows(at:warming:)`.
///
/// Produced by `TranscriptView.prepareRows(_:)` — which does the parsing,
/// shaping and typesetting off the main actor — and consumed by
/// `TranscriptView.insertRows(at:warming:)`, which merges it into the
/// transcript's row cache so that the insert costs a lookup per row instead of a
/// typesetting pass per row.
///
/// Opaque, and deliberately: what it holds is `MeasuredBlock`s, which are this
/// package's internal layout product. A host has nothing to do with the contents
/// and no reason to keep one around — `count` is the whole surface, and it is
/// there so a host can assert against the batch it handed over.
///
/// ## Keyed on identity, which is why it has no order
///
/// Each measurement is filed under the `TranscriptRow.ID` it was made for, so
/// this batch describes *which rows* it measured rather than *where they will
/// go*. Nothing about it has to line up with the `IndexSet` it is handed
/// alongside: the two arguments of `insertRows(at:warming:)` do two unrelated
/// jobs, and neither their sizes nor their orders need agree.
///
/// It was positional once — the *k*-th entry belonging to the *k*-th smallest
/// index — and that pairing is what made a background measurement dangerous:
/// every insertion or removal that landed while the batch was in flight moved
/// the rows out from under it, so the landing site had to re-ask the data source
/// what lived at each index before it dared write, and a mismatch it failed to
/// catch was a row permanently the wrong height. None of that survives the
/// identity. **Anything at all may happen to the transcript while a batch is in
/// flight.**
///
/// ## When it goes stale, and what that costs
///
/// Every entry is measured into **one** content width, recorded here. If the
/// window is resized between the `await` and the insert, that number no longer
/// applies to any of them, and the whole batch is dropped rather than merged —
/// the insert then measures the rows itself, exactly as `insertRows(at:)` does.
///
/// That check is thrift rather than correctness: an entry records the width it
/// was actually measured at, so one merged at the wrong width is rejected by the
/// row cache's own read-time comparison anyway. What the check buys is not
/// writing a dictionary's worth of entries that will all miss.
///
/// Individual entries go stale the same way — a row whose content moved between
/// the measurement and the insert is rejected on read, by the comparison every
/// other entry faces. So staleness is **not** an error and needs no handling: it
/// degrades to the synchronous path. The only thing it costs is the background
/// work, which is why `prepareRows(_:)` is documented to be called in batches — a
/// resize halfway through wastes one batch rather than all of them.
public struct PreparedRows: Sendable {

    /// One measurement per row that produced one, under the identity it was made
    /// for.
    ///
    /// Whole cache entries, recipe included — so a row that arrived this way is
    /// indistinguishable from one the transcript measured itself, and in
    /// particular is no more expensive to resize. See `RowCache.Body`.
    let entries: [TranscriptRow.ID: RowCache.Entry]

    /// The content width every entry above was measured into.
    let width: CGFloat

    init(entries: [TranscriptRow.ID: RowCache.Entry], width: CGFloat) {
        self.entries = entries
        self.width = width
    }

    /// How many measurements this carries.
    ///
    /// Not the length of the array handed to `prepareRows(_:)`, which it was when
    /// this type was positional: a `.view` row produces nothing to warm, and so
    /// does a row whose measurement was cancelled. The number is what will be
    /// merged, which is the only version of it a host can act on.
    ///
    /// The whole public surface, and `isEmpty` is deliberately not beside it
    /// (§3): nothing has needed one, and `count == 0` says it.
    public var count: Int { entries.count }
}

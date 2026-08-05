import AppKit

/// Rows already measured, on their way to `insertRows(at:prepared:)`.
///
/// Produced by `TranscriptView.prepareRows(_:)` — which does the parsing,
/// shaping and typesetting off the main actor — and consumed by
/// `TranscriptView.insertRows(at:prepared:)`, which seeds the transcript's row
/// cache with it so that the insert costs a lookup per row instead of a
/// typesetting pass per row.
///
/// Opaque, and deliberately: what it holds is `MeasuredBlock`s, which are this
/// package's internal layout product. A host has nothing to do with the contents
/// and no reason to keep one around — `count` is the whole surface, and it is
/// there so a host can assert against the batch it handed over.
///
/// ## When it goes stale, and what that costs
///
/// Every entry is measured into **one** content width, recorded here. If the
/// window is resized between the `await` and the insert, that number no longer
/// applies to any of them, and the whole batch is dropped at seed time — the
/// insert then measures the rows itself, exactly as `insertRows(at:)` does.
/// Individual entries drop the same way when the row they were prepared for now
/// holds different text.
///
/// So staleness is **not** an error and needs no handling: it degrades to the
/// synchronous path. The only thing it costs is the background work, which is
/// why `prepareRows(_:)` is documented to be called in batches — a resize
/// halfway through wastes one batch rather than all of them.
///
/// ## Ordering
///
/// Entries stay in the order the contents were given. `insertRows(at:prepared:)`
/// pairs them with `indexes` in ascending order: the *k*-th content lands at the
/// *k*-th smallest index. Nothing else is implied — the indices need not be
/// contiguous, and a `.view` row among them simply carries no entry.
public struct PreparedRows: Sendable {

    /// One row's answer: what it was measured from, and what came out.
    ///
    /// The content travels with the measurement rather than being looked up
    /// again at seed time, because the seed's whole job is deciding whether the
    /// two still describe the same row — and a lookup could only ask the party
    /// that has already moved on.
    ///
    /// **The whole content, not its text.** Carrying only the source `String`
    /// was the first shape here, and it is wrong in a way worth recording: a
    /// bubble is measured into three quarters of the column and a document into
    /// all of it, so one string has two heights depending on which case it
    /// arrives as. A seed keyed on the text alone therefore accepts a document's
    /// measurement onto a user's turn — and because the entry it writes is
    /// internally consistent, nothing later disagrees with it. That is the one
    /// way this mechanism could produce a *persistent* wrong height rather than
    /// a wasted re-measure, and `PreparedRowsTests` is what found it.
    struct Row: Sendable {
        let content: TranscriptRowContent

        /// A whole cache entry, recipe included — so a row that arrived this way
        /// is indistinguishable from one the transcript measured itself, and in
        /// particular is no more expensive to resize. See `RowCache.Body`.
        let entry: RowCache.Entry
    }

    /// Index-aligned with the array `prepareRows(_:)` was given. `nil` for a
    /// `.view` row — the host measures those itself, through the delegate — and
    /// for one whose measurement was cancelled.
    private let rows: [Row?]

    /// The content width every entry above was measured into.
    let width: CGFloat

    init(rows: [Row?], width: CGFloat) {
        self.rows = rows
        self.width = width
    }

    /// How many rows this covers: the length of the array handed to
    /// `prepareRows(_:)`, including the `.view` rows that produced nothing.
    ///
    /// The whole public surface, and `isEmpty` is deliberately not beside it
    /// (§3): nothing has needed one, and `count == 0` says it.
    public var count: Int { rows.count }

    /// Bounds-checked, because the caller pairs this against an `IndexSet` whose
    /// size is the host's and need not match.
    subscript(offset: Int) -> Row? {
        guard offset >= 0, offset < rows.count else { return nil }
        return rows[offset]
    }
}

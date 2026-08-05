import AppKit

/// One entry per row, holding what that row cost to build.
///
/// The transcript is asked for a row's height and, later, for its view. Without
/// this, both answered by parsing the markdown source and typesetting it from
/// scratch — twice per row per screen, and again for every row on every width
/// change.
///
/// ## Keyed on the source, not on a call
///
/// An entry is valid against the markdown it was built from, so the cache
/// notices a content change itself rather than being told about one. Three
/// consequences, all of which are the point:
///
/// - **`reloadRows` on a row whose content did not move is a true no-op.** No
///   re-parse, no re-typeset, nothing marked dirty. A host driving a stream off a
///   frame ticker can announce every frame without first working out whether it
///   has anything to announce — and the check itself is a pointer comparison,
///   since two strings sharing storage compare in constant time and a data source
///   handing back the value it already held is exactly that case.
/// - **A content change that nobody announced still renders correctly**, whenever
///   something next asks. There is no ordering left to get wrong, which is §4's
///   rule about contracts living in the API's shape rather than in prose.
/// - **A row that grew re-typesets only what changed**, because the entry keeps
///   the previous version's pieces in a `MarkdownMemo` for the next version to
///   take. That is the whole of what makes a streaming row affordable, and the
///   reasoning for it is over there.
///
/// **Width is not a mutation path either.** It is recorded per entry and checked
/// when the entry is read, so a width change needs no sweep and no invalidation
/// call — a stale entry simply re-measures the next time it is asked for.
/// `TypesetText.typesetWidth` is the same comparison one level down.
///
/// The same property is most of what makes `seed(_:forRow:source:width:)` safe
/// to expose at all. A measurement computed on another thread, for a row the host
/// may have renumbered since, is written here without ceremony — because an entry
/// is believed only as far as its `(source, width)` agrees with what is being
/// asked for, and a seed that no longer does is indistinguishable from a row
/// nobody has measured. A late or misplaced measurement costs a re-measure rather
/// than a wrong render, which is the difference between "the host must announce
/// mutations before the background work lands" — a rule nobody can hold — and "it
/// does not matter when it lands".
///
/// **Where that stops, and it is worth knowing exactly where.** `(source, width)`
/// identifies an entry, not the *thing it was measured as*. One string measures to
/// two different heights depending on which `TranscriptRowContent` case it
/// arrives in — a bubble takes three quarters of the column — so a measurement
/// filed under the wrong case is internally consistent and nothing here will ever
/// object to it. That single gap is closed one level up, by
/// `TranscriptView.seed(_:at:)` comparing whole content values before it writes,
/// and it is the only check in that method that is load-bearing rather than
/// thrift.
///
/// ## Why the renumbering lives here
///
/// Every entry is positional — `entries[i]` is row `i`'s — so every mutation that
/// renumbers rows has to renumber these too, and a single missed one shows up as
/// a row rendering another row's content, only under some orderings, long after
/// the mutation. Keeping both in one file is what makes that invariant something
/// a reader can check in one sitting rather than something spread across the
/// public methods of a thousand-line view.
///
/// Entries are `nil` for rows never asked about and for rows the transcript does
/// not draw itself (`.view`), so the array stays index-aligned with the data
/// source whatever mix of row kinds it holds.
final class RowCache {

    /// One row's answer, and everything needed to produce the next one cheaply.
    ///
    /// `Sendable`, because this is also what a background task produces: measuring
    /// off the main actor and measuring on it end at the same value, so there is
    /// one shape rather than a "prepared" one and a real one. See
    /// `TranscriptView.prepareRows(_:)`.
    struct Entry: Sendable {

        /// The text this was built from — what the entry is valid against.
        var source: String

        /// How it rebuilds when that text moves.
        var body: Body

        var measured: MeasuredBlock
        var measuredWidth: CGFloat
    }

    /// What an entry keeps between versions of its source, which is the one thing
    /// that differs between the self-drawn cases.
    ///
    /// A document is many blocks and grows a token at a time, so what is worth
    /// keeping is the blocks that did not change. A user's bubble is one block and
    /// arrives whole, so what is worth keeping is the recipe — which costs nothing
    /// on a width change and is simply rebuilt when the text moves. Modelling that
    /// as an enum rather than as two caches keeps one array, one set of
    /// renumbering, and one answer to "has this row's source moved".
    ///
    /// **Two cases, and there was briefly a third.** A `seeded` case carried a
    /// measurement with no recipe behind it, for entries that had crossed an actor
    /// boundary back when `Block` was not `Sendable`. It was not a third way of
    /// keeping something — it was *nothing kept*, which is a hole rather than a
    /// case, and it cost what a hole here costs: every row that arrived from a
    /// background task re-parsed **and re-shaped** on the first width change,
    /// instead of only re-breaking its lines. On a ten-thousand-row transcript
    /// that is the difference between a resize and a freeze. Nine
    /// `@unchecked Sendable` annotations retired it, in nine files that each
    /// already carried the identical annotation one type below.
    enum Body: Sendable {
        case markdown(MarkdownMemo)
        case block(Block)
    }

    private var entries: [Entry?] = []

    /// Row `row`'s markdown, laid out at `width` — handed back untouched when
    /// neither has moved, which is the usual case: `NSTableView` asks for a
    /// height and then, for the rows it is about to show, a view.
    ///
    /// A source that moved re-typesets only the blocks that changed; see
    /// `MarkdownMemo`, which is the whole of why this case has an entry point of
    /// its own.
    func measuredMarkdown(forRow row: Int, source: String, width: CGFloat) -> MeasuredBlock {
        padEntries(through: row)
        if let entry = entries[row], entry.source == source, entry.measuredWidth == width {
            return entry.measured
        }

        var memo: MarkdownMemo
        if case .markdown(let previous)? = entries[row]?.body {
            memo = previous
        } else {
            memo = MarkdownMemo()
        }
        let measured = memo.measure(source, width: width)
        entries[row] = Entry(
            source: source, body: .markdown(memo), measured: measured, measuredWidth: width)
        return measured
    }

    /// Row `row`'s tree for any other case the transcript draws itself: one
    /// recipe for the whole source, re-measured when the width moves and rebuilt
    /// when the source does.
    ///
    /// `build` is a closure rather than a value so that a hit costs nothing — the
    /// shaping it would perform is the expensive half, and on a hit it must not
    /// happen at all.
    func measuredBlock(
        forRow row: Int, source: String, width: CGFloat, build: () -> Block
    ) -> MeasuredBlock {
        padEntries(through: row)
        if let entry = entries[row], entry.source == source, case .block(let block) = entry.body {
            if entry.measuredWidth == width { return entry.measured }
            let measured = block.measure(width)
            entries[row] = Entry(
                source: source, body: .block(block), measured: measured, measuredWidth: width)
            return measured
        }

        let block = build()
        let measured = block.measure(width)
        entries[row] = Entry(
            source: source, body: .block(block), measured: measured, measuredWidth: width)
        return measured
    }

    /// Files an entry someone else produced — off the main actor, by
    /// `TranscriptView.prepareRows(_:)` — as row `row`'s.
    ///
    /// A whole `Entry`, recipe included, so a prepared row is **indistinguishable
    /// from one this cache measured itself**: same donor for the next version of
    /// its source, same recipe for the next width. Handing over only the
    /// measurement is what the retired `Body.seeded` case was, and its cost is
    /// written down there.
    ///
    /// **Unconditional on purpose.** Every check that could belong here is
    /// already somewhere better: that the entry is still *for* this row is checked
    /// against the live data source by the caller, one row at a time, before it
    /// gets here; that it is still valid is checked on every read, by the same
    /// `(source, width)` comparison every other entry faces. So the worst a wrong
    /// seed can do is cost a re-measure the next time the row is asked about — the
    /// same cost as no seed at all.
    func seed(_ entry: Entry, forRow row: Int) {
        padEntries(through: row)
        entries[row] = entry
    }

    /// The text row `row` was last built from, or `nil` for a row nothing has
    /// asked about.
    ///
    /// One caller, and a narrow question: whether the source a row is about to be
    /// rebound with *extends* the one it is already showing, which is what decides
    /// whether the reader's selection in it still names the same characters. See
    /// `TranscriptView.rebindVisibleRows(in:)`.
    func source(forRow row: Int) -> String? {
        guard row >= 0, row < entries.count else { return nil }
        return entries[row]?.source
    }

    /// Makes `entries[row]` addressable, filling anything short of it with `nil`.
    ///
    /// The array is built lazily and `NSTableView` asks about rows in whatever
    /// order it tiles, so the first question can be about row 40 of an array that
    /// is still empty.
    private func padEntries(through row: Int) {
        guard row >= entries.count else { return }
        entries.append(contentsOf: repeatElement(nil, count: row - entries.count + 1))
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
}

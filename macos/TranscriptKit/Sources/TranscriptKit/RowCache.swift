import AppKit

/// One entry per row, holding what that row cost to build.
///
/// The transcript is asked for a row's height and, later, for its view. Without
/// this, both answered by parsing the markdown source and typesetting it from
/// scratch — twice per row per screen, and again for every row on every width
/// change.
///
/// ## Keyed on the row's identity, valid against its content
///
/// Two different questions, answered by two different halves of `TranscriptRow`,
/// and keeping them apart is what this file is for.
///
/// **The key is the host's identity** (`TranscriptRow.ID`). A row keeps its
/// entry through every insertion and removal above it, through a reorder, and
/// through a `reloadData` — because none of those change who it is. Nothing here
/// has to be told that rows moved.
///
/// **The value is believed only as far as its `(content, width)` still matches
/// what is being asked for**, so the cache notices a content change itself rather
/// than being told about one. Three consequences, all of which are the point:
///
/// - **`reloadRows` on a row whose content did not move is a true no-op.** No
///   re-parse, no re-typeset, nothing marked dirty. A host driving a stream off a
///   frame ticker can announce every frame without first working out whether it
///   has anything to announce — and the check itself is a case comparison and
///   then a pointer comparison, since two strings sharing storage compare in
///   constant time and a data source handing back the value it already held is
///   exactly that case.
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
/// **The whole content, not its source text.** One string measures to two
/// different heights depending on which `TranscriptRowContent` case it arrives in
/// — a bubble takes three quarters of the column — so an entry validated on text
/// alone would serve a bubble's measurement to a document that happens to hold
/// the same words, and the entry it wrote is internally consistent, so nothing
/// downstream would ever object. That is the one way this mechanism can produce a
/// *persistent* wrong height rather than a wasted re-measure, and comparing whole
/// values costs nothing extra: the case is checked first.
///
/// ## What the identity deleted
///
/// This was a positional array — `entries[i]` was row *i*'s — spliced in lockstep
/// with every mutation that renumbered rows, from `insert(at:)` and `remove(at:)`
/// that lived here for exactly that purpose. The invariant read: *a single missed
/// shift shows up as a row rendering another row's content, only under some
/// orderings, long after the mutation.* Keying on identity does not make that
/// invariant easier to hold, it removes the thing it was about.
///
/// Three further guards went with it, all of which existed to compensate for a
/// key that moved: a generation counter to invalidate everything a `reloadData`
/// renumbered, a per-row content check performed at the landing site of a
/// background measurement to catch one that had been filed under a row that had
/// since moved, and the batch-wide pairing between an `IndexSet` and an ordered
/// array of results. What is left is the `(content, width)` comparison above,
/// which was always here and is the cache's own question about its own validity.
///
/// ## What the identity cost
///
/// A dictionary does not shrink when rows go away, where the array did so for
/// free. `keep(_:)` is the answer, called by the transcript on the two mutations
/// that can orphan an entry — and it costs a walk of the data source where the
/// array cost a memmove: measured, removing three rows from ten thousand goes
/// from 0.7 ms to 5.1 ms. `TranscriptView.sweepCache()` is where that trade is
/// written down.
///
/// What it buys back is larger than what it costs. `reloadData` is no longer a
/// full discard, so a reorder is free where it used to re-typeset the whole
/// transcript; and nothing has to be spliced per insert, which on a
/// ten-thousand-row prepared load took the worst batch from 10.0 ms to 1.5 ms and
/// made it flat rather than growing.
///
/// That is bounded growth, not eviction. **Nothing here evicts a live row**, so a
/// transcript that is fully read is a transcript fully typeset in memory. That
/// was true of the array too and is recorded in §6.
final class RowCache {

    /// One row's answer, and everything needed to produce the next one cheaply.
    ///
    /// `Sendable`, because this is also what a background task produces: measuring
    /// off the main actor and measuring on it end at the same value, so there is
    /// one shape rather than a "prepared" one and a real one. See
    /// `TranscriptView.prepareRows(_:)`.
    struct Entry: Sendable {

        /// What this was built from — what the entry is valid against. The whole
        /// content rather than its text, for the reason above.
        var content: TranscriptRowContent

        /// How it rebuilds when that content moves.
        var body: Body

        var measured: MeasuredBlock
        var measuredWidth: CGFloat
    }

    /// What an entry keeps between versions of its content, which is the one thing
    /// that differs between the self-drawn cases.
    ///
    /// A document is many blocks and grows a token at a time, so what is worth
    /// keeping is the blocks that did not change. A user's bubble is one block and
    /// arrives whole, so what is worth keeping is the recipe — which costs nothing
    /// on a width change and is simply rebuilt when the text moves. Modelling that
    /// as an enum rather than as two caches keeps one store and one answer to "has
    /// this row's content moved".
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

    private var entries: [TranscriptRow.ID: Entry] = [:]

    /// `row`'s markdown, laid out at `width` — handed back untouched when neither
    /// the content nor the width has moved, which is the usual case:
    /// `NSTableView` asks for a height and then, for the rows it is about to show,
    /// a view.
    ///
    /// A content that moved re-typesets only the blocks that changed; see
    /// `MarkdownMemo`, which is the whole of why this case has an entry point of
    /// its own.
    ///
    /// `source` is `row.content`'s payload, unwrapped by the caller that already
    /// pattern-matched to get here. It is what the memo takes; `row.content` is
    /// what the entry is keyed and validated on, and the two are not
    /// interchangeable — see the note on comparing whole values above.
    func measuredMarkdown(for row: TranscriptRow, source: String, width: CGFloat) -> MeasuredBlock {
        if let entry = entries[row.id], entry.content == row.content, entry.measuredWidth == width {
            return entry.measured
        }

        var memo: MarkdownMemo
        if case .markdown(let previous)? = entries[row.id]?.body {
            memo = previous
        } else {
            memo = MarkdownMemo()
        }
        let measured = memo.measure(source, width: width)
        entries[row.id] = Entry(
            content: row.content, body: .markdown(memo), measured: measured, measuredWidth: width)
        return measured
    }

    /// `row`'s tree for any other case the transcript draws itself: one recipe for
    /// the whole content, re-measured when the width moves and rebuilt when the
    /// content does.
    ///
    /// `build` is a closure rather than a value so that a hit costs nothing — the
    /// shaping it would perform is the expensive half, and on a hit it must not
    /// happen at all.
    func measuredBlock(
        for row: TranscriptRow, width: CGFloat, build: () -> Block
    ) -> MeasuredBlock {
        if let entry = entries[row.id], entry.content == row.content,
            case .block(let block) = entry.body
        {
            if entry.measuredWidth == width { return entry.measured }
            let measured = block.measure(width)
            entries[row.id] = Entry(
                content: row.content, body: .block(block), measured: measured, measuredWidth: width)
            return measured
        }

        let block = build()
        let measured = block.measure(width)
        entries[row.id] = Entry(
            content: row.content, body: .block(block), measured: measured, measuredWidth: width)
        return measured
    }

    /// Files entries someone else produced — off the main actor, by
    /// `TranscriptView.prepareRows(_:)`.
    ///
    /// Whole `Entry` values, recipe included, so a prepared row is
    /// **indistinguishable from one this cache measured itself**: same donor for
    /// the next version of its content, same recipe for the next width. Handing
    /// over only the measurement is what the retired `Body.seeded` case was, and
    /// its cost is written down there.
    ///
    /// **Unconditional, and now that is a structural fact rather than a choice.**
    /// There is no slot to land in wrongly: an entry arrives under the identity it
    /// was measured for, and if the row it names has changed since, the
    /// `(content, width)` comparison every read performs rejects it exactly as it
    /// would reject any other stale entry. The worst a late batch can do is cost a
    /// re-measure, which is the same cost as no batch at all. The positional
    /// version of this method took an index and had to re-ask the data source what
    /// lived there before it dared write.
    func merge(_ prepared: [TranscriptRow.ID: Entry]) {
        entries.merge(prepared) { _, new in new }
    }

    /// The text `id`'s row was last built from, or `nil` for a row nothing has
    /// asked about.
    ///
    /// One caller, and a narrow question: whether the content a row is about to be
    /// rebound with *extends* the one it is already showing, which is what decides
    /// whether the reader's selection in it still names the same characters. See
    /// `TranscriptView.rebindVisibleRows(in:)`.
    func source(for id: TranscriptRow.ID) -> String? {
        entries[id]?.content.source
    }

    // MARK: - Bounding

    /// Drops every entry whose row is no longer in the data source.
    ///
    /// The dictionary's replacement for what the array got from `remove(at:)`.
    /// Called by the transcript from `removeRows` and `reloadData` — the two
    /// mutations after which an id may name nothing — and deliberately *not* from
    /// `insertRows` or `reloadRows`, which can only add or change rows.
    ///
    /// Keeping rather than removing, because the caller knows which rows exist and
    /// not which ones stopped existing: a `removeRows` reaches the transcript after
    /// the host has already mutated, so the departed rows can no longer be asked
    /// about.
    func keep(_ live: Set<TranscriptRow.ID>) {
        entries = entries.filter { live.contains($0.key) }
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }
}

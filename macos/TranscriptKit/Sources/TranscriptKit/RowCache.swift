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
/// ## Heights for every row, trees for a few
///
/// An entry is two things of very different sizes: the row's **height**, a
/// number, and its **tree** — the recipe and the typeset lines it was measured
/// from. Measured on the demo's corpus, a tree is about **470 KB** of Core Text
/// (`CTRun`s, glyph advances, `CTLine`s, the typesetter behind them), roughly 87
/// bytes per character of source. This cache used to keep the tree of every row
/// it had ever measured, so a ten-thousand-row prepared load held all ten
/// thousand: **4.6 GB**, freed only when the transcript went.
///
/// The table needs a height for every row; it needs a tree only for the rows it
/// is drawing. So every entry keeps its height for as long as its row lives, and
/// the trees are held **up to `residentBudget`**, least recently drawn first to
/// go. A row whose tree went is typeset again the next time something asks to
/// draw it — one row's cost, on a row scrolling into view, which is what
/// `NSTableView` pays for every row it shows anyway.
///
/// What an evicted row gives up is the recipe, and with it three things that were
/// free while it was resident: a width change rebuilds it from its source rather
/// than re-breaking its lines (off the main actor — see
/// `Entry.remeasured(at:)`), a stream into it starts with no donor, and a find
/// builds it on the pool and drops it again. Each is bounded by the rows that
/// have been evicted, none of them runs on the main thread, and together they are
/// the price of the transcript's memory being a constant rather than its length.
///
/// **What is "recently drawn"** is the tree being asked for by `measured(for:width:)`
/// — the view, the rebind, a find scrolling to a hit. A height question does not
/// count, and neither does a prepared batch landing: both are about rows nobody
/// is looking at, so what they build is filed as the first thing to evict rather
/// than pushing out the rows on screen.
final class RowCache {

    private var entries: [TranscriptRow.ID: Entry] = [:]

    // MARK: - What stays resident

    /// How much source text the resident trees may cover, in UTF-8 bytes.
    ///
    /// A budget in source rather than in bytes of tree, because the source is
    /// what is in hand before anything is built — `prepareRows(_:)` decides which
    /// trees to keep before measuring — and the two are close to proportional:
    /// about 87 bytes of tree per character, measured on the demo's corpus, so
    /// this is in the order of 45 MB. A screenful of prose is a few thousand
    /// characters, so this is tens of screens of scrollback kept typeset.
    static let residentBudget = 512 * 1024

    /// What a row costs beyond its characters — the stack, the typesetter, the
    /// line array — so that a thousand one-word rows are not counted as free.
    static let rowOverhead = 512

    /// When each resident tree was last asked to be drawn; the eviction order.
    /// `0` is "never": a tree built only to answer a height, or landed from a
    /// prepared batch.
    private var lastDrawn: [TranscriptRow.ID: UInt64] = [:]
    private var clock: UInt64 = 0
    private var residentCost = 0

    static func cost(of content: TranscriptRowContent) -> Int {
        (content.source?.utf8.count ?? 0) + rowOverhead
    }

    /// Files `entry` under `id`, keeping the resident accounting in step.
    private func store(_ entry: Entry, for id: TranscriptRow.ID, drawnAt stamp: UInt64?) {
        if let previous = entries[id], previous.tree != nil {
            residentCost -= Self.cost(of: previous.content)
        }
        entries[id] = entry
        if entry.tree != nil {
            residentCost += Self.cost(of: entry.content)
            lastDrawn[id] = stamp ?? lastDrawn[id] ?? 0
        } else {
            lastDrawn[id] = nil
        }
    }

    /// Drops trees, least recently drawn first, until what is left fits — or down
    /// to three quarters of the budget, so that a row built at the edge does not
    /// evict one row per call.
    ///
    /// **Released off the main thread.** Tearing down a few hundred typeset rows is
    /// tens of thousands of Core Text objects, and doing that inside the insert that
    /// pushed the budget over would put back the main-thread cost `prepareRows`
    /// exists to remove. They are immutable and were built on the pool to begin
    /// with, so ending there is sound.
    private func evictIfNeeded(sparing spared: TranscriptRow.ID? = nil) {
        guard residentCost > Self.residentBudget else { return }
        let target = Self.residentBudget * 3 / 4
        var released: [Entry.Tree] = []
        for (id, _) in lastDrawn.sorted(by: { $0.value < $1.value }) {
            guard residentCost > target else { break }
            guard id != spared, let entry = entries[id], let tree = entry.tree else { continue }
            released.append(tree)
            store(entry.evicted, for: id, drawnAt: nil)
        }
        guard !released.isEmpty else { return }
        Task.detached(priority: .utility) { withExtendedLifetime(released) {} }
    }

    /// `row`, laid out at `width` — handed back untouched when neither the content
    /// nor the width has moved, which is the usual case: `NSTableView` asks for a
    /// height and then, for the rows it is about to show, a view. `nil` for content
    /// the transcript does not draw itself.
    ///
    /// **One entry point for every self-drawn case, and nothing here knows which
    /// case it is serving.** What differs between a document and a bubble is what
    /// the rebuild takes from the previous version, and that lives with the
    /// content case, in `Entry.init(measuring:width:reusing:)` — which is also
    /// what `prepareRows(_:)` calls on a background task, so there is one
    /// description of how a row is built rather than one per thread.
    ///
    /// This is therefore the whole of the cache's own logic: *is what I have still
    /// what is being asked for, and if not, hand the stale entry to the rebuild so
    /// it can take what it likes.* Deciding whether the previous entry is any use
    /// is the rebuild's business — it compares content itself, and the worst a
    /// useless donor costs is a rebuild.
    ///
    /// **This is the question that marks a tree as drawn**, and so the one that
    /// decides what eviction keeps. An evicted row is rebuilt here from its
    /// content, with no donor — one row's cost, on a row something is about to draw.
    func measured(for row: TranscriptRow, width: CGFloat) -> MeasuredBlock? {
        clock += 1
        let previous = entries[row.id]
        if let previous, previous.content == row.content, previous.measuredWidth == width,
            let measured = previous.measured
        {
            lastDrawn[row.id] = clock
            return measured
        }
        guard let entry = Entry(measuring: row.content, width: width, reusing: previous) else {
            return nil
        }
        store(entry, for: row.id, drawnAt: clock)
        evictIfNeeded(sparing: row.id)
        return entry.measured
    }

    /// How tall `row` is at `width`, answered from the height an entry keeps when
    /// its tree is gone — so asking about every row in the transcript, which
    /// `NSTableView` does on a reload, builds only the rows nothing has measured.
    ///
    /// What it does build is filed as never drawn: a height is asked of rows far
    /// from the viewport, and the tree it took to answer is the first to go. A row
    /// that was resident keeps its place in the order — a streaming row re-measured
    /// here is one the reader is looking at.
    func height(for row: TranscriptRow, width: CGFloat) -> CGFloat? {
        let previous = entries[row.id]
        if let previous, previous.content == row.content, previous.measuredWidth == width {
            return previous.height
        }
        guard let entry = Entry(measuring: row.content, width: width, reusing: previous) else {
            return nil
        }
        store(entry, for: row.id, drawnAt: nil)
        evictIfNeeded(sparing: row.id)
        return entry.height
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
    ///
    /// Filed as never drawn: a prepared batch is history arriving above the
    /// reader, and letting it push out the rows on screen would be exactly
    /// backwards. Most of a large batch arrives evicted already —
    /// `TranscriptView.prepareRows(_:)` keeps a tree only for as many rows as the
    /// budget holds, and releases the rest on the pool.
    func merge(_ prepared: [TranscriptRow.ID: Entry]) {
        for (id, entry) in prepared {
            store(entry, for: id, drawnAt: nil)
        }
        evictIfNeeded()
    }

    // MARK: - Re-measuring elsewhere

    /// Every entry that was measured into some width other than `width`, under the
    /// identity it is filed by.
    ///
    /// What a width change actually invalidates, and it is much less than the
    /// transcript: **only rows something has already asked about have an entry at
    /// all**, so a ten-thousand-row transcript the reader has scrolled a fifth of
    /// hands back two thousand rather than ten. Rows nobody has measured need
    /// nothing done — the first question about one is answered at whatever the
    /// width is then.
    ///
    /// Handed out as whole `Entry` values so the work can happen off the main
    /// actor; `Entry.remeasured(at:)` is what is done to each, and
    /// `merge(remeasured:at:)` is where they come back.
    ///
    /// **A dictionary rather than a list, because the caller reorders it and then
    /// strikes entries off.** Which row each one belongs to is the transcript's
    /// question, not this store's — it walks its rows outward from the viewport and
    /// claims entries out of this by identity as it passes them, so the rows nearest
    /// the reader are measured first and the walk stops as soon as this is empty.
    /// See `TranscriptView.staleRowsOutwardFromViewport(at:)`.
    func entries(measuredAtWidthOtherThan width: CGFloat) -> [TranscriptRow.ID: Entry] {
        entries.filter { $0.value.measuredWidth != width }
    }

    /// Files re-measurements taken elsewhere, keeping the ones whose row still
    /// wants what they were made from.
    ///
    /// **Both checks here are thrift, and it is worth knowing that before
    /// touching either.** Deleting them leaves the transcript correct: an entry
    /// filed under a row whose content has since moved is rejected by the same
    /// `(content, width)` comparison every read performs, and re-measured on the
    /// spot. Verified by deleting each and watching the whole suite stay green.
    /// What they buy is not writing entries that are certain to be rejected — a
    /// row a `reloadRows` changed during the window, a row a reader scrolled into
    /// and so re-measured on demand, an id a `reloadData` swept away.
    ///
    /// That the *correctness* of a background re-measure needs nothing here is the
    /// property the whole design rests on, so it is worth stating positively:
    /// entries have no positions, so an insert or a removal cannot move one; and
    /// an entry is believed only as far as it matches what is being asked for, so
    /// the worst a stale batch can do is waste the work that produced it.
    func merge(remeasured: [(id: TranscriptRow.ID, entry: Entry)], at width: CGFloat) {
        for item in remeasured {
            guard let current = entries[item.id], current.content == item.entry.content,
                current.measuredWidth != width
            else { continue }
            store(item.entry, for: item.id, drawnAt: nil)
        }
        evictIfNeeded()
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

    /// `row`'s tree if one is filed for its current content, **without building
    /// one** — measured at `width`, or at any width at all when `width` is `nil`.
    ///
    /// The `nil` case is the one read here that does not check the width, and it
    /// is not a relaxation of the rule above but a different question. Everything
    /// else asking this store wants geometry, and geometry is what the width
    /// decides. A find over a document wants the flat index space, which is a
    /// function of the row's content and no part of which depends on the width the
    /// row was laid out at — the invariant `BlockView`'s selection rests on, one
    /// level up. So an entry this store would rightly refuse to *draw* — one
    /// measured before a resize, one still waiting for its correction — answers
    /// that search exactly as well as a fresh one.
    ///
    /// **Not every case can ask it that way.** A user message cut short at its
    /// line cap is searched only as far as it is shown (`TypesetText.ranges(of:)`),
    /// and how far that is depends on how its lines broke — so its searchable
    /// extent is a function of the width after all, and the caller passes one.
    ///
    /// `nil` for a row nothing has measured, and that stays the caller's problem
    /// rather than being solved here by measuring one: the caller is walking every
    /// row in the transcript, and a parse per miss on the main thread is the freeze
    /// `prepareRows(_:)` exists to have removed. An evicted row answers `nil` the
    /// same way, and a find reading it does not count as drawing it — a walk over
    /// the whole transcript must not reorder what stays resident.
    func cachedMeasured(for row: TranscriptRow, width: CGFloat?) -> MeasuredBlock? {
        guard let entry = entries[row.id], entry.content == row.content,
            width.map({ $0 == entry.measuredWidth }) ?? true
        else { return nil }
        return entry.measured
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
        lastDrawn = lastDrawn.filter { live.contains($0.key) }
        residentCost = lastDrawn.keys.reduce(0) { total, id in
            total + (entries[id].map { Self.cost(of: $0.content) } ?? 0)
        }
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: true)
        lastDrawn.removeAll(keepingCapacity: true)
        residentCost = 0
    }
}

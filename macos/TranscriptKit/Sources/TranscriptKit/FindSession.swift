import AppKit
import ExactList

/// A find over the transcript: its state, the walk that fills it in, and its
/// presentation.
///
/// Owns the `Find` — matches keyed by row identity, the current match, the
/// walk's cursor — and the one `Task` that walks, cancelling a walk a newer find
/// or a refresh supersedes. Owns `overlay`, the view that shows it; the
/// transcript mounts it and tells this when rows move under it. The transcript
/// forwards its public find API here and tells it what each mutation did
/// (`shiftFind`, `keepFind`, `refileFind`, `refreshFind`); this reports back
/// through `FindSessionDelegate`, whose `findDidUpdate(matches:isComplete:)` is the
/// host's delegate call — the one channel a find crosses by.
@MainActor
final class FindSession {

    /// A find's presentation — the dimming, the lit matches, the current one's
    /// bubble. Mounted by the transcript, once, as a floating subview of its
    /// list (`addFloatingSubview`), and hidden while no find is up. See `FindOverlayView`.
    let overlay: FindOverlayView = {
        let overlay = FindOverlayView()
        overlay.isHidden = true
        return overlay
    }()

    private weak var dataSource: RowDataSource?
    private weak var delegate: FindSessionDelegate?
    private let rowCache: RowCache
    private let list: ExactListView

    init(
        dataSource: RowDataSource, delegate: FindSessionDelegate, rowCache: RowCache,
        list: ExactListView
    ) {
        self.dataSource = dataSource
        self.delegate = delegate
        self.rowCache = rowCache
        self.list = list
        overlay.rows = { [weak self] in self?.findRowsOnScreen() ?? [] }
    }

    /// Whether a find is up.
    var isFinding: Bool { find != nil }

    /// A find, running or settled.
    ///
    /// **Keyed on identity**, for the reason `RowCache` is: a hit is a place inside
    /// a row, and every insertion above a row renumbers it. The row numbers held
    /// here are the walk's own — its cursor and the slice it has out — and every
    /// mutation renumbers them on the way through (`shiftFind(byRowsInserted:)`),
    /// the way it renumbers the scroll anchor.
    private struct Find {

        let query: String

        /// What each row matched, for the rows that matched anything, filed with
        /// the content it was matched in — so a row whose content has moved on
        /// since is never drawn with ranges that name other characters now.
        var matches: [TranscriptRow.ID: RowMatches] = [:]

        /// How many hits that is, kept in step rather than derived — publishing a
        /// slice should cost the slice, not a walk of everything filed so far.
        var count = 0

        /// The hit the reader is on, by *where* it is: a row and a range, which no
        /// insertion or removal elsewhere can move.
        var selection: (row: TranscriptRow.ID, range: Range<Int>)?

        /// The selection's ordinal — the `4` in "4 of 51" less one — when it is
        /// known. **A cache, not a fact**: anything that changes which hits come
        /// before the selection clears it, and `indexOfSelectedMatch` works it
        /// out again when next asked. Kept in step instead, it would be one more
        /// number every mutation had to renumber correctly, and the review that
        /// found it wrong after a removal is why it is not.
        var ordinal: Int?

        /// The walk's cursor: every row above it has been searched.
        var next = 0

        /// The rows whose slice is on the pool right now. Cleared by a mutation
        /// that renumbers any of them, which is how the walk learns that the row
        /// numbers in the answer it is waiting for now name other rows.
        var pending: Range<Int>?

        /// Rows `TranscriptView.reloadRows(at:)` searched again on the main actor while `pending`
        /// was out. What the pool answers for them was matched against the content
        /// before, so it is older than what is filed, and is dropped.
        var refiled: Set<TranscriptRow.ID> = []

        /// The width the walk matches at. Only a capped user message cares — see
        /// `RowCache.cachedMeasured(for:width:)` — and a change is what
        /// `refreshFind()` exists to catch.
        var width: CGFloat

        /// Whether the walk selects a hit when it reaches the reader. A new find's
        /// first pass does; any later pass — a refresh, new rows arriving — must
        /// not scroll someone who is already reading.
        var landsOnViewport = true

        var isComplete = false
    }

    /// One row's hits, and the content they were found in.
    private struct RowMatches: Equatable {
        let content: TranscriptRowContent
        let ranges: [Range<Int>]
    }

    private var find: Find?

    /// The walk in flight, held for the two reasons `RemeasureScheduler.task` is: a superseded
    /// walk should stop burning cores for an answer nothing will read, and a test
    /// has no other honest way to know the walk has finished.
    private(set) var finding: Task<Void, Never>?

    /// One slice of the walk, in rows.
    ///
    /// A row count, where `RemeasureScheduler` had to reject one in
    /// favour of pacing against the cost of applying a batch. The difference is
    /// what a publish costs: there it is `noteHeightOfRows`, whose work is
    /// proportional to the whole transcript however few rows the batch held; here
    /// it is a dictionary write per row and a repaint of whatever is on screen.
    /// Bounded by the slice, so the slice is a fair unit.
    private static let findSliceRows = 200

    /// One slice on its way to the pool: what to search, and either the tree to
    /// search it in when something has already built one. A `.view` row is carried
    /// with no tree: it is not searched.
    private typealias FindSlice = [(
        row: Int, id: TranscriptRow.ID, content: TranscriptRowContent,
        measured: MeasuredBlock?
    )]

    /// What comes back: every row of the slice with what it matched — nothing
    /// included — so a walk passing a row that no longer matches can take its old
    /// hits away.
    private typealias FindBatch = [(
        row: Int, id: TranscriptRow.ID, content: TranscriptRowContent, ranges: [Range<Int>]
    )]

    /// The number of matches found so far. Still climbing until the find
    /// reports `isComplete`.
    var numberOfMatches: Int { find?.count ?? 0 }

    /// Which match the reader is on, counting from zero, or `nil` when none is
    /// selected — the walk has not reached the reader yet, there are no matches,
    /// or the one they were on went away.
    var indexOfSelectedMatch: Int? {
        guard let find, let selection = find.selection else { return nil }
        if let ordinal = find.ordinal { return ordinal }
        let ordinal = ordinal(of: selection, in: find)
        self.find?.ordinal = ordinal
        return ordinal
    }

    /// Starts a find for `query`, replacing any find already up; an empty query
    /// ends one. See `TranscriptView.find(_:)`.
    func find(_ query: String) {
        guard !query.isEmpty else { return endFind() }

        find = Find(query: query, width: dataSource?.contentWidth ?? 0)
        walkFind()
        rebindFind()
        reportFind()
    }

    /// Takes the highlights away, stops the walk, and reports. See
    /// `TranscriptView.endFind()`.
    func endFind() {
        finding?.cancel()
        finding = nil
        guard find != nil else { return }
        find = nil
        rebindFind()
        delegate?.findDidUpdate(matches: 0, isComplete: true)
    }

    /// Moves to the next match, wrapping at the end, and scrolls it into view.
    func findNext() { moveFindSelection(by: 1) }

    /// Moves to the previous match, wrapping at the start, and scrolls it into view.
    func findPrevious() { moveFindSelection(by: -1) }

    /// Starts the walk from the cursor, replacing one already running.
    private func walkFind() {
        finding?.cancel()
        guard find != nil else {
            finding = nil
            return
        }
        find?.pending = nil
        find?.isComplete = false
        finding = Task { [weak self] in
            await self?.scan()
        }
    }

    /// Walks a find again from the top, in place: what it had stays up until the
    /// walk reaches each row and replaces it, the reader keeps the hit they are
    /// on if it is still there, and nothing scrolls.
    ///
    /// For the two things that can change what matched without saying which rows:
    /// `TranscriptView.reloadData()`, after which any row may hold anything, and the content width
    /// settling, which moves where a capped user message is cut. Cheap in the
    /// common case, because every row the last pass searched is answered from the
    /// cache.
    func refreshFind() {
        guard find != nil else { return }
        find?.next = 0
        find?.width = dataSource?.contentWidth ?? 0
        walkFind()
    }

    /// Walks the transcript from the cursor in order, matching each slice off the
    /// main actor and publishing it before the next one starts.
    ///
    /// **In order, rather than outward from the viewport** — the opposite of what
    /// `RemeasureScheduler.staleRowsOutwardFromViewport(at:)` chose, and the difference is what the
    /// two are racing. A width correction has a *window* the reader can meet, so it
    /// starts where they are looking. A find has an *ordinal*: "4 of 51" only means
    /// anything if the fourth hit is the fourth from the top, and hits arriving out
    /// of order would renumber themselves under the reader as the walk filled in.
    ///
    /// **The cursor lives in `find`, not here**, because the transcript can change
    /// under every `await`: a mutation renumbers it where it stands, and one that
    /// renumbers the slice out on the pool clears `pending` — so the answer is
    /// dropped and the slice taken again from wherever the cursor went, rather than
    /// filed against rows that have since moved.
    private func scan() async {
        while let slice = takeFindSlice() {
            let batch = await Self.match(slice.rows, query: slice.query, width: slice.width)
            guard !Task.isCancelled else { return }
            guard find?.pending == slice.range else { continue }
            publish(batch, covering: slice.range)
        }
        guard !Task.isCancelled else { return }
        completeFind()
    }

    /// The next slice from the cursor, marked as out — or `nil` once the walk has
    /// passed the last row.
    ///
    /// The cache is read **by content, and by width only where the width decides
    /// what is searchable** — see `RowCache.cachedMeasured(for:width:)`. A row it
    /// answers costs this walk a dictionary lookup; a row it does not is carried
    /// across as its content and built on the pool, which is the only part of a
    /// find that is ever expensive.
    private func takeFindSlice() -> (
        range: Range<Int>, rows: FindSlice, query: String, width: CGFloat
    )? {
        guard var find, let dataSource, find.next < dataSource.numberOfRows else { return nil }
        let range = find.next..<min(find.next + Self.findSliceRows, dataSource.numberOfRows)
        let rows: FindSlice = range.compactMap { row in
            guard let described = dataSource.row(at: row) else { return nil }
            switch described.content {
            case .markdown:
                let cached = rowCache.cachedMeasured(for: described, width: nil)
                return (row, described.id, described.content, cached)
            case .userMessage:
                let cached = rowCache.cachedMeasured(for: described, width: find.width)
                return (row, described.id, described.content, cached)
            case .view:
                return (row, described.id, described.content, nil)
            }
        }
        // No row is "no data source": nothing to walk.
        guard rows.count == range.count else { return nil }
        find.pending = range
        find.refiled = []
        self.find = find
        return (range, rows, find.query, find.width)
    }

    /// One slice, matched across every core.
    ///
    /// `nonisolated` because a `static` member of a
    /// `@MainActor` type is main-actor isolated by default, and awaiting this from
    /// `scan` is what hops off. Everything crossing is `Sendable` — a
    /// `MeasuredBlock` because measuring is pure and nothing mutates one after it
    /// is built.
    ///
    /// **A tree built here is used and dropped, not filed.** Handing it to
    /// `RowCache` looks like thrift and is a change of behaviour: a find over a
    /// transcript nothing has read would push every row it passed through the
    /// resident budget, evicting the rows the reader has on screen to make room for
    /// rows nobody is looking at. What a hit actually needs is its range, which outlives
    /// the tree, and the one row the reader jumps to is re-measured on arrival for a
    /// fraction of a frame.
    private nonisolated static func match(
        _ slice: FindSlice, query: String, width: CGFloat
    ) async -> FindBatch {
        await withTaskGroup(of: FindBatch.Element?.self) { group in
            for row in slice {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    // A host's view is neither searched nor measured here.
                    if row.content == .view { return (row.row, row.id, row.content, []) }
                    // Nothing to reuse: this is either a row the cache already
                    // answered, or one nobody has measured at this width. Same
                    // call the cache would make, so the two cannot describe a row
                    // differently.
                    let measured =
                        row.measured
                        ?? RowCache.Entry(measuring: row.content, width: width, reusing: nil)?.measured
                    return (row.row, row.id, row.content, measured?.ranges(of: query) ?? [])
                }
            }
            var batch: FindBatch = []
            for await found in group {
                guard let found else { continue }
                batch.append(found)
            }
            // The pool answers in whatever order it finishes; the order a reader
            // navigates by is reading order, and this is the only place both are in
            // hand at once.
            return batch.sorted { $0.row < $1.row }
        }
    }

    /// Files a slice's hits, moves the cursor past it, shows what changed, and
    /// lands the selection if this is the slice the reader was looking at.
    ///
    /// **A find starts from where the reader is, not from the top.** Selecting the
    /// first hit the walk meets is what this did first, and it is wrong in the way
    /// that is obvious the moment it is used: search for a word that is on the
    /// screen in front of you, and the transcript jumps to the top of the history
    /// to show you a different one. Every find bar starts at the reader's position
    /// and wraps, so the hit that selects itself is the first one **at or after the
    /// first visible row**, and the wrap — for a query whose every hit is above
    /// them — happens once the walk is done, in `completeFind()`.
    ///
    /// The row numbers in `batch` are trusted here because `scan` only calls this
    /// while the slice is still `pending` — nothing has renumbered them.
    private func publish(_ batch: FindBatch, covering range: Range<Int>) {
        guard var find else { return }

        let viewport = firstVisibleRow
        var landing: (row: Int, id: TranscriptRow.ID, range: Range<Int>)?
        var changed = false

        for found in batch where !find.refiled.contains(found.id) {
            if Self.file(found.ranges, searched: found.content, for: found.id, in: &find) {
                changed = true
            }
            if find.landsOnViewport, find.selection == nil, landing == nil,
                found.row >= viewport, let first = found.ranges.first
            {
                landing = (found.row, found.id, first)
            }
        }
        find.next = range.upperBound
        find.pending = nil
        self.find = find

        if let landing {
            select(row: landing.row, id: landing.id, range: landing.range, ordinal: nil)
        } else if changed {
            rebindFind()
        }
        if changed { reportFind() }
    }

    /// Ends a walk that reached the last row.
    ///
    /// A first pass that found hits but none at or below the reader wraps to the
    /// first one — the same wrap `findNext()` makes off the end of the transcript,
    /// and what lets `publish` be strict about "at or after the viewport" without
    /// the case where nothing is falling through it.
    private func completeFind() {
        finding = nil
        guard var find else { return }
        find.isComplete = true
        let wraps = find.landsOnViewport && find.selection == nil && find.count > 0
        find.landsOnViewport = false
        self.find = find
        if wraps {
            // Reports on its way out, so this branch does not report twice.
            moveFindSelection(by: 1)
        } else {
            reportFind()
        }
    }

    /// Files what one row matched, keeping the count, the selection and the
    /// ordinal in step. Answers whether anything changed.
    ///
    /// **Replaces, never adds.** A row can be searched more than once — a refresh,
    /// a reload, a walk pulled back by an insertion — and the count has to move by
    /// the difference, not by the whole of each answer.
    private static func file(
        _ ranges: [Range<Int>], searched content: TranscriptRowContent,
        for id: TranscriptRow.ID, in find: inout Find
    ) -> Bool {
        let old = find.matches[id]
        let new = ranges.isEmpty ? nil : RowMatches(content: content, ranges: ranges)
        guard new != old else { return false }

        find.matches[id] = new
        find.count += ranges.count - (old?.ranges.count ?? 0)
        if new?.ranges != old?.ranges {
            // Conservative: a row after the selection cannot move its ordinal, but
            // knowing which side a row is on costs the walk this is saving.
            find.ordinal = nil
            if let selection = find.selection, selection.row == id,
                !ranges.contains(selection.range)
            {
                find.selection = nil
            }
        }
        return true
    }

    /// The topmost row the reader can see — where a fresh find starts looking.
    ///
    /// The list's own answer rather than a tracked one, and it is allowed to be
    /// approximate: a row half under the top inset counts as visible, which is the
    /// forgiving direction. A list that has not loaded answers no rows.
    private var firstVisibleRow: Int {
        list.rows(in: list.bounds).first ?? 0
    }

    /// Tells the delegate where the find has got to.
    ///
    /// One funnel rather than a call beside every mutation: the call means *this
    /// is the find's state now*, so every path that changes it — the matches, the
    /// current one, the walk finishing — reports through here, and none can
    /// forget to.
    func reportFind() {
        guard let find else { return }
        delegate?.findDidUpdate(matches: find.count, isComplete: find.isComplete)
    }

    /// Moves the selection `delta` hits along, wrapping at both ends — or, with
    /// nothing selected, onto the nearest hit from the reader in that direction.
    ///
    /// The order is re-derived here rather than kept, which costs one `rowAt` per
    /// row — the same walk `TranscriptView.sweepCache()` makes, on a keystroke rather than in a
    /// loop. Keeping it instead would mean a list of positions that every insertion
    /// renumbers, which is the bookkeeping `RowCache`'s identity keying exists to
    /// have deleted; and it would still have to be rebuilt after any mutation, so
    /// what it saves is a walk the reader is waiting on either way.
    private func moveFindSelection(by delta: Int) {
        let hits = locatedHits()
        guard !hits.isEmpty else { return }

        let target: Int
        if let selection = find?.selection,
            let current = hits.firstIndex(where: {
                $0.id == selection.row && $0.range == selection.range
            })
        {
            target = ((current + delta) % hits.count + hits.count) % hits.count
        } else {
            let viewport = firstVisibleRow
            let after = hits.firstIndex { $0.row >= viewport } ?? hits.count
            target = delta > 0 ? after % hits.count : (after + hits.count - 1) % hits.count
        }
        let hit = hits[target]
        select(row: hit.row, id: hit.id, range: hit.range, ordinal: target)
        reportFind()
    }

    /// Every hit in transcript order, with where its row is now.
    ///
    /// Rows the data source no longer has simply do not turn up, so a hit in a row
    /// that went away is skipped rather than navigated to — the same shape as
    /// `RemeasureScheduler.staleRowsOutwardFromViewport(at:)` dropping entries a removal orphaned.
    private func locatedHits() -> [(row: Int, id: TranscriptRow.ID, range: Range<Int>)] {
        guard let find, !find.matches.isEmpty, let dataSource else { return [] }
        var hits: [(row: Int, id: TranscriptRow.ID, range: Range<Int>)] = []
        for row in 0..<dataSource.numberOfRows {
            guard let id = dataSource.row(at: row)?.id else { return [] }
            guard let ranges = find.matches[id]?.ranges else { continue }
            hits.append(contentsOf: ranges.map { (row, id, $0) })
        }
        return hits
    }

    /// How many hits come before `selection`, in transcript order.
    ///
    /// The walk `locatedHits()` makes, stopping at the selection's row — so what a
    /// find bar asking after every report costs is the distance to the reader, and
    /// only when something has cleared the cached answer.
    private func ordinal(
        of selection: (row: TranscriptRow.ID, range: Range<Int>), in find: Find
    ) -> Int? {
        guard let dataSource else { return nil }
        var before = 0
        for row in 0..<dataSource.numberOfRows {
            guard let id = dataSource.row(at: row)?.id else { return nil }
            guard let ranges = find.matches[id]?.ranges else { continue }
            if id == selection.row {
                return ranges.firstIndex(of: selection.range).map { before + $0 }
            }
            before += ranges.count
        }
        return nil
    }

    /// Makes one hit the current one: records it, brings it on screen, repaints.
    private func select(row: Int, id: TranscriptRow.ID, range: Range<Int>, ordinal: Int?) {
        find?.selection = (id, range)
        find?.ordinal = ordinal
        delegate?.scrollFindMatchToVisible(range, inRow: row)
        rebindFind()
    }

    /// Shows the find as it stands now, or takes it away.
    ///
    /// Called wherever the find changes — its matches, its selection, its end.
    /// Every other reason the overlay has to look again is a row moving under it,
    /// and those reach `setNeedsFindLayout()` on their own.
    private func rebindFind() {
        overlay.isHidden = find == nil
        placeFindOverlay()
        setNeedsFindLayout()
    }

    /// Keeps the overlay over what is on screen: the list's bounds, converted
    /// into the overlay's space, with half a screen to spare either way.
    ///
    /// The overlay moves with the document on its own — AppKit carries a floating
    /// subview through a scroll the way it carries the rows — so this is not what
    /// keeps a lit match on its text. It is what keeps the *dimming* reaching the
    /// edge of the viewport as the reader travels further than the spare half
    /// screen, and what brings rows that have scrolled in under the overlay.
    ///
    /// A scroll inside the spare half screen changes nothing here: the rows it
    /// brings in report themselves as they arrive (`setNeedsFindLayout()`), so
    /// the overlay is not laid out — and its shade not redrawn — once per wheel
    /// event for nothing.
    func placeFindOverlay() {
        guard find != nil, let superview = overlay.superview else { return }
        // The overlay's superview is AppKit's floating container, which rides
        // with the document vertically; converting from the list is what keeps
        // this true whatever that container's own coordinates are.
        let visible = superview.convert(list.bounds, from: list)
        guard !overlay.frame.contains(visible) || overlay.frame.width != visible.width
        else { return }
        overlay.frame = visible.insetBy(dx: 0, dy: -visible.height / 2)
        overlay.needsLayout = true
    }

    /// Asks the overlay to read the rows on screen again, if a find is up.
    func setNeedsFindLayout() {
        guard find != nil else { return }
        overlay.needsLayout = true
    }

    /// The rows on screen that have matches, as the overlay asks for them.
    ///
    /// Filed matches are shown only for the content they were found in, so a row
    /// whose text has moved on since is lit nowhere rather than at ranges that name
    /// other characters now.
    private func findRowsOnScreen() -> [FindOverlayView.Row] {
        guard let find, let dataSource else { return [] }
        var rows: [FindOverlayView.Row] = []
        list.enumerateAvailableRowViews { cell, row in
            guard let view = (cell as? TranscriptCellView)?.hostedView as? BlockView,
                let described = dataSource.row(at: row)
            else { return }
            guard let filed = find.matches[described.id], filed.content == described.content
            else { return }
            let current = find.selection.flatMap { $0.row == described.id ? $0.range : nil }
            rows.append(.init(id: described.id, view: view, matches: filed.ranges, current: current))
        }
        return rows
    }

    /// Searches again the rows `TranscriptView.reloadRows(at:)` announced changed — the ones the
    /// walk has passed or has out, since it will reach the rest on its own.
    ///
    /// On the main actor and on the spot, because the table is about to measure
    /// these rows anyway: a changed row is a changed height, so the tree this
    /// searches is the one its height is answered from. For the streaming row that
    /// is one search of one row a frame, and only while a find is up.
    func refileFind(inRows rows: IndexSet) {
        guard var find, let dataSource else { return }
        let covered = min(find.pending?.upperBound ?? find.next, dataSource.numberOfRows)
        var changed = false
        for row in rows where row < covered {
            guard let described = dataSource.row(at: row) else { continue }
            let ranges =
                described.content == .view
                ? []
                : rowCache.measured(for: described, width: dataSource.contentWidth)?
                    .ranges(of: find.query) ?? []
            if find.pending?.contains(row) == true {
                find.refiled.insert(described.id)
            }
            if Self.file(ranges, searched: described.content, for: described.id, in: &find) {
                changed = true
            }
        }
        self.find = find
        guard changed else { return }
        rebindFind()
        reportFind()
    }

    /// Renumbers the walk for rows inserted at `indexes` (post-insertion
    /// positions), and resumes a walk that had finished so it takes them in.
    ///
    /// Rows landing *behind* the cursor pull it back to the first of them rather
    /// than past them: the walk re-reads what lies between, which the cache
    /// answers, and nothing inserted goes unsearched. A slice out on the pool that
    /// the insertion renumbered is abandoned — `scan` takes it again.
    ///
    /// Not reported: nothing has been found yet. The walk reports as it files, and
    /// `isComplete` goes back to `true` when it reaches the end again.
    func shiftFind(byRowsInserted indexes: IndexSet) {
        guard var find, let first = indexes.first else { return }
        if let pending = find.pending, first < pending.upperBound {
            find.pending = nil
        }
        find.next = min(find.next, first)
        self.find = find
        if finding == nil { walkFind() }
    }

    /// Renumbers the walk for rows removed at `indexes` (pre-removal positions).
    /// Their hits went with the sweep `TranscriptView.removeRows(at:)` makes first.
    func shiftFind(byRowsRemoved indexes: IndexSet) {
        guard var find, let first = indexes.first else { return }
        if let pending = find.pending, first < pending.upperBound {
            find.pending = nil
        }
        find.next -= indexes.count(in: 0..<find.next)
        self.find = find
    }

    /// Drops hits for rows the data source no longer has.
    ///
    /// Called from `TranscriptView.sweepCache()`, off the same walk and the same live set, because
    /// the two answer one question — which identities still name a row — and asking
    /// it twice is how the answers come to differ. Not reported here: this runs
    /// inside a mutation, before the table has been told, and anything read in
    /// answer to the report would walk rows the table does not have yet. The
    /// mutation reports once it is done.
    func keepFind(_ live: Set<TranscriptRow.ID>) {
        guard var find else { return }
        let gone = find.matches.keys.filter { !live.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone {
            find.count -= find.matches.removeValue(forKey: id)?.ranges.count ?? 0
        }
        find.ordinal = nil
        if let selection = find.selection, !live.contains(selection.row) {
            find.selection = nil
        }
        self.find = find
    }

    /// Walks a find again once the width has settled, if it was walked at another.
    ///
    /// Only a user message cut at its line cap searches differently at a new width
    /// — how far it is shown depends on how its lines broke — and nothing cheaper
    /// than a walk can say which rows those are. Settled rather than per frame of a
    /// drag, for the reason the off-screen re-measure waits for mouse-up.
    func refreshFindAfterWidthChange() {
        guard let find, find.width != (dataSource?.contentWidth ?? 0) else { return }
        refreshFind()
    }
}
